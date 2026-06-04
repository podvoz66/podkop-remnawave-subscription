#!/bin/sh
set -eu

# Configure direct SSH/LuCI access from Tailscale peers on OpenWrt.
# Safe defaults:
# - allows only Tailnet IPv4 range 100.64.0.0/10
# - opens only router-local TCP ports 22, 80, 443
# - does not open WAN ports
# - does not create port forwarding
# - keeps forwarding from Tailscale rejected unless configured elsewhere

TAILSCALE_ALLOWED_CIDR="${TAILSCALE_ALLOWED_CIDR:-100.64.0.0/10}"
ENABLE_TAILSCALE_SSH_DIRECT="${ENABLE_TAILSCALE_SSH_DIRECT:-1}"
ENABLE_TAILSCALE_LUCI_DIRECT="${ENABLE_TAILSCALE_LUCI_DIRECT:-1}"

echo "=== Configure direct OpenWrt access from Tailscale ==="

if [ "$(id -u)" != "0" ]; then
  echo "[ERROR] Run as root."
  exit 1
fi

if [ ! -f /etc/openwrt_release ]; then
  echo "[ERROR] This does not look like OpenWrt."
  exit 1
fi

stamp="$(date +%Y%m%d-%H%M%S)"

if [ -f /etc/config/firewall ]; then
  cp /etc/config/firewall "/etc/config/firewall.backup-tailscale-direct-access-$stamp"
  echo "[INFO] Firewall backup: /etc/config/firewall.backup-tailscale-direct-access-$stamp"
fi

if [ -f /etc/config/uhttpd ]; then
  cp /etc/config/uhttpd "/etc/config/uhttpd.backup-tailscale-direct-access-$stamp"
  echo "[INFO] uHTTPd backup: /etc/config/uhttpd.backup-tailscale-direct-access-$stamp"
fi

ensure_service_enabled() {
  svc="$1"
  if [ -x "/etc/init.d/$svc" ]; then
    /etc/init.d/"$svc" enable || true
  fi
}

restart_service_if_present() {
  svc="$1"
  if [ -x "/etc/init.d/$svc" ]; then
    /etc/init.d/"$svc" restart || true
  fi
}

find_firewall_rule_by_name() {
  name="$1"
  uci show firewall 2>/dev/null | sed -n "s/^\(firewall\.[^=]*\)=rule$/\1/p" | while IFS= read -r section; do
    if [ "$(uci -q get "$section.name" 2>/dev/null || true)" = "$name" ]; then
      echo "$section"
      break
    fi
  done
}

ensure_tailnet_input_rule() {
  name="$1"
  ports="$2"

  section="$(find_firewall_rule_by_name "$name" | head -n 1 || true)"

  if [ -z "$section" ]; then
    uci add firewall rule >/dev/null
    section="firewall.@rule[-1]"
    echo "[INFO] Creating firewall rule: $name"
  else
    echo "[INFO] Updating firewall rule: $name"
  fi

  uci set "$section.name=$name"
  uci set "$section.src=*"
  uci set "$section.src_ip=$TAILSCALE_ALLOWED_CIDR"
  uci set "$section.proto=tcp"
  uci set "$section.dest_port=$ports"
  uci set "$section.target=ACCEPT"
  uci set "$section.family=ipv4"
  uci set "$section.enabled=1"
}

echo "[STEP] Enable autostart for remote-access services"
ensure_service_enabled tailscale
ensure_service_enabled dropbear
ensure_service_enabled uhttpd

echo "[STEP] Allow LuCI to answer through Tailscale"
if [ -f /etc/config/uhttpd ]; then
  uci set uhttpd.main.rfc1918_filter='0'
  uci commit uhttpd
else
  echo "[WARN] /etc/config/uhttpd not found; skipping rfc1918_filter change."
fi

echo "[STEP] Add firewall rules for Tailnet direct access"
if [ "$ENABLE_TAILSCALE_SSH_DIRECT" = "1" ]; then
  ensure_tailnet_input_rule "Allow-SSH-from-Tailscale" "22"
fi

if [ "$ENABLE_TAILSCALE_LUCI_DIRECT" = "1" ]; then
  ensure_tailnet_input_rule "Allow-LuCI-from-Tailscale" "80 443"
fi

uci commit firewall

echo "[STEP] Restart services"
restart_service_if_present firewall
restart_service_if_present uhttpd
restart_service_if_present dropbear
restart_service_if_present tailscale

sleep 5

echo
echo "=== Local checks ==="
echo "[INFO] Tailscale IP:"
tailscale ip -4 2>/dev/null || true

echo
echo "[INFO] Listening ports:"
netstat -lntp 2>/dev/null | grep -E ':22|:80|:443' || true

echo
echo "[INFO] Firewall rules:"
uci show firewall | grep -E 'Allow-SSH-from-Tailscale|Allow-LuCI-from-Tailscale' || true

echo
echo "[OK] Direct access rules installed."
echo
echo "Check from your laptop, not from the router:"
echo '  & "C:\Program Files\Tailscale\tailscale.exe" ping ROUTER_TAILSCALE_IP'
echo "  curl.exe -I http://ROUTER_TAILSCALE_IP"
echo "  ssh root@ROUTER_TAILSCALE_IP"
