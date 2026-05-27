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

UA='Podkop-OpenWrt/1.0'
TIMEOUT='25'

TMP_SUB="/tmp/remnawave-sub.$$"
TMP_TXT="/tmp/remnawave-sub.$$.txt"
TMP_ALL="/tmp/remnawave-vless-all.$$.list"
TMP_MAIN="/tmp/remnawave-vless-main.$$.list"
TMP_USA="/tmp/remnawave-vless-usa.$$.list"
TMP_UCI="/tmp/podkop-uci.$$.batch"

cleanup() {
  rm -f "$TMP_SUB" "$TMP_TXT" "$TMP_ALL" "$TMP_MAIN" "$TMP_USA" "$TMP_UCI"
}
trap cleanup EXIT

ensure_section() {
  sec="$1"

  if ! uci -q show "${UCI_CFG}.${sec}" >/dev/null 2>&1; then
    echo "[INFO] Creating podkop.${sec} section"
    anon="$(uci add "$UCI_CFG" section)"
    uci rename "${UCI_CFG}.${anon}=${sec}"
  fi
}

write_urltest_section() {
  sec="$1"
  list_file="$2"

  echo "set ${UCI_CFG}.${sec}.connection_type='proxy'"
  echo "set ${UCI_CFG}.${sec}.proxy_config_type='urltest'"
  echo "del ${UCI_CFG}.${sec}.proxy_string"
  echo "del ${UCI_CFG}.${sec}.urltest_proxy_links"

  while IFS= read -r link; do
    [ -n "$link" ] || continue
    esc="$(printf "%s" "$link" | sed "s/'/'\\\\''/g")"
    echo "add_list ${UCI_CFG}.${sec}.urltest_proxy_links='${esc}'"
  done < "$list_file"

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

# Extract VLESS links and normalize REALITY links for Podkop/sing-box.
# Some clients need explicit spx=%2F; AutoXray includes it, Remnawave may omit it.
grep -Eo 'vless://[^[:space:]]+' "$TMP_TXT" \
  | sed '/security=reality/ { /[?&]spx=/! s/#/\&spx=%2F#/; }' \
  > "$TMP_ALL" || true

if [ ! -s "$TMP_ALL" ]; then
  echo "[ERROR] No vless:// links found in subscription."
  echo "[DEBUG] First 300 bytes decoded/raw:"
  head -c 300 "$TMP_TXT" | sed 's/[^[:print:]\t]/?/g'
  echo
  exit 1
fi

# USA section: only US links.
grep -E '@us\.example\.com:443|#us-direct|@us\.adeptpro\.online:443' "$TMP_ALL" > "$TMP_USA" || true

# main section: everything except US links.
grep -Ev '@us\.example\.com:443|#us-direct|@us\.adeptpro\.online:443' "$TMP_ALL" > "$TMP_MAIN" || true

ALL_COUNT="$(wc -l < "$TMP_ALL" | tr -d ' ')"
MAIN_COUNT="$(wc -l < "$TMP_MAIN" | tr -d ' ')"
USA_COUNT="$(wc -l < "$TMP_USA" | tr -d ' ')"

echo "[INFO] Found VLESS links total: $ALL_COUNT"
echo "[INFO] main links: $MAIN_COUNT"
echo "[INFO] USA links: $USA_COUNT"

if [ "$MAIN_COUNT" -lt 1 ]; then
  echo "[ERROR] main section would become empty. Refusing to apply."
  exit 1
fi

if [ "$USA_COUNT" -lt 1 ]; then
  echo "[ERROR] USA section would become empty. Refusing to apply."
  exit 1
fi

BACKUP="/etc/config/podkop.backup.$(date +%Y%m%d-%H%M%S)"
cp /etc/config/podkop "$BACKUP"
echo "[INFO] Backup saved: $BACKUP"

ensure_section "$MAIN_SEC"
ensure_section "$USA_SEC"

{
  write_urltest_section "$MAIN_SEC" "$TMP_MAIN"
  write_urltest_section "$USA_SEC" "$TMP_USA"
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
