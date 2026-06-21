#!/bin/sh
set -eu

GUARD_DIR="/etc/podkop-guard"
CACHE_DIR="$GUARD_DIR/cache"
URLS_FILE="$GUARD_DIR/urls.txt"
LOG_TAG="podkop-all-lists-guard"

DEFAULT_URLS='https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Subnets/IPv4/cloudflare.lst
https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Subnets/IPv4/discord.lst
https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Subnets/IPv4/meta.lst
https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Subnets/IPv4/telegram.lst
https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Subnets/IPv4/twitter.lst'

log_msg() {
  level="$1"
  shift
  msg="$*"
  echo "[$level] $msg"
  if command -v logger >/dev/null 2>&1; then
    logger -t "$LOG_TAG" "[$level] $msg" 2>/dev/null || true
  fi
}

info() {
  log_msg INFO "$@"
}

warn() {
  log_msg WARN "$@"
}

err() {
  log_msg ERROR "$@"
}

ensure_inventory() {
  mkdir -p "$CACHE_DIR"

  if [ ! -s "$URLS_FILE" ]; then
    umask 022
    printf '%s\n' "$DEFAULT_URLS" > "$URLS_FILE"
    info "Created default URL inventory: $URLS_FILE"
  fi
}

cache_name_for_url() {
  url="$1"
  base="$(printf '%s' "$url" | sed 's#[?#].*##; s#.*/##; s#[^A-Za-z0-9_.-]#_#g')"
  case "$base" in
    *.lst) ;;
    *) base="${base}.lst" ;;
  esac
  printf 'Subnets_IPv4_%s\n' "$base"
}

download_url_to_tmp() {
  url="$1"
  tmp="$2"

  rm -f "$tmp"

  if command -v curl >/dev/null 2>&1; then
    curl -4 -fsSL --connect-timeout 8 --max-time 25 --retry 2 --retry-delay 2 "$url" -o "$tmp"
  elif command -v wget >/dev/null 2>&1; then
    wget -T 25 -O "$tmp" "$url"
  else
    err "Need curl or wget to download subnet lists."
    return 1
  fi

  [ -s "$tmp" ]
}

download_all() {
  mode="$1"
  failures=0
  count=0

  ensure_inventory

  while IFS= read -r url || [ -n "$url" ]; do
    case "$url" in
      ''|\#*) continue ;;
    esac

    count=$((count + 1))
    cache_file="$CACHE_DIR/$(cache_name_for_url "$url")"
    tmp="/tmp/podkop-guard-download.$$.tmp"

    if download_url_to_tmp "$url" "$tmp"; then
      mv "$tmp" "$cache_file"
      info "Cached $(basename "$cache_file")"
    else
      rm -f "$tmp"
      failures=$((failures + 1))
      if [ "$mode" = "precheck" ]; then
        err "Failed to download or empty list: $url"
      else
        warn "Failed to refresh list: $url"
      fi
    fi
  done < "$URLS_FILE"

  rm -f "/tmp/podkop-guard-download.$$.tmp"

  if [ "$count" -eq 0 ]; then
    err "URL inventory is empty: $URLS_FILE"
    return 1
  fi

  if [ "$mode" = "precheck" ] && [ "$failures" -gt 0 ]; then
    return 1
  fi

  if [ "$mode" = "precheck" ]; then
    info "OK: all lists downloaded successfully"
  elif [ "$failures" -eq 0 ]; then
    info "OK: refresh completed successfully"
  else
    warn "Refresh completed with failed lists: $failures"
  fi

  return 0
}

find_nft_set() {
  target="$1"
  nft list ruleset 2>/dev/null | awk -v target="$target" '
    $1 == "table" { fam=$2; tbl=$3 }
    $1 == "set" && $2 == target { print fam " " tbl; exit }
  '
}

add_cidr_to_set() {
  location="$1"
  set_name="$2"
  cidr="$3"

  set -- $location
  fam="${1:-}"
  tbl="${2:-}"

  if [ -z "$fam" ] || [ -z "$tbl" ]; then
    return 0
  fi

  nft add element "$fam" "$tbl" "$set_name" "{ $cidr }" 2>/dev/null || true
}

apply_cache_file() {
  file="$1"
  default_location="$2"
  discord_location="$3"
  attempted_file="/tmp/podkop-guard-attempted.$$.count"

  target_set="podkop_subnets"
  target_location="$default_location"

  case "$(basename "$file")" in
    Subnets_IPv4_discord.lst)
      if [ -n "$discord_location" ]; then
        target_set="podkop_discord_subnets"
        target_location="$discord_location"
      fi
      ;;
  esac

  sed 's/#.*//; s/[[:space:]]*$//; s/^[[:space:]]*//' "$file" \
    | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/ { print }' \
    | while IFS= read -r cidr; do
        [ -n "$cidr" ] || continue
        add_cidr_to_set "$target_location" "$target_set" "$cidr"
        count="$(cat "$attempted_file" 2>/dev/null || echo 0)"
        count=$((count + 1))
        printf '%s\n' "$count" > "$attempted_file"
      done
}

apply_cached_lists() {
  ensure_inventory

  subnets_location="$(find_nft_set podkop_subnets || true)"
  discord_location="$(find_nft_set podkop_discord_subnets || true)"

  if [ -z "$subnets_location" ]; then
    warn "podkop_subnets nft set not found. Skipping guard apply."
    return 0
  fi

  attempted_file="/tmp/podkop-guard-attempted.$$.count"
  printf '0\n' > "$attempted_file"
  files_count=0

  for file in "$CACHE_DIR"/Subnets_IPv4_*.lst; do
    [ -f "$file" ] || continue
    files_count=$((files_count + 1))
    apply_cache_file "$file" "$subnets_location" "$discord_location"
  done

  attempted="$(cat "$attempted_file" 2>/dev/null || echo 0)"
  rm -f "$attempted_file"

  info "OK: processed cache files=$files_count, CIDR entries attempted=$attempted"
  return 0
}

show_sample_cidr() {
  cidr="$1"
  if nft list ruleset 2>/dev/null | grep -Fq "$cidr"; then
    echo "$cidr: present"
  else
    echo "$cidr: not-found"
  fi
}

status_report() {
  ensure_inventory

  echo "URL inventory: $URLS_FILE"
  cat "$URLS_FILE" 2>/dev/null || true
  echo
  echo "Cache files:"
  for file in "$CACHE_DIR"/Subnets_IPv4_*.lst; do
    [ -f "$file" ] || continue
    lines="$(wc -l < "$file" | tr -d ' ')"
    echo "$file ($lines lines)"
  done
  echo

  subnets_location="$(find_nft_set podkop_subnets || true)"
  discord_location="$(find_nft_set podkop_discord_subnets || true)"

  echo "podkop_subnets set location: ${subnets_location:-not-found}"
  echo "podkop_discord_subnets set location: ${discord_location:-not-found}"
  echo
  echo "Sample CIDR status:"
  show_sample_cidr "5.28.192.0/18"
  show_sample_cidr "91.108.4.0/22"
  show_sample_cidr "149.154.160.0/20"
  show_sample_cidr "31.13.64.0/18"
  show_sample_cidr "157.240.0.0/17"
  show_sample_cidr "104.16.0.0/13"
  show_sample_cidr "104.16.0.0/12"
  show_sample_cidr "141.101.64.0/18"
  show_sample_cidr "162.158.0.0/15"
  show_sample_cidr "162.159.0.0/16"
}

usage() {
  cat <<EOF
Usage: $0 --precheck|--refresh|--apply|--status

--precheck  Download every static subnet list and fail if any list is unavailable.
--refresh   Best-effort cache refresh; warnings do not fail the command.
--apply     Re-apply cached CIDR entries to Podkop nft sets.
--status    Show inventory, cache files, nft set locations, and sample CIDR status.
EOF
}

case "${1:-}" in
  --precheck)
    download_all precheck
    ;;
  --refresh)
    download_all refresh
    ;;
  --apply)
    apply_cached_lists
    ;;
  --status)
    status_report
    ;;
  *)
    usage
    exit 2
    ;;
esac
