#!/bin/sh
set -eu

LINK_SCHEMES='(vless|ss|trojan|hysteria2|hy2)'

section() {
  echo
  echo "=== $* ==="
}

cmd_state() {
  if command -v "$1" >/dev/null 2>&1; then
    echo present
  else
    echo missing
  fi
}

service_status() {
  svc="$1"

  if [ -x "/etc/init.d/$svc" ]; then
    "/etc/init.d/$svc" status 2>&1 | head -n 3 || true
  else
    echo "missing"
  fi
}

sanitize_logs() {
  sed 's#https\{0,1\}://[^[:space:]]*#URL***MASKED***#g; s#vless://[^[:space:]]*#vless://***MASKED***#g; s#trojan://[^[:space:]]*#trojan://***MASKED***#g; s#ss://[^[:space:]]*#ss://***MASKED***#g; s#hysteria2://[^[:space:]]*#hysteria2://***MASKED***#g; s#hy2://[^[:space:]]*#hy2://***MASKED***#g; s#tskey-[^[:space:]]*#tskey-***MASKED***#g'
}

count_links() {
  proto="$1"
  file="$2"
  grep -c "^${proto}://" "$file" 2>/dev/null || true
}

section "OpenWrt"
if [ -f /etc/openwrt_release ]; then
  sed -n "s/^DISTRIB_DESCRIPTION='/OpenWrt version: /p; s/^DISTRIB_TARGET='/Target: /p; s/^DISTRIB_ARCH='/Arch: /p" /etc/openwrt_release | sed "s/'$//"
else
  echo "OpenWrt release file: missing"
fi
echo "apk: $(cmd_state apk)"
echo "opkg: $(cmd_state opkg)"

section "Services"
echo "podkop:"
service_status podkop
echo "sing-box process:"
pgrep -af sing-box 2>/dev/null | sanitize_logs || echo "not-running"
echo "tailscale:"
service_status tailscale
if command -v tailscale >/dev/null 2>&1; then
  tailscale status 2>/dev/null | sed -n '1,20p' | sanitize_logs || true
fi

section "Podkop proxy link counts"
tmp="/tmp/validate-openwrt-router-links.$$"
: > "$tmp"
uci -q get podkop.main.urltest_proxy_links 2>/dev/null | tr ' ' '\n' | grep -E "^${LINK_SCHEMES}://" > "$tmp" || true
echo "main total: $(wc -l < "$tmp" | tr -d ' ')"
echo "main vless: $(count_links vless "$tmp")"
echo "main ss: $(count_links ss "$tmp")"
echo "main trojan: $(count_links trojan "$tmp")"
echo "main hysteria2: $(count_links hysteria2 "$tmp")"
echo "main hy2: $(count_links hy2 "$tmp")"
: > "$tmp"
uci -q get podkop.USA.urltest_proxy_links 2>/dev/null | tr ' ' '\n' | grep -E "^${LINK_SCHEMES}://" > "$tmp" || true
echo "USA total: $(wc -l < "$tmp" | tr -d ' ')"
rm -f "$tmp"

section "Cron"
if crontab -l >/tmp/validate-openwrt-router-cron.$$ 2>/dev/null; then
  grep -E 'update-podkop-from-remnawave|podkop list_update|apply-podkop-router-output-bypass|podkop-tailscale-protect|podkop-all-lists-guard' /tmp/validate-openwrt-router-cron.$$ || true
elif [ -f /etc/crontabs/root ]; then
  grep -E 'update-podkop-from-remnawave|podkop list_update|apply-podkop-router-output-bypass|podkop-tailscale-protect|podkop-all-lists-guard' /etc/crontabs/root || true
else
  echo "root cron: unavailable"
fi
rm -f /tmp/validate-openwrt-router-cron.$$

section "Routes: table podkop"
ip route show table podkop 2>/dev/null | grep -E '192\.200\.0\.0/24|192\.73\.242\.28|100\.100\.100\.100|100\.64\.0\.0/10|tailscale0' || true

section "nft tailscale_force443"
nft list table inet tailscale_force443 2>/dev/null || echo "tailscale_force443: missing"

section "Recent critical logs"
if command -v logread >/dev/null 2>&1; then
  logread 2>/dev/null \
    | grep -iE 'PollNetMap|map response|context canceled|not-in-map-poll|fatal|panic' \
    | tail -n 80 \
    | sanitize_logs || true
else
  echo "logread: missing"
fi
