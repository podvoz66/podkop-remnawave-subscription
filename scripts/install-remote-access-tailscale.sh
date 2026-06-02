#!/bin/sh
set -eu

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

if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
  echo "[INFO] Using TAILSCALE_AUTHKEY from environment."
  tailscale up \
    --authkey="$TAILSCALE_AUTHKEY" \
    --accept-dns=false \
    $TAILSCALE_EXTRA_ARGS
else
  echo "[INFO] No TAILSCALE_AUTHKEY provided."
  echo "[INFO] Tailscale will print an auth URL. Open it in browser and approve this router."
  tailscale up \
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
