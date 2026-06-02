#!/bin/sh
set -eu

# Version: tailscale-remote-access-v2

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

pkg_install_one() {
  p="$1"

  echo "[INFO] Installing package: $p"

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
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//'
}

echo
echo "[STEP] Tailscale settings"

if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
  TS_AUTHKEY="$TAILSCALE_AUTHKEY"
else
  echo "[INFO] Paste Tailscale auth key."
  echo "[INFO] Example: tskey-auth-xxxxxxxxxxxxxxxx"
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
echo "[STEP] Installing Tailscale..."
pkg_install_one tailscale

if [ ! -x /etc/init.d/tailscale ]; then
  echo "[ERROR] /etc/init.d/tailscale not found after install."
  exit 1
fi

echo
echo "[STEP] Enabling and starting Tailscale service..."
/etc/init.d/tailscale enable || true
/etc/init.d/tailscale start || true

sleep 3

if ! pgrep -af tailscaled >/dev/null 2>&1; then
  echo "[WARN] tailscaled process not found. Trying service restart..."
  /etc/init.d/tailscale restart || true
  sleep 5
fi

if ! pgrep -af tailscaled >/dev/null 2>&1; then
  echo "[ERROR] tailscaled is not running."
  echo "[INFO] Check logs:"
  echo "logread | grep -i tailscale | tail -n 120"
  exit 1
fi

echo
echo "[STEP] Checking current Tailscale status..."
tailscale status 2>/dev/null || true

echo
echo "[STEP] Running tailscale up..."

TAILSCALE_EXTRA_ARGS="${TAILSCALE_EXTRA_ARGS:-}"

if [ -n "$TS_AUTHKEY" ]; then
  echo "[INFO] Using provided Tailscale auth key."
  echo "[INFO] No browser login should be required."

  tailscale up \
    --authkey="$TS_AUTHKEY" \
    --hostname="$TS_HOSTNAME" \
    --accept-dns=false \
    $TAILSCALE_EXTRA_ARGS
else
  echo "[INFO] No Tailscale auth key provided."
  echo "[INFO] Tailscale will print an auth URL. Open it in browser and approve this router."

  tailscale up \
    --hostname="$TS_HOSTNAME" \
    --accept-dns=false \
    $TAILSCALE_EXTRA_ARGS
fi

echo
echo "[STEP] Final Tailscale status:"
tailscale status || true

echo
echo "[INFO] Tailscale IPv4:"
tailscale ip -4 2>/dev/null || true

echo
echo "[OK] Remote access via Tailscale is installed."
echo
echo "Use from your laptop:"
echo "  ssh root@TAILSCALE_IP"
echo "  http://TAILSCALE_IP/"
echo "  http://TAILSCALE_IP:9090/  # YACD / sing-box API, if enabled"
echo
echo "[SECURITY] No WAN ports were opened."
echo "[SECURITY] Keep SSH/LuCI closed from WAN; use Tailscale IP for remote access."

