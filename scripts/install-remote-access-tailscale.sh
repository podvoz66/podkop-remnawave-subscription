#!/bin/sh
set -eu

# Version: tailscale-remote-access-v3

echo "=== OpenWrt remote access via Tailscale ==="

if [ "$(id -u)" != "0" ]; then
  echo "[ERROR] Run as root."
  exit 1
fi

if [ ! -f /etc/openwrt_release ]; then
  echo "[ERROR] This does not look like OpenWrt."
  exit 1
fi

echo
echo "[INFO] OpenWrt release:"
cat /etc/openwrt_release || true

if command -v apk >/dev/null 2>&1; then
  PKG="apk"
elif command -v opkg >/dev/null 2>&1; then
  PKG="opkg"
else
  echo "[ERROR] Neither apk nor opkg found."
  exit 1
fi

pkg_update() {
  if [ "$PKG" = "apk" ]; then
    apk update
  else
    opkg update
  fi
}

pkg_is_installed() {
  p="$1"

  if [ "$PKG" = "apk" ]; then
    apk info -e "$p" >/dev/null 2>&1
  else
    opkg list-installed "$p" 2>/dev/null | grep -q "^${p} "
  fi
}

pkg_install_one() {
  p="$1"

  if pkg_is_installed "$p"; then
    echo "[OK] Package already installed: $p"
    return 0
  fi

  echo "[STEP] Installing package: $p"

  if [ "$PKG" = "apk" ]; then
    apk add "$p" || {
      echo "[ERROR] Failed to install package: $p"
      exit 1
    }
  else
    opkg install "$p" || {
      echo "[ERROR] Failed to install package: $p"
      exit 1
    }
  fi
}

read_from_tty() {
  prompt="$1"
  var_name="$2"

  if [ -r /dev/tty ]; then
    printf "%s" "$prompt" > /dev/tty
    IFS= read -r value < /dev/tty
  else
    printf "%s" "$prompt"
    IFS= read -r value
  fi

  eval "$var_name=\$value"
}

sanitize_hostname() {
  name="$1"

  printf '%s' "$name" \
    | tr 'A-Z' 'a-z' \
    | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//'
}

stop_orphan_singbox_for_tailscale() {
  echo
  echo "[STEP] Checking for orphan sing-box before Tailscale start..."

  if ! pgrep -x sing-box >/dev/null 2>&1; then
    echo "[OK] No sing-box process found."
    return 0
  fi

  echo "[WARN] sing-box process is running."
  echo "[WARN] Stopping Podkop first, if installed."

  # A stale Podkop/sing-box process can keep old transparent proxy rules active
  # and prevent tailscaled from reaching the Tailscale coordination server.
  if [ -x /etc/init.d/podkop ]; then
    /etc/init.d/podkop stop || true
    sleep 3
  else
    echo "[WARN] /etc/init.d/podkop not found."
  fi

  if pgrep -x sing-box >/dev/null 2>&1; then
    echo "[WARN] sing-box is still alive after Podkop stop. Killing stale process..."
    killall sing-box || true
    sleep 2
  fi

  if pgrep -x sing-box >/dev/null 2>&1; then
    echo "[ERROR] sing-box is still running after killall."
    pgrep -af sing-box || true
    exit 1
  fi

  echo "[OK] No orphan sing-box remains."
}

configure_luci_tailscale_access() {
  if [ "${ENABLE_LUCI_TAILSCALE:-1}" != "1" ]; then
    echo "[INFO] ENABLE_LUCI_TAILSCALE is not 1. Skipping direct SSH/LuCI Tailscale access setup."
    return 0
  fi

  echo
  echo "[STEP] Enable direct SSH/LuCI access through Tailscale"

  helper="/tmp/install-tailscale-direct-access.sh"
  repo_raw_base="${REPO_RAW_BASE:-https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main}"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 25 --max-time 60 \
      "$repo_raw_base/scripts/install-tailscale-direct-access.sh" \
      -o "$helper"
  else
    wget -O "$helper" \
      "$repo_raw_base/scripts/install-tailscale-direct-access.sh"
  fi

  chmod +x "$helper"

  ENABLE_TAILSCALE_SSH_DIRECT="${ENABLE_TAILSCALE_SSH_DIRECT:-1}" \
  ENABLE_TAILSCALE_LUCI_DIRECT="${ENABLE_TAILSCALE_LUCI_DIRECT:-1}" \
  TAILSCALE_ALLOWED_CIDR="${TAILSCALE_ALLOWED_CIDR:-100.64.0.0/10}" \
    sh "$helper"
}

tailscale_status_safe() {
  tailscale status 2>/dev/null || true
}

wait_tailscale_online() {
  i=0

  echo
  echo "[STEP] Waiting for Tailscale online state..."

  while [ "$i" -lt 60 ]; do
    ts_ip="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
    ts_status="$(tailscale status 2>/dev/null || true)"
    self_line="$(printf '%s\n' "$ts_status" | grep -i "[[:space:]]${TS_HOSTNAME}[[:space:]]" | head -n 1 || true)"

    if [ -n "$ts_ip" ]; then
      if [ -z "$self_line" ] || ! printf '%s\n' "$self_line" | grep -qi 'offline'; then
        echo "[OK] Tailscale IPv4: $ts_ip"
        return 0
      fi
    fi

    i=$((i + 1))
    sleep 1
  done

  echo "[ERROR] Tailscale did not become online within 60 seconds."
  echo
  echo "[DEBUG] tailscale status:"
  tailscale status || true
  echo
  echo "[DEBUG] tailscale netcheck:"
  tailscale netcheck || true
  echo
  echo "[DEBUG] recent Tailscale logs:"
  logread | grep -i tailscale | tail -n 120 || true
  echo
  echo "[DEBUG] sing-box processes:"
  pgrep -af sing-box || true
  echo
  echo "[DEBUG] Podkop status:"
  if [ -x /etc/init.d/podkop ]; then
    /etc/init.d/podkop status || true
  else
    echo "/etc/init.d/podkop not found"
  fi

  exit 1
}

run_tailscale_up() {
  echo
  echo "[STEP] Running tailscale up..."

  tmp="/tmp/tailscale-up.$$"

  if [ -n "$TS_AUTHKEY" ]; then
    echo "[INFO] Using provided Tailscale auth key. The key will not be printed."
    if tailscale up --authkey="$TS_AUTHKEY" --accept-dns=false --ssh=false --hostname="$TS_HOSTNAME" >"$tmp" 2>&1; then
      cat "$tmp"
      rm -f "$tmp"
      return 0
    fi
  else
    echo "[INFO] No Tailscale auth key provided."
    echo "[INFO] Tailscale will print an auth URL. Open it in browser and approve this router."
    if tailscale up --accept-dns=false --ssh=false --hostname="$TS_HOSTNAME" >"$tmp" 2>&1; then
      cat "$tmp"
      rm -f "$tmp"
      return 0
    fi
  fi

  if grep -q "changing settings via 'tailscale up' requires mentioning all non-default flags" "$tmp"; then
    echo "[WARN] tailscale up reported a non-default flags warning."
    echo "[WARN] Continuing to online-state validation because required flags were supplied."
    rm -f "$tmp"
    return 0
  fi

  sed 's/tskey-[^[:space:]]*/tskey-***MASKED***/g' "$tmp"
  rm -f "$tmp"
  exit 1
}

echo
echo "[STEP] Tailscale settings"

if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
  TS_AUTHKEY="$TAILSCALE_AUTHKEY"
else
  echo "[INFO] Paste Tailscale auth key."
  echo "[INFO] Leave empty if you want browser login/auth URL instead."
  read_from_tty "Tailscale auth key: " TS_AUTHKEY
fi

if [ -n "${TAILSCALE_HOSTNAME:-}" ]; then
  TS_HOSTNAME="$TAILSCALE_HOSTNAME"
else
  CURRENT_HOSTNAME="$(uci -q get system.@system[0].hostname 2>/dev/null || hostname 2>/dev/null || echo openwrt)"
  echo
  echo "[INFO] Enter router name for Tailscale."
  echo "[INFO] Current/default name: $CURRENT_HOSTNAME"
  read_from_tty "Tailscale router name: " TS_HOSTNAME

  if [ -z "$TS_HOSTNAME" ]; then
    TS_HOSTNAME="$CURRENT_HOSTNAME"
  fi
fi

TS_HOSTNAME="$(sanitize_hostname "$TS_HOSTNAME")"

if [ -z "$TS_HOSTNAME" ]; then
  TS_HOSTNAME="openwrt-router"
fi

echo
echo "[INFO] Tailscale hostname will be: $TS_HOSTNAME"

echo
echo "[STEP] Updating package lists..."
pkg_update

echo
echo "[STEP] Installing Tailscale dependencies..."
pkg_install_one ca-bundle
pkg_install_one ca-certificates
pkg_install_one kmod-tun
# OpenWrt 24.10 uses nftables; these packages provide iptables/ip6tables
# compatibility commands that tailscaled expects when managing firewall state.
pkg_install_one iptables-nft
pkg_install_one ip6tables-nft
pkg_install_one tailscale

if [ ! -x /etc/init.d/tailscale ]; then
  echo "[ERROR] /etc/init.d/tailscale not found after install."
  exit 1
fi

stop_orphan_singbox_for_tailscale

echo
echo "[STEP] Enabling and starting Tailscale service..."
/etc/init.d/tailscale enable || true
/etc/init.d/tailscale restart || true

sleep 5

if ! pgrep -af tailscaled >/dev/null 2>&1; then
  echo "[ERROR] tailscaled is not running."
  echo "[INFO] Check logs:"
  echo "logread | grep -i tailscale | tail -n 120"
  exit 1
fi

echo
echo "[STEP] Current Tailscale status:"
tailscale_status_safe

run_tailscale_up
wait_tailscale_online
configure_luci_tailscale_access

TAILSCALE_IP="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"

echo
echo "[STEP] Final Tailscale status:"
tailscale status || true

echo
echo "[OK] Remote access via Tailscale is installed."
echo "[INFO] Tailscale IPv4: $TAILSCALE_IP"
echo
echo "Use from your laptop:"
echo "  ssh root@$TAILSCALE_IP"
echo "  http://$TAILSCALE_IP/"
echo "  http://$TAILSCALE_IP:9090/  # YACD / sing-box API, if enabled"
echo
echo "[SECURITY] No WAN ports were opened."
echo "[SECURITY] Keep SSH/LuCI closed from WAN; use Tailscale IP for remote access."
echo "[WARN] Podkop/sing-box may have been stopped to restore remote access."
echo "[WARN] Do not start Podkop back until routing exclusions are checked."
