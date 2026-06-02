#!/bin/sh
set -eu

APP_DIR="/etc/podkop-remnawave"
CONF="$APP_DIR/subscription.conf"
UPDATER="/usr/bin/update-podkop-from-remnawave.sh"
LOG="/tmp/podkop-sub-update.log"
CRON_LINE="0 */4 * * * /usr/bin/update-podkop-from-remnawave.sh >/tmp/podkop-sub-update.log 2>&1"

REPO_UPDATER_URL="https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main/scripts/update-podkop-from-remnawave.sh"
PODKOP_INSTALL_URL="https://raw.githubusercontent.com/itdoginfo/podkop/main/install.sh"

UPDATE_PODKOP="${UPDATE_PODKOP:-0}"

echo "=== Existing OpenWrt Podkop -> Remnawave subscription sync ==="

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
    echo "[ERROR] No interactive terminal available."
    echo "[ERROR] Run with SUB_URL variable, for example:"
    echo "SUB_URL='https://sub.example/token' sh /tmp/install-subscription-on-existing-podkop.sh"
    exit 1
  fi

  eval "$var_name=\$value"
}

validate_subscription_before_apply() {
  url="$1"
  tmp="/tmp/remnawave-sub-validate.$$"
  txt="/tmp/remnawave-sub-validate.$$.txt"

  echo
  echo "[STEP] Validating Remnawave subscription before touching Podkop..."

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL \
      --connect-timeout 25 \
      --max-time 25 \
      -H "User-Agent: Podkop-OpenWrt/1.0" \
      -H "Accept: */*" \
      "$url" \
      -o "$tmp"
  else
    wget -O "$tmp" "$url"
  fi

  if grep -Eq '(vless|ss)://' "$tmp"; then
    cp "$tmp" "$txt"
  else
    if base64 -d "$tmp" > "$txt" 2>/dev/null; then
      :
    else
      echo "[ERROR] Subscription is not plain links and not valid base64."
      echo "[DEBUG] First 300 bytes:"
      head -c 300 "$tmp" | sed 's/[^[:print:]\t]/?/g'
      echo
      rm -f "$tmp" "$txt"
      exit 1
    fi
  fi

  if grep -Eq '@0\.0\.0\.0:1|00000000-0000-0000-0000-000000000000|App%20not%20supported|App not supported' "$txt"; then
    echo "[ERROR] Subscription returned placeholder / App not supported link."
    echo "[ERROR] Refusing to continue. Fix Remnawave HWID/user/squad/hosts/settings first."
    grep -E '@0\.0\.0\.0:1|00000000-0000-0000-0000-000000000000|App%20not%20supported|App not supported' "$txt" | sed 's/\?.*/?.../'
    rm -f "$tmp" "$txt"
    exit 1
  fi

  grep -Eo '(vless|ss)://[^[:space:]]+' "$txt" > /tmp/remnawave-links-validate.$$ || true

  LINK_COUNT="$(wc -l < /tmp/remnawave-links-validate.$$ | tr -d ' ')"
  VLESS_COUNT="$(grep -c '^vless://' /tmp/remnawave-links-validate.$$ 2>/dev/null || true)"
  SS_COUNT="$(grep -c '^ss://' /tmp/remnawave-links-validate.$$ 2>/dev/null || true)"

  rm -f "$tmp" "$txt" /tmp/remnawave-links-validate.$$

  if [ "$LINK_COUNT" -lt 1 ]; then
    echo "[ERROR] Subscription contains no vless:// or ss:// links."
    exit 1
  fi

  echo "[OK] Subscription is valid."
  echo "[INFO] Total links: $LINK_COUNT"
  echo "[INFO] VLESS links: $VLESS_COUNT"
  echo "[INFO] Shadowsocks links: $SS_COUNT"
}

run_podkop_installer_non_interactive() {
  echo "[INFO] Running Podkop installer/update in non-interactive mode..."
  echo "[INFO] Auto-answering Podkop prompts with: y"
  echo "[INFO] Timeout: 900 seconds"

  fetch "$PODKOP_INSTALL_URL" /tmp/podkop-install.sh
  chmod +x /tmp/podkop-install.sh

  if command -v timeout >/dev/null 2>&1; then
    timeout 900 sh -c "while true; do printf 'y\n'; sleep 1; done | sh /tmp/podkop-install.sh"
  else
    (
      while true; do
        printf 'y\n'
        sleep 1
      done
    ) | sh /tmp/podkop-install.sh
  fi
}

if [ ! -f /etc/config/podkop ]; then
  echo "[ERROR] /etc/config/podkop not found."
  echo "[ERROR] This script is for routers where Podkop is already installed."
  echo "[INFO] For clean routers use install.sh from this repository."
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

echo
echo "[STEP] Updating package lists..."
pkg_update

echo
echo "[STEP] Installing base tools..."
pkg_install_one ca-bundle
pkg_install_one ca-certificates
pkg_install_one curl
pkg_install_one wget
pkg_install_one grep
pkg_install_one sed
pkg_install_one coreutils-base64

validate_subscription_before_apply "$REMNA_SUB_URL"

mkdir -p "$APP_DIR/backups"
chmod 700 "$APP_DIR" "$APP_DIR/backups"

STAMP="$(date +%Y%m%d-%H%M%S)"

echo
echo "[STEP] Backup current Podkop and Remnawave updater state..."

cp /etc/config/podkop "$APP_DIR/backups/podkop.config.before-existing-sync.$STAMP"

if [ -f "$CONF" ]; then
  cp "$CONF" "$APP_DIR/backups/subscription.conf.before-existing-sync.$STAMP"
fi

if [ -f "$UPDATER" ]; then
  cp "$UPDATER" "$APP_DIR/backups/update-podkop-from-remnawave.before-existing-sync.$STAMP"
fi

echo "[INFO] Backup dir: $APP_DIR/backups"

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

if [ "$UPDATE_PODKOP" = "1" ]; then
  echo
  echo "[STEP] Updating Podkop because UPDATE_PODKOP=1..."

  if run_podkop_installer_non_interactive; then
    echo "[OK] Podkop installer/update finished."
  else
    echo "[WARN] Podkop installer/update failed or timed out."
    echo "[WARN] Continuing with Remnawave subscription sync."
  fi

  if [ ! -f /etc/config/podkop ]; then
    echo "[ERROR] /etc/config/podkop disappeared after Podkop update. Stop."
    exit 1
  fi
else
  echo
  echo "[INFO] Skipping Podkop package update by default."
  echo "[INFO] To update Podkop too, run with UPDATE_PODKOP=1."
fi

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
echo "[INFO] Managed links summary:"
uci show podkop.main 2>/dev/null | grep 'urltest_proxy_links' | sed 's/ /\n/g' | grep -E 'vless://|ss://' || true

echo
echo "[INFO] cron:"
grep 'update-podkop-from-remnawave.sh' /etc/crontabs/root || true

echo
echo "[OK] Existing Podkop router synced with Remnawave subscription."
echo "[INFO] Podkop package update was skipped unless UPDATE_PODKOP=1 was used."
echo "[INFO] Config: $CONF"
echo "[INFO] Updater: $UPDATER"
echo "[INFO] Log: $LOG"
echo "[INFO] Backups: $APP_DIR/backups"
