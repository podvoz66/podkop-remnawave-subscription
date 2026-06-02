#!/bin/sh
set -eu

REPO_UPDATER_URL="https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main/scripts/update-podkop-from-remnawave.sh"
PODKOP_INSTALL_URL="https://raw.githubusercontent.com/itdoginfo/podkop/main/install.sh"

APP_DIR="/etc/podkop-remnawave"
CONF="$APP_DIR/subscription.conf"
UPDATER="/usr/bin/update-podkop-from-remnawave.sh"
LOG="/tmp/podkop-sub-update.log"
CRON_LINE="0 */4 * * * /usr/bin/update-podkop-from-remnawave.sh >/tmp/podkop-sub-update.log 2>&1"

echo "=== Podkop + Remnawave installer for OpenWrt ==="

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
    apk add "$p" || echo "[WARN] Package install failed or unavailable: $p"
  else
    opkg install "$p" || echo "[WARN] Package install failed or unavailable: $p"
  fi
}

pkg_install_many() {
  for p in "$@"; do
    pkg_install_one "$p"
  done
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

run_podkop_installer_non_interactive() {
  echo "[INFO] Running Podkop installer in non-interactive mode..."
  echo "[INFO] Auto-answering Podkop prompts with: y"

  # The official Podkop installer may ask "Введите y или n" for Russian language.
  # When our script is started as "wget -O - ... | sh", stdin is not interactive,
  # so the Podkop installer can loop forever. This pipe feeds "y" repeatedly.
  (
    while true; do
      printf 'y\n'
      sleep 1
    done
  ) | sh /tmp/podkop-install.sh
}

echo
echo "[STEP] Updating package lists..."
pkg_update

echo
echo "[STEP] Installing base tools..."
pkg_install_many ca-bundle ca-certificates curl wget grep sed coreutils-base64

echo
echo "[STEP] Installing Russian LuCI localization, best effort..."
pkg_install_many \
  luci-i18n-base-ru \
  luci-i18n-firewall-ru \
  luci-i18n-ttyd-ru \
  luci-i18n-package-manager-ru \
  luci-i18n-opkg-ru \
  luci-i18n-uhttpd-ru

echo
echo "[STEP] Installing ttyd, best effort..."
pkg_install_many ttyd luci-app-ttyd

if [ -x /etc/init.d/ttyd ]; then
  /etc/init.d/ttyd enable || true
  /etc/init.d/ttyd restart || true
fi

echo
echo "[STEP] Installing Podkop..."

if [ ! -f /etc/init.d/podkop ]; then
  fetch "$PODKOP_INSTALL_URL" /tmp/podkop-install.sh
  chmod +x /tmp/podkop-install.sh

  if run_podkop_installer_non_interactive; then
    echo "[OK] Podkop installer finished."
  else
    echo "[ERROR] Podkop install failed."
    echo "[INFO] Check logs above. You may need to install Podkop manually, then rerun this installer."
    exit 1
  fi
else
  echo "[INFO] Podkop already installed."
fi

if [ ! -f /etc/config/podkop ]; then
  echo "[ERROR] /etc/config/podkop not found after Podkop installation."
  exit 1
fi

echo
echo "[STEP] Remnawave subscription URL"

if [ -n "${SUB_URL:-}" ]; then
  REMNA_SUB_URL="$SUB_URL"
else
  read_from_tty "Paste Remnawave subscription URL: " REMNA_SUB_URL
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

mkdir -p "$APP_DIR/backups"
chmod 700 "$APP_DIR" "$APP_DIR/backups"

STAMP="$(date +%Y%m%d-%H%M%S)"

if [ -f "$CONF" ]; then
  cp "$CONF" "$APP_DIR/backups/subscription.conf.backup.$STAMP"
fi

if [ -f "$UPDATER" ]; then
  cp "$UPDATER" "$APP_DIR/backups/update-podkop-from-remnawave.sh.backup.$STAMP"
fi

cp /etc/config/podkop "$APP_DIR/backups/podkop.config.backup.$STAMP"

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
  echo "[INFO] If your subscription domain points to router WAN/public IP from LAN, rerun with:"
  echo "       SUB_HOST_IP='192.168.0.172' wget -O - https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main/install.sh | sh"
fi

echo
echo "[STEP] Installing Remnawave updater..."

if fetch "$REPO_UPDATER_URL" "$UPDATER"; then
  chmod +x "$UPDATER"
else
  echo "[ERROR] Failed to download updater from GitHub:"
  echo "$REPO_UPDATER_URL"
  exit 1
fi

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
echo "[OK] Installation complete."
echo "[INFO] Config: $CONF"
echo "[INFO] Updater: $UPDATER"
echo "[INFO] Log: $LOG"
echo "[INFO] Backups: $APP_DIR/backups"
