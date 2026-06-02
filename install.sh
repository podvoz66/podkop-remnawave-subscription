#!/bin/sh
set -eu

CONF='/etc/podkop-remnawave/subscription.conf'

if [ ! -f "$CONF" ]; then
  echo "[ERROR] Missing config: $CONF"
  echo "[ERROR] Expected it to contain: SUB_URL='https://...'"
  exit 1
fi

. "$CONF"

if [ -z "${SUB_URL:-}" ]; then
  echo "[ERROR] SUB_URL is empty in $CONF"
  exit 1
fi

UCI_CFG='podkop'
MAIN_SEC='main'
USA_SEC='USA'
MANAGED_SUFFIX='-rwsub'

UA='Podkop-OpenWrt/1.0'
TIMEOUT='25'

TMP_SUB="/tmp/remnawave-sub.$$"
TMP_TXT="/tmp/remnawave-sub.$$.txt"
TMP_ALL="/tmp/remnawave-vless-all.$$.list"
TMP_MAIN_SRC="/tmp/remnawave-vless-main-src.$$.list"
TMP_USA_SRC="/tmp/remnawave-vless-usa-src.$$.list"
TMP_MAIN_KEEP="/tmp/podkop-main-keep.$$.list"
TMP_USA_KEEP="/tmp/podkop-usa-keep.$$.list"
TMP_UCI="/tmp/podkop-uci.$$.batch"

cleanup() {
  rm -f "$TMP_SUB" "$TMP_TXT" "$TMP_ALL" "$TMP_MAIN_SRC" "$TMP_USA_SRC" "$TMP_MAIN_KEEP" "$TMP_USA_KEEP" "$TMP_UCI"
}
trap cleanup EXIT

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

normalize_reality_links() {
  sed '/security=reality/ { /[?&]spx=/! s/#/\&spx=%2F#/; }'
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
  link="$1"

  case "$link" in
    *"${MANAGED_SUFFIX}"|*"#rwsub") return 0 ;;
    *) return 1 ;;
  esac
}

strip_managed_marker() {
  sed "s/${MANAGED_SUFFIX}$//; s/#rwsub$//"
}

collect_manual_links() {
  sec="$1"
  current_src_file="$2"
  output_file="$3"

  : > "$output_file"

  if ! section_exists "$sec"; then
    return 0
  fi

  uci -q get "${UCI_CFG}.${sec}.urltest_proxy_links" 2>/dev/null \
    | tr ' ' '\n' \
    | grep '^vless://' \
    | while IFS= read -r link; do
        [ -n "$link" ] || continue

        if is_managed_link "$link"; then
          continue
        fi

        norm="$(printf '%s\n' "$link" | strip_managed_marker)"

        if grep -Fxq "$norm" "$current_src_file" 2>/dev/null; then
          continue
        fi

        printf '%s\n' "$link"
      done >> "$output_file" || true
}

write_urltest_section() {
  sec="$1"
  keep_file="$2"
  managed_src_file="$3"

  echo "set ${UCI_CFG}.${sec}.connection_type='proxy'"
  echo "set ${UCI_CFG}.${sec}.proxy_config_type='urltest'"
  echo "del ${UCI_CFG}.${sec}.proxy_string"
  echo "del ${UCI_CFG}.${sec}.urltest_proxy_links"

  if [ -s "$keep_file" ]; then
    while IFS= read -r link; do
      [ -n "$link" ] || continue
      esc="$(printf "%s" "$link" | sed "s/'/'\\\\''/g")"
      echo "add_list ${UCI_CFG}.${sec}.urltest_proxy_links='${esc}'"
    done < "$keep_file"
  fi

  if [ -s "$managed_src_file" ]; then
    while IFS= read -r link; do
      [ -n "$link" ] || continue
      marked="$(mark_managed_link "$link")"
      esc="$(printf "%s" "$marked" | sed "s/'/'\\\\''/g")"
      echo "add_list ${UCI_CFG}.${sec}.urltest_proxy_links='${esc}'"
    done < "$managed_src_file"
  fi

  echo "set ${UCI_CFG}.${sec}.urltest_check_interval='3m'"
  echo "set ${UCI_CFG}.${sec}.urltest_tolerance='50'"
  echo "set ${UCI_CFG}.${sec}.urltest_testing_url='https://www.gstatic.com/generate_204'"
}

echo "[INFO] Downloading Remnawave subscription..."

curl -fsSL \
  --connect-timeout "$TIMEOUT" \
  --max-time "$TIMEOUT" \
  -H "User-Agent: $UA" \
  -H "Accept: */*" \
  "$SUB_URL" \
  -o "$TMP_SUB"

if grep -q 'vless://' "$TMP_SUB"; then
  cp "$TMP_SUB" "$TMP_TXT"
else
  if base64 -d "$TMP_SUB" > "$TMP_TXT" 2>/dev/null; then
    :
  else
    echo "[ERROR] Cannot decode subscription as base64 and no vless:// found."
    echo "[DEBUG] First 300 bytes:"
    head -c 300 "$TMP_SUB" | sed 's/[^[:print:]\t]/?/g'
    echo
    exit 1
  fi
fi

grep -Eo 'vless://[^[:space:]]+' "$TMP_TXT" \
  | normalize_reality_links \
  > "$TMP_ALL" || true

if [ ! -s "$TMP_ALL" ]; then
  echo "[ERROR] No vless:// links found in subscription."
  exit 1
fi

USA_EXISTS=0
if section_exists "$USA_SEC"; then
  USA_EXISTS=1
fi

if [ "$USA_EXISTS" -eq 1 ]; then
  grep -E '@us\.adeptpro\.online:443|#.*us|#.*US|#.*usa|#.*USA' "$TMP_ALL" > "$TMP_USA_SRC" || true
  grep -Ev '@us\.adeptpro\.online:443|#.*us|#.*US|#.*usa|#.*USA' "$TMP_ALL" > "$TMP_MAIN_SRC" || true

  if [ ! -s "$TMP_MAIN_SRC" ] && [ -s "$TMP_USA_SRC" ]; then
    echo "[INFO] All Remnawave links look like USA links; main will preserve manual links only."
  fi
else
  cp "$TMP_ALL" "$TMP_MAIN_SRC"
  : > "$TMP_USA_SRC"
fi

ALL_COUNT="$(wc -l < "$TMP_ALL" | tr -d ' ')"
MAIN_RW_COUNT="$(wc -l < "$TMP_MAIN_SRC" | tr -d ' ')"
USA_RW_COUNT="$(wc -l < "$TMP_USA_SRC" | tr -d ' ')"

echo "[INFO] Found VLESS links total: $ALL_COUNT"
echo "[INFO] USA section exists: $USA_EXISTS"
echo "[INFO] Remnawave links for main: $MAIN_RW_COUNT"
echo "[INFO] Remnawave links for USA: $USA_RW_COUNT"

if [ "$ALL_COUNT" -lt 1 ]; then
  echo "[ERROR] Subscription contains no VLESS links. Refusing to apply."
  exit 1
fi

if [ "$USA_EXISTS" -eq 0 ] && [ "$MAIN_RW_COUNT" -lt 1 ]; then
  echo "[ERROR] main would receive zero Remnawave links. Refusing to apply."
  exit 1
fi

BACKUP="/etc/config/podkop.backup.$(date +%Y%m%d-%H%M%S)"
cp /etc/config/podkop "$BACKUP"
echo "[INFO] Backup saved: $BACKUP"

ensure_section "$MAIN_SEC"

collect_manual_links "$MAIN_SEC" "$TMP_MAIN_SRC" "$TMP_MAIN_KEEP"

if [ "$USA_EXISTS" -eq 1 ]; then
  collect_manual_links "$USA_SEC" "$TMP_USA_SRC" "$TMP_USA_KEEP"
fi

MAIN_MANUAL_COUNT="$(wc -l < "$TMP_MAIN_KEEP" | tr -d ' ')"
USA_MANUAL_COUNT=0

if [ "$USA_EXISTS" -eq 1 ]; then
  USA_MANUAL_COUNT="$(wc -l < "$TMP_USA_KEEP" | tr -d ' ')"
fi

echo "[INFO] Preserved manual links in main: $MAIN_MANUAL_COUNT"

if [ "$USA_EXISTS" -eq 1 ]; then
  echo "[INFO] Preserved manual links in USA: $USA_MANUAL_COUNT"
fi

{
  write_urltest_section "$MAIN_SEC" "$TMP_MAIN_KEEP" "$TMP_MAIN_SRC"

  if [ "$USA_EXISTS" -eq 1 ]; then
    write_urltest_section "$USA_SEC" "$TMP_USA_KEEP" "$TMP_USA_SRC"
  fi

  echo "commit ${UCI_CFG}"
} > "$TMP_UCI"

uci -q batch < "$TMP_UCI"

echo "[INFO] Restarting Podkop..."
/etc/init.d/podkop restart

sleep 10

if pgrep -af sing-box >/dev/null 2>&1; then
  echo "[OK] sing-box is running."
else
  echo "[WARN] sing-box process was not found after restart."
  echo "[WARN] Check: logread | grep -iE 'podkop|sing-box|error|failed|fatal|panic' | tail -n 120"
fi

echo "[OK] Podkop updated from Remnawave subscription."
