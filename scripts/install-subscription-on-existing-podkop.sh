#!/bin/sh
set -eu

APP_DIR="/etc/podkop-remnawave"
CONF="$APP_DIR/subscription.conf"
UPDATER="/usr/bin/update-podkop-from-remnawave.sh"
LOG="/tmp/podkop-sub-update.log"
CRON_LINE="0 */4 * * * /usr/bin/update-podkop-from-remnawave.sh >/tmp/podkop-sub-update.log 2>&1"

REPO_UPDATER_URL="https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main/scripts/update-podkop-from-remnawave.sh"
PODKOP_INSTALL_URL="https://raw.githubusercontent.com/itdoginfo/podkop/main/install.sh"

echo "=== Existing OpenWrt Podkop -> Remnawave subscription installer ==="

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

if [ ! -f /etc/config/podkop ]; then
echo "[ERROR] /etc/config/podkop not found."
echo "[ERROR] This script is for routers where Podkop is already installed."
echo "[INFO] For clean routers use install.sh from this repository."
exit 1
fi

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

if command -v "$p" >/dev/null 2>&1; then
return 0
fi

echo "[INFO] Installing package: $p"

if [ "$PKG" = "apk" ]; then
apk add "$p" || echo "[WARN] Package install failed or unavailable: $p"
else
opkg install "$p" || echo "[WARN] Package install failed or unavailable: $p"
fi
}

fetch() {
url="$1"
out="$2"

if command -v curl >/dev/null 2>&1; then
curl -fsSL "$url" -o "$out"
elif command -v wget >/dev/null 2>&1; then
wget -O "$out" "$url"
else
echo "[ERROR] Need curl or wget."
exit 1
fi
}

mkdir -p "$APP_DIR/backups"
chmod 700 "$APP_DIR" "$APP_DIR/backups"

STAMP="$(date +%Y%m%d-%H%M%S)"

echo
echo "[STEP] Backup current Podkop and Remnawave updater state..."

cp /etc/config/podkop "$APP_DIR/backups/podkop.config.before-existing-install.$STAMP"

if [ -f "$CONF" ]; then
cp "$CONF" "$APP_DIR/backups/subscription.conf.before-existing-install.$STAMP"
fi

if [ -f "$UPDATER" ]; then
cp "$UPDATER" "$APP_DIR/backups/update-podkop-from-remnawave.before-existing-install.$STAMP"
fi

echo "[INFO] Backup dir: $APP_DIR/backups"

echo
echo "[STEP] Updating package lists..."
pkg_update

echo
echo "[STEP] Installing base tools..."
pkg_install_one curl
pkg_install_one wget
pkg_install_one grep
pkg_install_one sed
pkg_install_one ca-bundle
pkg_install_one ca-certificates

echo
echo "[STEP] Updating Podkop, best effort..."

fetch "$PODKOP_INSTALL_URL" /tmp/podkop-install.sh
chmod +x /tmp/podkop-install.sh

if sh /tmp/podkop-install.sh; then
echo "[OK] Podkop installer/update finished."
else
echo "[WARN] Podkop installer returned an error."
echo "[WARN] Existing Podkop config backup is saved."
echo "[WARN] Continuing with Remnawave updater installation."
fi

if [ ! -f /etc/config/podkop ]; then
echo "[ERROR] /etc/config/podkop disappeared after Podkop update. Stop."
exit 1
fi

echo
echo "[STEP] Remnawave subscription URL"

if [ -n "${SUB_URL:-}" ]; then
REMNA_SUB_URL="$SUB_URL"
else
printf "Paste Remnawave subscription URL: "
read -r REMNA_SUB_URL
fi

if [ -z "$REMNA_SUB_URL" ]; then
echo "[ERROR] Empty subscription URL."
exit 1
fi

case "$REMNA_SUB_URL" in
http://*|https://*) ;;
*)
echo "[ERROR] Subscription URL must start with http:// or https://"
exit 1
;;
esac

cat >"$CONF" <<EOF
SUB_URL='$REMNA_SUB_URL'
EOF

chmod 600 "$CONF"

echo
echo "[STEP] Optional split-DNS override"

if [ -n "${SUB_HOST_IP:-}" ]; then
SUB_HOST="$(printf '%s' "$REMNA_SUB_URL" | sed -E 's#^https?://([^/:]+).*#\1#')"

echo "[INFO] Adding DNS override: $SUB_HOST -> $SUB_HOST_IP"

uci add dhcp domain >/dev/null
uci set dhcp.@domain[-1].name="$SUB_HOST"
uci set dhcp.@domain[-1].ip="$SUB_HOST_IP"
uci commit dhcp
/etc/init.d/dnsmasq restart || true
else
echo "[INFO] No SUB_HOST_IP provided. Skipping split-DNS override."
fi

echo
echo "[STEP] Installing Remnawave updater..."

fetch "$REPO_UPDATER_URL" "$UPDATER"
chmod +x "$UPDATER"

echo
echo "[STEP] Installing cron job..."

grep -v 'update-podkop-from-remnawave.sh' /etc/crontabs/root 2>/dev/null > /tmp/root.cron.$$ || true
echo "$CRON_LINE" >> /tmp/root.cron.$$
cat /tmp/root.cron.$$ > /etc/crontabs/root
rm -f /tmp/root.cron.$$

/etc/init.d/cron restart || true

echo
echo "[STEP] First Remnawave update..."

if "$UPDATER" >"$LOG" 2>&1; then
cat "$LOG"
else
echo "[ERROR] First update failed. Log:"
cat "$LOG" || true
exit 1
fi

echo
echo "=== Verification ==="

echo
echo "[INFO] sing-box:"
pgrep -af sing-box || true

echo
echo "[INFO] listeners:"
netstat -lntup 2>/dev/null | grep -E '1602|9090|sing|podkop' || true

echo
echo "[INFO] Podkop main links:"
uci show podkop.main 2>/dev/null | grep 'urltest_proxy_links' || true

echo
echo "[INFO] Podkop USA links, if section exists:"
uci show podkop.USA 2>/dev/null | grep 'urltest_proxy_links' || true

echo
echo "[INFO] cron:"
grep 'update-podkop-from-remnawave.sh' /etc/crontabs/root || true

echo
echo "[OK] Existing Podkop router updated and connected to Remnawave subscription."
echo "[INFO] Config: $CONF"
echo "[INFO] Updater: $UPDATER"
echo "[INFO] Log: $LOG"
echo "[INFO] Backups: $APP_DIR/backups"
