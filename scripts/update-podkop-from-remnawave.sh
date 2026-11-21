#!/bin/sh
set -eu

CONF="${CONF:-/etc/podkop-remnawave/subscription.conf}"
DENYLIST_FILE="${DENYLIST_FILE:-/etc/podkop-remnawave/denylist.sha256}"
BACKUP_ROOT="${BACKUP_ROOT:-/root/podkop-remnawave-backups}"
BYPASS_BIN="${BYPASS_BIN:-/root/apply-podkop-router-output-bypass.sh}"
TAILSCALE_PROTECT_BIN="${TAILSCALE_PROTECT_BIN:-/usr/bin/podkop-tailscale-protect.sh}"
GUARD_BIN="${GUARD_BIN:-/usr/bin/podkop-all-lists-guard.sh}"

UCI_CFG='podkop'
MAIN_SEC='main'
USA_SEC='USA'
MANAGED_SUFFIX='-rwsub'
LINK_SCHEMES='(vless|ss|trojan|hysteria2|hy2)'
UA='Podkop-OpenWrt/1.0'
TIMEOUT='25'
DRY_RUN=0

TMP_SUB="/tmp/remnawave-sub.$$"
TMP_TXT="/tmp/remnawave-sub.$$.txt"
TMP_ALL="/tmp/remnawave-links-all.$$.list"
TMP_MAIN_SRC="/tmp/remnawave-links-main-src.$$.list"
TMP_USA_SRC="/tmp/remnawave-links-usa-src.$$.list"
TMP_MAIN_MANUAL="/tmp/podkop-main-manual.$$.list"
TMP_USA_MANUAL="/tmp/podkop-usa-manual.$$.list"
TMP_MAIN_CANDIDATE="/tmp/podkop-main-candidate.$$.list"
TMP_USA_CANDIDATE="/tmp/podkop-usa-candidate.$$.list"
TMP_DENY="/tmp/podkop-deny.$$.list"
TMP_DENY_NEW="/tmp/podkop-deny.$$.list.new"
TMP_UCI="/tmp/podkop-uci.$$.batch"

usage() {
  cat <<'EOF'
Usage: update-podkop-from-remnawave.sh [--dry-run]

  --dry-run   Download and parse the Remnawave subscription, build the
              candidate pool, and print only counts/protocols/hash prefixes.
              Does not change UCI, restart services, routes, nft, or cron.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[ERROR] Unknown argument: $1"; usage; exit 2 ;;
  esac
  shift
done

cleanup() {
  rm -f "$TMP_SUB" "$TMP_TXT" "$TMP_ALL" "$TMP_MAIN_SRC" "$TMP_USA_SRC" \
    "$TMP_MAIN_MANUAL" "$TMP_USA_MANUAL" "$TMP_MAIN_CANDIDATE" \
    "$TMP_USA_CANDIDATE" "$TMP_DENY" "$TMP_DENY_NEW" "$TMP_UCI"
}
trap cleanup EXIT

sanitize_output() {
  sed \
    -e 's#https\?://[^[:space:]]*#URL***MASKED***#g' \
    -e 's#vless://[^[:space:]]*#vless://***MASKED***#g' \
    -e 's#trojan://[^[:space:]]*#trojan://***MASKED***#g' \
    -e 's#ss://[^[:space:]]*#ss://***MASKED***#g' \
    -e 's#hysteria2://[^[:space:]]*#hysteria2://***MASKED***#g' \
    -e 's#hy2://[^[:space:]]*#hy2://***MASKED***#g' \
    -e 's/tskey-[^[:space:]]*/tskey-***MASKED***/g'
}

require_config() {
  if [ ! -f "$CONF" ]; then
    echo "[ERROR] Missing config: $CONF"
    echo "[ERROR] Expected it to contain SUB_URL plus optional safe flags."
    exit 1
  fi
}

read_conf_value() {
  key="$1"
  sed -n "s/^[[:space:]]*${key}=['\"]\\{0,1\\}\\([^'\"]*\\)['\"]\\{0,1\\}[[:space:]]*$/\\1/p" "$CONF" 2>/dev/null | head -n 1
}

load_config() {
  require_config

  SUB_URL="$(read_conf_value SUB_URL)"
  PRESERVE_MANUAL_LINKS="$(read_conf_value PRESERVE_MANUAL_LINKS)"
  DENYLIST_SHA256="$(read_conf_value DENYLIST_SHA256)"

  [ -n "$PRESERVE_MANUAL_LINKS" ] || PRESERVE_MANUAL_LINKS=0
  [ -n "$DENYLIST_SHA256" ] || DENYLIST_SHA256=''

  case "$SUB_URL" in
    http://*|https://*) ;;
    *) echo "[ERROR] Cannot read valid SUB_URL from $CONF"; exit 1 ;;
  esac

  case "$PRESERVE_MANUAL_LINKS" in
    0|1) ;;
    *) echo "[ERROR] PRESERVE_MANUAL_LINKS must be 0 or 1"; exit 1 ;;
  esac
}

sha256_full() {
  printf '%s' "$1" | sha256sum | awk '{print $1}'
}

hash12() {
  printf '%s' "$1" | sha256sum | awk '{print substr($1,1,12)}'
}

proto_of() {
  printf '%s' "$1" | sed 's#://.*##'
}

count_lines() {
  awk 'NF { n++ } END { print n + 0 }' "$1"
}

protocol_breakdown() {
  file="$1"
  vless="$(grep -c '^vless://' "$file" 2>/dev/null || true)"
  ss="$(grep -c '^ss://' "$file" 2>/dev/null || true)"
  trojan="$(grep -c '^trojan://' "$file" 2>/dev/null || true)"
  hy2="$(grep -cE '^(hysteria2|hy2)://' "$file" 2>/dev/null || true)"
  echo "vless=$vless ss=$ss trojan=$trojan hy2=$hy2"
}

dedupe_keep_order() {
  awk 'NF && !seen[$0]++'
}

normalize_links() {
  sed '/^vless:\/\// { /security=reality/ { /[?&]spx=/! s/#/\&spx=%2F#/; } }'
}

mark_managed_link() {
  link="$1"
  case "$link" in
    *"${MANAGED_SUFFIX}") printf '%s\n' "$link" ;;
    *\#*) printf '%s\n' "$(printf '%s' "$link" | sed "s/#\([^#[:space:]]*\)$/#\1${MANAGED_SUFFIX}/")" ;;
    *) printf '%s\n' "${link}#rwsub" ;;
  esac
}

is_managed_link() {
  case "$1" in
    *"${MANAGED_SUFFIX}"|*"#rwsub") return 0 ;;
    *) return 1 ;;
  esac
}

strip_managed_marker() {
  sed "s/${MANAGED_SUFFIX}$//; s/#rwsub$//"
}

section_exists() {
  sec="$1"
  uci -q show "${UCI_CFG}.${sec}" >/dev/null 2>&1
}

ensure_section() {
  sec="$1"
  if ! section_exists "$sec"; then
    echo "[INFO] Creating podkop.${sec} section"
    anon="$(uci add "$UCI_CFG" section)"
    uci rename "${UCI_CFG}.${anon}=${sec}"
  fi
}

load_denylist() {
  : > "$TMP_DENY"

  if [ -n "$DENYLIST_SHA256" ]; then
    printf '%s\n' "$DENYLIST_SHA256" | tr ' ' '\n' >> "$TMP_DENY"
  fi

  if [ -f "$DENYLIST_FILE" ]; then
    sed 's/#.*//; s/[[:space:]]*$//' "$DENYLIST_FILE" | tr ' ' '\n' >> "$TMP_DENY"
  fi

  grep -E '^[0-9a-fA-F]{64}$' "$TMP_DENY" 2>/dev/null | tr 'A-F' 'a-f' | dedupe_keep_order > "$TMP_DENY_NEW" || true
  mv "$TMP_DENY_NEW" "$TMP_DENY"
}

is_denied_link() {
  link="$1"
  [ -s "$TMP_DENY" ] || return 1
  h="$(sha256_full "$link")"
  grep -Fxq "$h" "$TMP_DENY"
}

log_link_decision() {
  idx="$1"
  source="$2"
  decision="$3"
  link="$4"
  reason="$5"
  printf '[LINK] index=%s protocol=%s hash=%s source=%s decision=%s reason=%s\n' \
    "$idx" "$(proto_of "$link")" "$(hash12 "$link")" "$source" "$decision" "$reason" >&2
}

extract_current_links() {
  sec="$1"
  uci -q get "${UCI_CFG}.${sec}.urltest_proxy_links" 2>/dev/null \
    | tr ' ' '\n' \
    | grep -E "^${LINK_SCHEMES}://" || true
}

collect_manual_links() {
  sec="$1"
  current_src_file="$2"
  output_file="$3"

  : > "$output_file"

  if [ "$PRESERVE_MANUAL_LINKS" != "1" ]; then
    return 0
  fi

  if ! section_exists "$sec"; then
    return 0
  fi

  idx=0
  extract_current_links "$sec" | while IFS= read -r link; do
    [ -n "$link" ] || continue
    idx=$((idx + 1))

    if is_managed_link "$link"; then
      log_link_decision "$idx" manual drop "$link" managed-existing
      continue
    fi

    norm="$(printf '%s\n' "$link" | strip_managed_marker)"
    if grep -Fxq "$norm" "$current_src_file" 2>/dev/null; then
      log_link_decision "$idx" manual drop "$link" duplicates-subscription
      continue
    fi

    if is_denied_link "$link"; then
      log_link_decision "$idx" manual deny "$link" denylist
      continue
    fi

    log_link_decision "$idx" manual preserve "$link" preserve-manual-enabled
    printf '%s\n' "$link"
  done >> "$output_file" || true
}

build_managed_candidates() {
  src_file="$1"
  output_file="$2"

  : > "$output_file"
  idx=0

  while IFS= read -r link; do
    [ -n "$link" ] || continue
    idx=$((idx + 1))
    marked="$(mark_managed_link "$link")"

    if is_denied_link "$marked"; then
      log_link_decision "$idx" subscription deny "$marked" denylist
      continue
    fi

    log_link_decision "$idx" subscription keep "$marked" subscription
    printf '%s\n' "$marked"
  done < "$src_file" | dedupe_keep_order > "$output_file"
}

write_urltest_section() {
  sec="$1"
  manual_file="$2"
  managed_file="$3"

  echo "set ${UCI_CFG}.${sec}.connection_type='proxy'"
  echo "set ${UCI_CFG}.${sec}.proxy_config_type='urltest'"
  echo "del ${UCI_CFG}.${sec}.proxy_string"
  echo "del ${UCI_CFG}.${sec}.urltest_proxy_links"

  if [ -s "$manual_file" ]; then
    while IFS= read -r link; do
      [ -n "$link" ] || continue
      esc="$(printf "%s" "$link" | sed "s/'/'\\\\''/g")"
      echo "add_list ${UCI_CFG}.${sec}.urltest_proxy_links='${esc}'"
    done < "$manual_file"
  fi

  if [ -s "$managed_file" ]; then
    while IFS= read -r link; do
      [ -n "$link" ] || continue
      esc="$(printf "%s" "$link" | sed "s/'/'\\\\''/g")"
      echo "add_list ${UCI_CFG}.${sec}.urltest_proxy_links='${esc}'"
    done < "$managed_file"
  fi

  echo "set ${UCI_CFG}.${sec}.urltest_check_interval='3m'"
  echo "set ${UCI_CFG}.${sec}.urltest_tolerance='50'"
  echo "set ${UCI_CFG}.${sec}.urltest_testing_url='https://www.gstatic.com/generate_204'"
}

guard_available() {
  [ -x "$GUARD_BIN" ]
}

guard_precheck() {
  guard_available || return 0
  echo "[SAFE-PODKOP-GUARD] Prechecking Podkop subnet lists before Podkop restart..."
  "$GUARD_BIN" --precheck
}

guard_apply() {
  guard_available || return 0
  echo "[SAFE-PODKOP-GUARD] Re-applying cached subnet lists after updater..."
  "$GUARD_BIN" --apply || true
}

ensure_guard_cron() {
  guard_available || return 0
  command -v crontab >/dev/null 2>&1 || return 0

  (
    crontab -l 2>/dev/null | grep -v 'podkop-all-lists-guard.sh' || true
    echo '*/2 * * * * /usr/bin/podkop-all-lists-guard.sh --apply >/tmp/podkop-all-lists-guard-apply.log 2>&1'
    echo '17 */6 * * * /usr/bin/podkop-all-lists-guard.sh --refresh >/tmp/podkop-all-lists-guard-refresh.log 2>&1'
  ) | crontab - || echo "[WARN] Failed to install Podkop subnet guard cron."
}

apply_runtime_protection() {
  [ -x "$BYPASS_BIN" ] && "$BYPASS_BIN" || true
  [ -x "$TAILSCALE_PROTECT_BIN" ] && "$TAILSCALE_PROTECT_BIN" || true
}

wait_sing_box() {
  i=0
  while [ "$i" -lt 60 ]; do
    if pgrep -af sing-box >/dev/null 2>&1; then
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  return 1
}

restart_podkop_safely() {
  echo "[INFO] Restarting Podkop safely..."
  /etc/init.d/podkop stop || true
  sleep 3

  if pgrep -x sing-box >/dev/null 2>&1; then
    echo "[WARN] sing-box remained after Podkop stop. Killing stale process..."
    killall sing-box || true
    sleep 2
  fi

  if pgrep -x sing-box >/dev/null 2>&1; then
    echo "[ERROR] Old sing-box process is still running. Refusing to start Podkop."
    pgrep -af sing-box || true
    return 1
  fi

  /etc/init.d/podkop start
  wait_sing_box
}

listener_ok() {
  netstat -tulpn 2>/dev/null | grep -q '127\.0\.0\.42:53' || return 1
  netstat -tulpn 2>/dev/null | grep -q '127\.0\.0\.1:1602' || return 1
  return 0
}

fakeip_ok() {
  domain="$1"
  nslookup "$domain" 127.0.0.1 2>/dev/null | grep -q 'Address: 198\.18\.'
}

urltest_delay_ok() {
  proxy="$1"
  url="$2"
  command -v curl >/dev/null 2>&1 || return 0
  curl -sS --max-time 15 "http://192.168.0.1:9090/proxies/${proxy}/delay?timeout=12000&url=${url}" 2>/dev/null \
    | grep -q '"delay"'
}

validate_after_apply() {
  echo "[INFO] Validating Podkop/sing-box after apply..."

  wait_sing_box || { echo "[ERROR] sing-box is not running after Podkop restart."; return 1; }
  listener_ok || { echo "[ERROR] sing-box listeners 127.0.0.42:53 or 127.0.0.1:1602 are missing."; return 1; }

  for d in youtube.com telegram.org instagram.com; do
    if fakeip_ok "$d"; then
      echo "[OK] $d resolves to FakeIP."
    else
      echo "[ERROR] $d does not resolve to FakeIP via router dnsmasq."
      return 1
    fi
  done

  if command -v curl >/dev/null 2>&1; then
    for url in https://telegram.org https://youtube.com https://www.instagram.com; do
      if urltest_delay_ok main-out "$url" || urltest_delay_ok main-urltest-out "$url"; then
        echo "[OK] URLTest delay check passed for $url"
      else
        echo "[ERROR] URLTest delay check failed for $url"
        return 1
      fi
    done
  else
    echo "[WARN] curl unavailable; skipping URLTest API site delay checks."
  fi

  return 0
}

rollback_from_backup() {
  backup_dir="$1"
  echo "[ERROR] Validation failed. Rolling back from $backup_dir"
  cp -a "$backup_dir/podkop" /etc/config/podkop
  uci commit podkop
  /etc/init.d/podkop restart || true
  sleep 20
  apply_runtime_protection
}

check_tailscale_after_podkop() {
  command -v tailscale >/dev/null 2>&1 || return 0
  ts_status="$(tailscale status 2>/dev/null || true)"
  [ -n "$ts_status" ] || return 0

  if printf '%s\n' "$ts_status" | grep -qiE 'offline|coordination server|health.*warn|unable to connect'; then
    echo "[WARN] Tailscale may be unhealthy after Podkop restart."
  else
    echo "[OK] Tailscale status does not report offline/coordination warnings."
  fi
}

download_subscription() {
  echo "[INFO] Downloading Remnawave subscription..."
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL \
      --connect-timeout "$TIMEOUT" \
      --max-time "$TIMEOUT" \
      -H "User-Agent: $UA" \
      -H "Accept: */*" \
      "$SUB_URL" \
      -o "$TMP_SUB"
  elif command -v wget >/dev/null 2>&1; then
    wget -T "$TIMEOUT" \
      --header="User-Agent: $UA" \
      --header='Accept: */*' \
      -O "$TMP_SUB" \
      "$SUB_URL"
  else
    echo "[ERROR] curl or wget is required to download subscription."
    exit 1
  fi

  if grep -Eq "${LINK_SCHEMES}://" "$TMP_SUB"; then
    cp "$TMP_SUB" "$TMP_TXT"
  elif base64 -d "$TMP_SUB" > "$TMP_TXT" 2>/dev/null; then
    :
  else
    echo "[ERROR] Cannot decode subscription as base64 and no supported proxy links found."
    echo "[DEBUG] First 300 bytes:"
    head -c 300 "$TMP_SUB" | sed 's/[^[:print:]\t]/?/g' | sanitize_output
    echo
    exit 1
  fi

  grep -Eo "${LINK_SCHEMES}://[^[:space:]]+" "$TMP_TXT" \
    | normalize_links \
    | dedupe_keep_order \
    > "$TMP_ALL" || true

  if [ ! -s "$TMP_ALL" ]; then
    echo "[ERROR] No supported proxy links found in subscription."
    exit 1
  fi

  if grep -Eq '@0\.0\.0\.0:1|00000000-0000-0000-0000-000000000000|App%20not%20supported|App not supported' "$TMP_ALL"; then
    echo "[ERROR] Subscription returned placeholder / App not supported link."
    echo "[ERROR] Refusing to apply invalid links to Podkop."
    grep -E '@0\.0\.0\.0:1|00000000-0000-0000-0000-000000000000|App%20not%20supported|App not supported' "$TMP_ALL" | sanitize_output
    exit 1
  fi
}

split_subscription() {
  USA_EXISTS=0
  if section_exists "$USA_SEC"; then
    USA_EXISTS=1
  fi

  if [ "$USA_EXISTS" -eq 1 ]; then
    grep -E '@us\.adeptpro\.online:443|#.*us|#.*US|#.*usa|#.*USA' "$TMP_ALL" > "$TMP_USA_SRC" || true
    grep -Ev '@us\.adeptpro\.online:443|#.*us|#.*US|#.*usa|#.*USA' "$TMP_ALL" > "$TMP_MAIN_SRC" || true
  else
    cp "$TMP_ALL" "$TMP_MAIN_SRC"
    : > "$TMP_USA_SRC"
  fi
}

build_candidate_files() {
  load_denylist
  split_subscription

  : > "$TMP_MAIN_MANUAL"
  : > "$TMP_USA_MANUAL"

  collect_manual_links "$MAIN_SEC" "$TMP_MAIN_SRC" "$TMP_MAIN_MANUAL"
  [ "$USA_EXISTS" -eq 1 ] && collect_manual_links "$USA_SEC" "$TMP_USA_SRC" "$TMP_USA_MANUAL"

  build_managed_candidates "$TMP_MAIN_SRC" "$TMP_MAIN_CANDIDATE"
  build_managed_candidates "$TMP_USA_SRC" "$TMP_USA_CANDIDATE"

  MAIN_MANUAL_COUNT="$(count_lines "$TMP_MAIN_MANUAL")"
  USA_MANUAL_COUNT="$(count_lines "$TMP_USA_MANUAL")"
  MAIN_CANDIDATE_COUNT="$(count_lines "$TMP_MAIN_CANDIDATE")"
  USA_CANDIDATE_COUNT="$(count_lines "$TMP_USA_CANDIDATE")"
  DENY_COUNT="$(count_lines "$TMP_DENY")"
}

print_summary() {
  echo "[INFO] preserve_manual=$PRESERVE_MANUAL_LINKS"
  echo "[INFO] denylist_hashes=$DENY_COUNT"
  echo "[INFO] subscription_count=$(count_lines "$TMP_ALL")"
  echo "[INFO] subscription_protocols=$(protocol_breakdown "$TMP_ALL")"
  echo "[INFO] main_candidate_count=$MAIN_CANDIDATE_COUNT"
  echo "[INFO] usa_candidate_count=$USA_CANDIDATE_COUNT"
  echo "[INFO] preserved_manual_main=$MAIN_MANUAL_COUNT"
  echo "[INFO] preserved_manual_usa=$USA_MANUAL_COUNT"
  echo "[INFO] main_candidate_protocols=$(protocol_breakdown "$TMP_MAIN_CANDIDATE")"
  echo "[INFO] usa_candidate_protocols=$(protocol_breakdown "$TMP_USA_CANDIDATE")"
}

print_dry_run() {
  current_main="$(extract_current_links "$MAIN_SEC" | wc -l | tr -d ' ')"
  current_usa=0
  [ "$USA_EXISTS" -eq 1 ] && current_usa="$(extract_current_links "$USA_SEC" | wc -l | tr -d ' ')"

  echo "[DRY-RUN] current_router_main_count=$current_main"
  echo "[DRY-RUN] current_router_usa_count=$current_usa"
  print_summary
  echo "[DRY-RUN] candidate_main_hashes_begin"
  idx=0
  cat "$TMP_MAIN_MANUAL" "$TMP_MAIN_CANDIDATE" | while IFS= read -r link; do
    [ -n "$link" ] || continue
    idx=$((idx + 1))
    printf '[DRY-RUN] index=%s protocol=%s hash=%s source=candidate\n' "$idx" "$(proto_of "$link")" "$(hash12 "$link")"
  done
  echo "[DRY-RUN] candidate_main_hashes_end"
  if [ "$USA_EXISTS" -eq 1 ]; then
    echo "[DRY-RUN] candidate_usa_hashes_begin"
    idx=0
    cat "$TMP_USA_MANUAL" "$TMP_USA_CANDIDATE" | while IFS= read -r link; do
      [ -n "$link" ] || continue
      idx=$((idx + 1))
      printf '[DRY-RUN] index=%s protocol=%s hash=%s source=candidate\n' "$idx" "$(proto_of "$link")" "$(hash12 "$link")"
    done
    echo "[DRY-RUN] candidate_usa_hashes_end"
  fi
}

load_config

if [ "$DRY_RUN" = "0" ]; then
  echo "[SAFE-PODKOP-GUARD] Preparing guard before Remnawave subscription update..."
  ensure_guard_cron
  if ! guard_precheck; then
    echo "[SAFE-PODKOP-GUARD][ERROR] Podkop subnet lists are not downloadable now."
    echo "[SAFE-PODKOP-GUARD][ERROR] Skip Remnawave subscription update to avoid breaking live Podkop routing."
    guard_apply
    ensure_guard_cron
    exit 30
  fi
fi

download_subscription
build_candidate_files

if [ "$MAIN_CANDIDATE_COUNT" -eq 0 ] && [ "$MAIN_MANUAL_COUNT" -eq 0 ]; then
  echo "[ERROR] main section would become empty. Refusing to apply."
  exit 1
fi

if [ "$DRY_RUN" = "1" ]; then
  print_dry_run
  exit 0
fi

print_summary
mkdir -p "$BACKUP_ROOT"
chmod 700 "$BACKUP_ROOT" 2>/dev/null || true
BACKUP_DIR="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp -a /etc/config/podkop "$BACKUP_DIR/podkop"
[ -f /etc/sing-box/config.json ] && cp -a /etc/sing-box/config.json "$BACKUP_DIR/config.json" || true
[ -f "$CONF" ] && cp -a "$CONF" "$BACKUP_DIR/subscription.conf" || true
echo "[INFO] Backup saved: $BACKUP_DIR"

ensure_section "$MAIN_SEC"

{
  write_urltest_section "$MAIN_SEC" "$TMP_MAIN_MANUAL" "$TMP_MAIN_CANDIDATE"

  if [ "$USA_EXISTS" -eq 1 ]; then
    if [ "$USA_CANDIDATE_COUNT" -gt 0 ] || [ "$USA_MANUAL_COUNT" -gt 0 ]; then
      write_urltest_section "$USA_SEC" "$TMP_USA_MANUAL" "$TMP_USA_CANDIDATE"
    else
      echo "[INFO] USA section exists but has no links. Leaving it unchanged." >&2
    fi
  fi

  echo "commit ${UCI_CFG}"
} > "$TMP_UCI"

uci -q batch < "$TMP_UCI"

if restart_podkop_safely && validate_after_apply; then
  guard_apply
  ensure_guard_cron
  apply_runtime_protection
  check_tailscale_after_podkop
  echo "[OK] Podkop updated from Remnawave subscription."
  exit 0
fi

rollback_from_backup "$BACKUP_DIR"
exit 1
