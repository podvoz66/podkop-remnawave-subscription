#!/bin/sh
set -eu

# One-command OpenWrt bootstrap for Podkop + Remnawave subscription + Tailscale.
# POSIX/ash-compatible for OpenWrt BusyBox.

REPO_RAW_BASE="https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main"
REPO_UPDATER_URL="$REPO_RAW_BASE/scripts/update-podkop-from-remnawave.sh"
PODKOP_INSTALL_URL="https://raw.githubusercontent.com/itdoginfo/podkop/main/install.sh"

APP_DIR="/etc/podkop-remnawave"
CONF="$APP_DIR/subscription.conf"
UPDATER="/usr/bin/update-podkop-from-remnawave.sh"
LOG="/tmp/podkop-sub-update.log"
CRON_LINE="0 */4 * * * /usr/bin/update-podkop-from-remnawave.sh >/tmp/podkop-sub-update.log 2>&1"
LINK_SCHEMES='(vless|ss|trojan|hysteria2|hy2)'

INSTALL_RU_LOCALE="${INSTALL_RU_LOCALE:-1}"
INSTALL_TTYD="${INSTALL_TTYD:-1}"
INSTALL_PODKOP="${INSTALL_PODKOP:-auto}"
ENABLE_LUCI_TAILSCALE="${ENABLE_LUCI_TAILSCALE:-1}"
DRY_RUN="${DRY_RUN:-0}"
INTERACTIVE="${INTERACTIVE:-1}"

BACKUP_DIR=""
ROUTER_STATE=""
OPENWRT_VERSION="unknown"
OPENWRT_TARGET="unknown"
OPENWRT_ARCH="unknown"
ROUTER_NAME_SAFE=""
TAILSCALE_IP=""
SUB_IMPORT_COUNT="skipped"
PODKOP_STOPPED_WARN=0
SINGBOX_KILLED_WARN=0
TAILSCALE_AUTH_MODE="existing-or-browser"
SUBSCRIPTION_SOURCE="skipped"

echo "=== OpenWrt Podkop + Remnawave + Tailscale bootstrap ==="

is_dry_run() {
  [ "$DRY_RUN" = "1" ]
}

info() {
  echo "[INFO] $*"
}

step() {
  echo
  echo "[STEP] $*"
}

warn() {
  echo "[WARN] $*"
}

err() {
  echo "[ERROR] $*"
}

run_cmd() {
  if is_dry_run; then
    echo "[DRY_RUN] $*"
    return 0
  fi

  "$@"
}

read_release_value() {
  key="$1"

  if [ -f /etc/openwrt_release ]; then
    sed -n "s/^${key}='\(.*\)'/\1/p" /etc/openwrt_release | head -n 1
  fi
}

sanitize_hostname() {
  name="$1"

  printf '%s' "$name" \
    | tr 'A-Z' 'a-z' \
    | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//'
}

mask_url() {
  url="$1"

  case "$url" in
    http://*/*|https://*/*)
      scheme_host="$(printf '%s' "$url" | sed 's#^\(https\{0,1\}://[^/][^/]*\).*#\1#')"
      token_path="$(printf '%s' "$url" | sed 's#^https\{0,1\}://[^/][^/]*/##')"
      token="$(printf '%s' "$token_path" | cut -d '?' -f 1 | cut -d '#' -f 1 | cut -d '/' -f 1)"
      ;;
    http://*|https://*)
      scheme_host="$url"
      token=""
      ;;
    *)
      scheme_host="URL"
      token=""
      ;;
  esac

  if [ -z "$token" ]; then
    printf '%s/...\n' "$scheme_host"
    return 0
  fi

  first="$(printf '%s' "$token" | cut -c 1-4)"
  token_len="$(printf '%s' "$token" | wc -c | tr -d ' ')"

  if [ "$token_len" -gt 8 ]; then
    start_pos=$((token_len - 3))
    last="$(printf '%s' "$token" | cut -c "$start_pos"-)"
    printf '%s/%s***%s\n' "$scheme_host" "$first" "$last"
  else
    printf '%s/%s***\n' "$scheme_host" "$first"
  fi
}

validate_flag() {
  name="$1"
  value="$2"

  case "$value" in
    0|1) ;;
    *)
      err "$name must be 0 or 1."
      exit 1
      ;;
  esac
}

validate_env() {
  validate_flag INSTALL_RU_LOCALE "$INSTALL_RU_LOCALE"
  validate_flag INSTALL_TTYD "$INSTALL_TTYD"
  validate_flag ENABLE_LUCI_TAILSCALE "$ENABLE_LUCI_TAILSCALE"
  validate_flag DRY_RUN "$DRY_RUN"
  validate_flag INTERACTIVE "$INTERACTIVE"

  case "$INSTALL_PODKOP" in
    auto|0|1) ;;
    *)
      err "INSTALL_PODKOP must be auto, 1, or 0."
      exit 1
      ;;
  esac

  if [ -n "${SUB_URL:-}" ]; then
    case "$SUB_URL" in
      http://*|https://*) ;;
      *)
        err "SUB_URL must start with http:// or https://."
        exit 1
        ;;
    esac
  fi
}

load_existing_sub_url() {
  if [ ! -f "$CONF" ]; then
    return 1
  fi

  sub_line="$(sed -n '/^SUB_URL=/{p;q;}' "$CONF" 2>/dev/null || true)"
  if [ -z "$sub_line" ]; then
    return 1
  fi

  sub_value="$(printf '%s' "$sub_line" | sed 's/^SUB_URL=//; s/[[:space:]]*$//')"

  case "$sub_value" in
    \"*\")
      sub_value="${sub_value#\"}"
      sub_value="${sub_value%\"}"
      ;;
    \'*\')
      sub_value="${sub_value#\'}"
      sub_value="${sub_value%\'}"
      ;;
  esac

  if [ -z "$sub_value" ]; then
    return 1
  fi

  case "$sub_value" in
    http://*|https://*) ;;
    *) return 1 ;;
  esac

  SUB_URL="$sub_value"
  return 0
}

prompt_startup_inputs() {
  if [ "$INTERACTIVE" != "1" ]; then
    info "INTERACTIVE=0. Using environment variables only."
    if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
      TAILSCALE_AUTH_MODE="env-key"
    else
      TAILSCALE_AUTH_MODE="existing-or-browser"
    fi

    if [ -n "${SUB_URL:-}" ]; then
      SUBSCRIPTION_SOURCE="env"
      info "SUB_URL is already provided via environment: $(mask_url "$SUB_URL")"
    elif load_existing_sub_url; then
      SUBSCRIPTION_SOURCE="existing"
      info "Using existing subscription URL from $CONF: $(mask_url "$SUB_URL")"
    else
      SUBSCRIPTION_SOURCE="skipped"
      warn "No SUB_URL provided and no existing subscription config found. Subscription import will be skipped."
    fi

    return 0
  fi

  if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
    TAILSCALE_AUTH_MODE="env-key"
    info "TAILSCALE_AUTHKEY is already provided via environment."
  else
    printf '%s' "Enter Tailscale auth key for remote access, or press Enter to keep existing / use browser login if needed: "
    IFS= read TAILSCALE_AUTHKEY || TAILSCALE_AUTHKEY=""
    if [ -n "$TAILSCALE_AUTHKEY" ]; then
      TAILSCALE_AUTH_MODE="entered-key"
    else
      TAILSCALE_AUTH_MODE="existing-or-browser"
    fi
  fi

  if [ -n "${SUB_URL:-}" ]; then
    SUBSCRIPTION_SOURCE="env"
    info "SUB_URL is already provided via environment: $(mask_url "$SUB_URL")"
  else
    printf '%s' "Enter Remnawave subscription URL, or press Enter to keep existing / skip if none: "
    IFS= read SUB_URL || SUB_URL=""
    if [ -n "$SUB_URL" ]; then
      SUBSCRIPTION_SOURCE="entered"
    elif load_existing_sub_url; then
      SUBSCRIPTION_SOURCE="existing"
      info "Using existing subscription URL from $CONF: $(mask_url "$SUB_URL")"
    else
      SUBSCRIPTION_SOURCE="skipped"
      warn "No SUB_URL entered and no existing subscription config found. Subscription import will be skipped."
    fi
  fi
}

require_root_openwrt() {
  if [ "$(id -u)" != "0" ]; then
    err "Run as root."
    exit 1
  fi

  if [ ! -f /etc/openwrt_release ]; then
    err "This does not look like OpenWrt."
    exit 1
  fi
}

pkg_detect() {
  if command -v opkg >/dev/null 2>&1; then
    PKG="opkg"
  elif command -v apk >/dev/null 2>&1; then
    PKG="apk"
  else
    err "Neither opkg nor apk found."
    exit 1
  fi
}

pkg_update() {
  if [ "$PKG" = "apk" ]; then
    run_cmd apk update || warn "apk update failed. Continuing; package installs may fail."
  else
    run_cmd opkg update || warn "opkg update failed. Continuing; package installs may fail."
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
  critical="$2"

  if pkg_is_installed "$p"; then
    echo "[OK] Package already installed: $p"
    return 0
  fi

  if is_dry_run; then
    echo "[DRY_RUN] install package: $p"
    return 0
  fi

  info "Installing package: $p"

  if [ "$PKG" = "apk" ]; then
    if apk add "$p"; then
      return 0
    fi
  else
    if opkg install "$p"; then
      return 0
    fi
  fi

  if [ "$critical" = "1" ]; then
    err "Critical package install failed: $p"
    exit 1
  fi

  warn "Package install failed or unavailable: $p"
  return 0
}

fetch() {
  url="$1"
  out="$2"

  if command -v curl >/dev/null 2>&1; then
    if is_dry_run; then
      echo "[DRY_RUN] curl -fsSL URL -o $out"
      return 0
    fi
    curl -fsSL --connect-timeout 25 --max-time 60 "$url" -o "$out"
  elif command -v wget >/dev/null 2>&1; then
    if is_dry_run; then
      echo "[DRY_RUN] wget -O $out URL"
      return 0
    fi
    wget -O "$out" "$url"
  else
    err "Need curl or wget."
    exit 1
  fi
}

command_state() {
  c="$1"

  if command -v "$c" >/dev/null 2>&1; then
    printf 'present'
  else
    printf 'missing'
  fi
}

service_state() {
  service="$1"
  status_file="/tmp/bootstrap-service-status.$$"
  status_rc=1

  if [ -x "/etc/init.d/$service" ]; then
    if "/etc/init.d/$service" status >"$status_file" 2>&1; then
      status_rc=0
    else
      status_rc=$?
    fi

    if grep -qiE 'not[[:space:]-]*running|stopped|inactive' "$status_file"; then
      rm -f "$status_file"
      printf 'installed/not-running'
    elif grep -qiE 'running|active' "$status_file"; then
      rm -f "$status_file"
      printf 'installed/running'
    elif [ "$status_rc" -eq 0 ]; then
      rm -f "$status_file"
      printf 'installed/running'
    else
      rm -f "$status_file"
      printf 'installed/not-running'
    fi
  else
    printf 'missing'
  fi
}

preflight() {
  step "Preflight diagnostics"

  OPENWRT_VERSION="$(read_release_value DISTRIB_DESCRIPTION || true)"
  OPENWRT_TARGET="$(read_release_value DISTRIB_TARGET || true)"
  OPENWRT_ARCH="$(read_release_value DISTRIB_ARCH || true)"

  [ -n "$OPENWRT_VERSION" ] || OPENWRT_VERSION="unknown"
  [ -n "$OPENWRT_TARGET" ] || OPENWRT_TARGET="unknown"
  [ -n "$OPENWRT_ARCH" ] || OPENWRT_ARCH="unknown"

  if [ -n "${ROUTER_NAME:-}" ]; then
    router_name_input="$ROUTER_NAME"
    ROUTER_NAME_SAFE="$(sanitize_hostname "$ROUTER_NAME")"
  else
    current_name="$(uci -q get system.@system[0].hostname 2>/dev/null || hostname 2>/dev/null || echo openwrt)"
    router_name_input="$current_name"
    ROUTER_NAME_SAFE="$(sanitize_hostname "$current_name")"
  fi

  [ -n "$ROUTER_NAME_SAFE" ] || ROUTER_NAME_SAFE="openwrt-router"

  if ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
    internet_state="ok"
  else
    internet_state="failed"
  fi

  if nslookup openwrt.org >/dev/null 2>&1; then
    dns_state="ok"
  else
    dns_state="failed"
  fi

  free_kb="$(df -k / 2>/dev/null | awk 'NR==2 {print $4}' || true)"
  [ -n "$free_kb" ] || free_kb="unknown"

  luci_state="$(service_state uhttpd)"
  ttyd_state="$(service_state ttyd)"
  podkop_state="$(service_state podkop)"
  tailscale_state="$(service_state tailscale)"

  if pgrep -x sing-box >/dev/null 2>&1; then
    singbox_state="running"
  elif command -v sing-box >/dev/null 2>&1; then
    singbox_state="installed/not-running"
  else
    singbox_state="missing"
  fi

  if [ -c /dev/net/tun ]; then
    tun_state="present"
  else
    tun_state="missing"
  fi

  managed_state="missing"
  if [ -d "$APP_DIR" ] || [ -f "$UPDATER" ] || grep -q 'update-podkop-from-remnawave.sh' /etc/crontabs/root 2>/dev/null; then
    managed_state="present"
  fi

  if [ "$podkop_state" = "missing" ] && [ "$singbox_state" = "missing" ] && [ "$tailscale_state" = "missing" ] && [ "$managed_state" = "missing" ]; then
    ROUTER_STATE="CLEAN"
  else
    ROUTER_STATE="EXISTING"
  fi

  echo "OpenWrt version: $OPENWRT_VERSION"
  echo "Target: $OPENWRT_TARGET"
  echo "Arch: $OPENWRT_ARCH"
  echo "Router name input: $router_name_input"
  echo "Router name: $ROUTER_NAME_SAFE"
  echo "Package manager: $PKG"
  echo "opkg: $(command_state opkg)"
  echo "Internet ping 1.1.1.1: $internet_state"
  echo "DNS nslookup openwrt.org: $dns_state"
  echo "Free space on /: ${free_kb} KB"
  echo "LuCI/uhttpd: $luci_state"
  echo "ttyd: $ttyd_state"
  echo "Podkop: $podkop_state"
  echo "sing-box: $singbox_state"
  echo "Tailscale: $tailscale_state"
  echo "/dev/net/tun: $tun_state"
  echo "Managed state: $managed_state"
  echo "Router state: $ROUTER_STATE"

  if [ "$internet_state" != "ok" ]; then
    warn "Internet ping failed. Package install and subscription fetch may fail."
  fi

  if [ "$dns_state" != "ok" ]; then
    warn "DNS lookup failed. Package install and subscription fetch may fail."
  fi
}

make_backup() {
  if [ "$ROUTER_STATE" != "EXISTING" ]; then
    info "Router state is CLEAN. Backup will still be created before managed writes."
  fi

  stamp="$(date +%Y%m%d-%H%M%S)"
  BACKUP_DIR="/root/podkop-bootstrap-backups/$stamp"

  step "Backup current router state"

  if is_dry_run; then
    echo "[DRY_RUN] mkdir -p $BACKUP_DIR"
    return 0
  fi

  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"

  for f in \
    /etc/config/podkop \
    /etc/config/uhttpd \
    /etc/config/dhcp \
    /etc/config/firewall \
    "$CONF" \
    "$UPDATER" \
    /etc/crontabs/root
  do
    if [ -f "$f" ]; then
      base="$(basename "$f")"
      cp -p "$f" "$BACKUP_DIR/$base.before-bootstrap"
    fi
  done

  echo "[INFO] Backup dir: $BACKUP_DIR"
}

install_dependencies() {
  step "Install dependencies"

  pkg_update

  pkg_install_one ca-bundle 0
  pkg_install_one ca-certificates 0

  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    pkg_install_one curl 0
  fi

  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    pkg_install_one wget 1
  fi

  if [ -c /dev/net/tun ]; then
    echo "[OK] /dev/net/tun already exists."
  else
    pkg_install_one kmod-tun 1
  fi
  pkg_install_one tailscale 1
  pkg_install_one iptables-nft 0
  pkg_install_one ip6tables-nft 0

  if [ "$INSTALL_TTYD" = "1" ]; then
    pkg_install_one ttyd 0
    pkg_install_one luci-app-ttyd 0
  else
    info "INSTALL_TTYD=0. Skipping ttyd packages."
  fi

  if [ "$INSTALL_RU_LOCALE" = "1" ]; then
    pkg_install_one luci-i18n-base-ru 0
    pkg_install_one luci-i18n-firewall-ru 0
    pkg_install_one luci-i18n-opkg-ru 0
  else
    info "INSTALL_RU_LOCALE=0. Skipping Russian LuCI locale packages."
  fi

  if [ -x /etc/init.d/ttyd ] && [ "$INSTALL_TTYD" = "1" ]; then
    run_cmd /etc/init.d/ttyd enable || true
    run_cmd /etc/init.d/ttyd restart || true
  fi
}

stop_orphan_singbox_for_tailscale() {
  step "Check orphan sing-box before Tailscale"

  if ! pgrep -x sing-box >/dev/null 2>&1; then
    echo "[OK] No sing-box process found."
    return 0
  fi

  warn "sing-box process is running."

  if [ -x /etc/init.d/podkop ]; then
    warn "Stopping Podkop first."
    PODKOP_STOPPED_WARN=1
    run_cmd /etc/init.d/podkop stop || true
    sleep 3
  else
    warn "/etc/init.d/podkop not found."
  fi

  if pgrep -x sing-box >/dev/null 2>&1; then
    warn "sing-box is still alive after Podkop stop. Killing stale process."
    SINGBOX_KILLED_WARN=1
    run_cmd killall sing-box || true
    sleep 2
  fi

  if is_dry_run; then
    echo "[DRY_RUN] skip post-cleanup sing-box assertion"
    return 0
  fi

  if pgrep -x sing-box >/dev/null 2>&1; then
    err "sing-box is still running after cleanup."
    pgrep -af sing-box || true
    exit 1
  fi

  echo "[OK] No orphan sing-box remains."
}

configure_luci_tailscale_access() {
  if [ "$ENABLE_LUCI_TAILSCALE" != "1" ]; then
    info "ENABLE_LUCI_TAILSCALE=0. Skipping LuCI/uhttpd change."
    return 0
  fi

  if [ ! -f /etc/config/uhttpd ]; then
    warn "/etc/config/uhttpd not found. Skipping LuCI/uhttpd change."
    return 0
  fi

  step "Enable LuCI access through Tailscale IP"

  run_cmd uci set uhttpd.main.rfc1918_filter='0'
  run_cmd uci commit uhttpd

  if [ -x /etc/init.d/uhttpd ]; then
    run_cmd /etc/init.d/uhttpd restart || true
  fi
}

tailscale_diagnostics() {
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
}

wait_tailscale_online() {
  i=0

  step "Wait for Tailscale online state"

  while [ "$i" -lt 60 ]; do
    TAILSCALE_IP="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
    ts_status="$(tailscale status 2>/dev/null || true)"
    self_line="$(printf '%s\n' "$ts_status" | grep -i "[[:space:]]${ROUTER_NAME_SAFE}[[:space:]]" | head -n 1 || true)"

    if [ -n "$TAILSCALE_IP" ]; then
      if [ -z "$self_line" ] || ! printf '%s\n' "$self_line" | grep -qi 'offline'; then
        echo "[OK] Tailscale IPv4: $TAILSCALE_IP"
        return 0
      fi
    fi

    i=$((i + 1))
    sleep 1
  done

  err "Tailscale did not become online within 60 seconds."
  tailscale_diagnostics
  exit 1
}

run_tailscale_up() {
  step "Run tailscale up"

  tmp="/tmp/tailscale-up.$$"

  if is_dry_run; then
    if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
      echo "[DRY_RUN] tailscale up --auth-key=***MASKED*** --accept-dns=false --ssh=false --hostname=$ROUTER_NAME_SAFE"
    else
      echo "[DRY_RUN] tailscale up --accept-dns=false --ssh=false --hostname=$ROUTER_NAME_SAFE"
    fi
    return 0
  fi

  if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
    info "Using provided Tailscale auth key. The key will not be printed."
    if tailscale up --auth-key="$TAILSCALE_AUTHKEY" --accept-dns=false --ssh=false --hostname="$ROUTER_NAME_SAFE" >"$tmp" 2>&1; then
      sed 's/tskey-[^[:space:]]*/tskey-***MASKED***/g' "$tmp"
      rm -f "$tmp"
      return 0
    fi
  else
    info "No Tailscale auth key provided. Existing state or browser login flow will be used."
    if tailscale up --accept-dns=false --ssh=false --hostname="$ROUTER_NAME_SAFE" >"$tmp" 2>&1; then
      sed 's/tskey-[^[:space:]]*/tskey-***MASKED***/g' "$tmp"
      rm -f "$tmp"
      return 0
    fi
  fi

  if grep -q "changing settings via 'tailscale up' requires mentioning all non-default flags" "$tmp"; then
    warn "tailscale up reported a non-default flags warning."
    warn "Continuing to online-state validation because required flags were supplied."
    rm -f "$tmp"
    return 0
  fi

  sed 's/tskey-[^[:space:]]*/tskey-***MASKED***/g' "$tmp"
  rm -f "$tmp"
  exit 1
}

setup_tailscale() {
  step "Configure Tailscale"

  if [ ! -x /etc/init.d/tailscale ] && ! is_dry_run; then
    err "/etc/init.d/tailscale not found after package install."
    exit 1
  fi

  stop_orphan_singbox_for_tailscale

  run_cmd /etc/init.d/tailscale enable || true
  run_cmd /etc/init.d/tailscale restart || true
  sleep 5

  if ! is_dry_run && ! pgrep -af tailscaled >/dev/null 2>&1; then
    err "tailscaled is not running."
    tailscale_diagnostics
    exit 1
  fi

  tailscale status 2>/dev/null || true
  run_tailscale_up

  if ! is_dry_run; then
    wait_tailscale_online
  fi

  configure_luci_tailscale_access
}

run_podkop_installer_non_interactive() {
  step "Install Podkop"

  if is_dry_run; then
    echo "[DRY_RUN] fetch Podkop installer and run it with yes answers"
    return 0
  fi

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

setup_podkop() {
  step "Configure Podkop"

  if [ -f /etc/config/podkop ] || [ -x /etc/init.d/podkop ]; then
    info "Podkop appears to be installed. Keeping existing installation."
    if [ -x /etc/init.d/podkop ]; then
      /etc/init.d/podkop status || true
    fi
    return 0
  fi

  case "$INSTALL_PODKOP" in
    0)
      warn "Podkop is not installed and INSTALL_PODKOP=0. Skipping Podkop install."
      return 0
      ;;
    auto|1)
      info "Podkop is not installed. Using documented Podkop installer."
      if run_podkop_installer_non_interactive; then
        echo "[OK] Podkop installer finished."
      else
        err "Podkop installer failed."
        err "Install Podkop manually, then rerun this bootstrap with INSTALL_PODKOP=0 or auto."
        exit 1
      fi
      ;;
  esac

  if ! is_dry_run && [ ! -f /etc/config/podkop ]; then
    err "/etc/config/podkop not found after Podkop installation."
    exit 1
  fi
}

install_updater_and_cron() {
  step "Install Remnawave updater"

  if is_dry_run; then
    echo "[DRY_RUN] mkdir -p $APP_DIR"
  else
    mkdir -p "$APP_DIR/backups"
    chmod 700 "$APP_DIR" "$APP_DIR/backups"
  fi

  fetch "$REPO_UPDATER_URL" "$UPDATER"
  run_cmd chmod +x "$UPDATER"

  if is_dry_run; then
    echo "[DRY_RUN] install cron line for update-podkop-from-remnawave.sh"
  else
    grep -v 'update-podkop-from-remnawave.sh' /etc/crontabs/root 2>/dev/null > /tmp/root.cron.$$ || true
    echo "$CRON_LINE" >> /tmp/root.cron.$$
    cat /tmp/root.cron.$$ > /etc/crontabs/root
    rm -f /tmp/root.cron.$$
  fi

  if [ -x /etc/init.d/cron ]; then
    run_cmd /etc/init.d/cron restart || true
  fi
}

write_subscription_config() {
  if [ -z "${SUB_URL:-}" ]; then
    warn "SUB_URL is not set. Subscription import will be skipped."
    SUB_IMPORT_COUNT="skipped"
    SUBSCRIPTION_SOURCE="skipped"
    return 1
  fi

  if [ "$SUBSCRIPTION_SOURCE" = "existing" ]; then
    info "Keeping existing subscription config: $(mask_url "$SUB_URL")"
    return 0
  fi

  step "Write subscription config"
  info "Subscription URL: $(mask_url "$SUB_URL")"

  if is_dry_run; then
    echo "[DRY_RUN] write masked SUB_URL to $CONF"
    return 0
  fi

  mkdir -p "$APP_DIR"
  chmod 700 "$APP_DIR"
  umask 077
  {
    printf "SUB_URL='"
    printf '%s' "$SUB_URL" | sed "s/'/'\\\\''/g"
    printf "'\n"
  } > "$CONF"
  chmod 600 "$CONF"
}

run_subscription_update() {
  if [ -z "${SUB_URL:-}" ]; then
    return 0
  fi

  if [ ! -f /etc/config/podkop ] && ! is_dry_run; then
    warn "Podkop config is missing. Subscription updater cannot run."
    SUB_IMPORT_COUNT="not-run"
    return 0
  fi

  step "Import Remnawave subscription"

  if is_dry_run; then
    echo "[DRY_RUN] run $UPDATER and parse counts"
    SUB_IMPORT_COUNT="dry-run"
    return 0
  fi

  if "$UPDATER" >"$LOG" 2>&1; then
    sed 's#https\?://[^[:space:]]*#URL***MASKED***#g; s/tskey-[^[:space:]]*/tskey-***MASKED***/g' "$LOG"
  else
    err "Subscription update failed. Sanitized log follows:"
    sed 's#https\?://[^[:space:]]*#URL***MASKED***#g; s/tskey-[^[:space:]]*/tskey-***MASKED***/g' "$LOG" || true
    exit 1
  fi

  SUB_IMPORT_COUNT="$(sed -n 's/^\[INFO\] Found subscription links total: //p' "$LOG" | tail -n 1)"
  [ -n "$SUB_IMPORT_COUNT" ] || SUB_IMPORT_COUNT="unknown"

  if grep -q 'Podkop/sing-box may have been stopped\|sing-box remained after Podkop stop' "$LOG" 2>/dev/null; then
    PODKOP_STOPPED_WARN=1
  fi

  if grep -q 'Killing stale process' "$LOG" 2>/dev/null; then
    SINGBOX_KILLED_WARN=1
  fi
}

final_report() {
  step "Final report"

  if command -v tailscale >/dev/null 2>&1; then
    TAILSCALE_IP="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
  fi

  [ -n "$TAILSCALE_IP" ] || TAILSCALE_IP="unknown"

  podkop_final="missing"
  if [ -x /etc/init.d/podkop ]; then
    if /etc/init.d/podkop status >/tmp/bootstrap-podkop-status.$$ 2>&1; then
      podkop_final="$(cat /tmp/bootstrap-podkop-status.$$ | head -n 1)"
    else
      podkop_final="$(cat /tmp/bootstrap-podkop-status.$$ | head -n 1)"
      [ -n "$podkop_final" ] || podkop_final="installed/not-running"
    fi
    rm -f /tmp/bootstrap-podkop-status.$$
  fi

  if pgrep -x sing-box >/dev/null 2>&1; then
    singbox_final="running"
  elif command -v sing-box >/dev/null 2>&1; then
    singbox_final="installed/not-running"
  else
    singbox_final="missing"
  fi

  echo "OpenWrt version: $OPENWRT_VERSION"
  echo "Router name: $ROUTER_NAME_SAFE"
  echo "Tailscale IP: $TAILSCALE_IP"
  echo "SSH command: ssh root@$TAILSCALE_IP"
  echo "LuCI URL: http://$TAILSCALE_IP/"
  echo "Podkop status: $podkop_final"
  echo "sing-box status: $singbox_final"
  echo "Tailscale auth: $TAILSCALE_AUTH_MODE"
  echo "Subscription source: $SUBSCRIPTION_SOURCE"
  echo "Subscription import count: $SUB_IMPORT_COUNT"
  echo "Backup dir: ${BACKUP_DIR:-not-created}"

  if [ "$PODKOP_STOPPED_WARN" = "1" ]; then
    warn "Podkop was stopped during safe Tailscale/Podkop handling."
  fi

  if [ "$SINGBOX_KILLED_WARN" = "1" ]; then
    warn "A stale sing-box process was killed."
  fi

  echo "[SECURITY] WAN ports were not opened."
}

validate_env
require_root_openwrt
pkg_detect
prompt_startup_inputs
validate_env
preflight
make_backup
install_dependencies
setup_tailscale
setup_podkop
if write_subscription_config; then
  install_updater_and_cron
  run_subscription_update
fi
final_report
