#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
BOOTSTRAP="$ROOT/scripts/bootstrap-openwrt-router.sh"
UPDATER="$ROOT/scripts/update-podkop-from-remnawave.sh"
SYNC="$ROOT/scripts/sync-podkop-mirror.sh"
RUNTIME_STATE="$ROOT/scripts/adeptpro-runtime-state.sh"
RUNTIME_INIT="$ROOT/scripts/adeptpro-runtime-state.init"
LEGACY_INSTALL="$ROOT/install.sh"
EXISTING_INSTALL="$ROOT/scripts/install-subscription-on-existing-podkop.sh"
FAILURES=0

pass() { echo "$1=PASS"; }
fail() { echo "$1=FAIL"; FAILURES=$((FAILURES + 1)); }

expect_pattern() {
  label="$1"; pattern="$2"; shift 2
  if grep -Eq "$pattern" "$@"; then pass "$label"; else fail "$label"; fi
}

expect_absent() {
  label="$1"; pattern="$2"; shift 2
  if grep -Eiq "$pattern" "$@"; then fail "$label"; else pass "$label"; fi
}

count_pattern() {
  pattern="$1"; shift
  grep -Eih "$pattern" "$@" 2>/dev/null | wc -l | tr -d ' '
}

tmp_base="${TMPDIR:-/tmp}/adeptpro-static.$$"
router_files="$tmp_base.router"
shell_files="$tmp_base.shell"
ttyd_files="$tmp_base.ttyd"
trap 'rm -f "$router_files" "$shell_files" "$ttyd_files"' EXIT

# Explicit server-side allowlist: only the mirror sync script and deployment scripts.
# Test scripts are validation tooling, not router-executable entrypoints.
find "$ROOT" -type f \( -name '*.sh' -o -name '*.init' \) -not -path '*/.git/*' | sort > "$shell_files"
while IFS= read -r script; do
  case "$script" in
    "$ROOT/tests/"*) continue ;;
    "$ROOT/scripts/sync-podkop-mirror.sh") continue ;;
    "$ROOT/deploy/bootstrap.adeptpro.online/scripts/"*) continue ;;
  esac
  printf '%s\n' "$script" >> "$router_files"
done < "$shell_files"

[ -s "$router_files" ] || { echo 'ROUTER_SCRIPT_DISCOVERY=FAIL'; exit 1; }
router_count="$(wc -l < "$router_files" | tr -d ' ')"
echo "ROUTER_SCRIPT_COUNT=$router_count"

github_count=0
cron_4h_count=0
podkop_restart_count=0
singbox_restart_count=0
singbox_kill_count=0
while IFS= read -r script; do
  github_count=$((github_count + $(count_pattern 'github\.com|api\.github\.com|raw\.githubusercontent\.com|objects\.githubusercontent\.com' "$script")))
  cron_4h_count=$((cron_4h_count + $(count_pattern '0[[:space:]]+\*/4[[:space:]]+\*[[:space:]]+\*[[:space:]]+\*' "$script")))
  podkop_restart_count=$((podkop_restart_count + $(count_pattern '/etc/init\.d/podkop[[:space:]]+(stop|start|restart)|service[[:space:]]+podkop[[:space:]]+(stop|start|restart)' "$script")))
  singbox_restart_count=$((singbox_restart_count + $(count_pattern 'sing-box.*restart|restart.*sing-box' "$script")))
  singbox_kill_count=$((singbox_kill_count + $(count_pattern 'killall[[:space:]]+sing-box|kill[[:space:]][^#]*sing-box' "$script")))
done < "$router_files"

echo "ROUTER_GITHUB_DEPENDENCY_COUNT=$github_count"
[ "$github_count" -eq 0 ] && pass GITHUB_IN_ROUTER_SCRIPTS || fail GITHUB_IN_ROUTER_SCRIPTS
[ "$cron_4h_count" -eq 0 ] && pass NO_4H_CRON || fail NO_4H_CRON
echo "PERIODIC_PODKOP_RESTART_COUNT=$podkop_restart_count"
echo "PERIODIC_SINGBOX_RESTART_COUNT=$singbox_restart_count"
echo "PERIODIC_SINGBOX_KILL_COUNT=$singbox_kill_count"
[ "$podkop_restart_count" -eq 0 ] || FAILURES=$((FAILURES + 1))
[ "$singbox_restart_count" -eq 0 ] || FAILURES=$((FAILURES + 1))
[ "$singbox_kill_count" -eq 0 ] || FAILURES=$((FAILURES + 1))

while IFS= read -r script; do
  case "$script" in
    "$ROOT/scripts/adeptpro-postboot.sh"|"$ROOT/scripts/adeptpro-postboot.init") continue ;;
  esac
  printf '%s\n' "$script" >> "$ttyd_files"
done < "$router_files"
ttyd_critical_count=0
while IFS= read -r script; do
  ttyd_critical_count=$((ttyd_critical_count + $(count_pattern 'opkg[^#]*install[^#]*ttyd|apk[^#]*add[^#]*ttyd|pkg_install[^#]*ttyd|/etc/init\.d/ttyd[[:space:]]+(start|restart)' "$script")))
done < "$ttyd_files"
echo "TTYYD_IN_CRITICAL_PATH=$ttyd_critical_count"
[ "$ttyd_critical_count" -eq 0 ] || FAILURES=$((FAILURES + 1))

expect_pattern LEGACY_INSTALL_SH_V2 'bootstrap\.adeptpro\.online/openwrt/v1' "$LEGACY_INSTALL"
expect_pattern LEGACY_INSTALL_SH_EXEC 'sh "\$bootstrap_tmp" "\$@"' "$LEGACY_INSTALL"
expect_absent LEGACY_INSTALL_SH_NO_OLD_LOGIC 'PODKOP_INSTALL_URL|ttyd|0 \*/4|github' "$LEGACY_INSTALL"
expect_pattern EXISTING_PODKOP_INSTALLER_V2 'bootstrap\.adeptpro\.online/openwrt/v1' "$EXISTING_INSTALL"
expect_pattern EXISTING_PODKOP_INSTALLER_PRESERVES_EXISTING 'INSTALL_PODKOP="\$\{INSTALL_PODKOP:-0\}"' "$EXISTING_INSTALL"
expect_absent EXISTING_PODKOP_INSTALLER_NO_OLD_LOGIC 'PODKOP_INSTALL_URL|ttyd|0 \*/4|github|killall[[:space:]]+sing-box' "$EXISTING_INSTALL"

expect_pattern SYNC_CRON_DAILY 'REMNAWAVE_SYNC_CRON="50 3 \* \* \* ' "$BOOTSTRAP"
expect_pattern PODKOP_RU_NONINTERACTIVE 'PODKOP_RU=AUTO' "$BOOTSTRAP"
expect_pattern TTYYD_POSTBOOT 'POSTBOOT_TTYD=PASS' "$ROOT/scripts/adeptpro-postboot.sh"
expect_pattern DONT_TOUCH_DHCP "podkop\.settings\.dont_touch_dhcp='1'" "$BOOTSTRAP"
expect_pattern SHA256_VALIDATION 'actual_sha=.*sha256sum' "$BOOTSTRAP"
expect_pattern MANUAL_LINK_PRESERVATION_PRESENT 'collect_manual_links' "$UPDATER"
expect_pattern SUB_URL_MASKING_PRESENT 'mask_url' "$BOOTSTRAP"
expect_pattern TAILSCALE_KEY_MASKING_PRESENT 'tskey-\*\*\*MASKED\*\*\*|auth key.*not be printed' "$BOOTSTRAP"
expect_pattern MIRROR_VERSION_PINNED "PODKOP_APPROVED_VERSION='0\.7\.22'" "$BOOTSTRAP" "$SYNC"

expect_pattern PENDING_MARKER_CREATE 'mv "\$marker_tmp" "\$PENDING_RUNTIME_RELOAD"' "$UPDATER"
expect_pattern PENDING_MARKER_BOOT_CLEAR 'mv -f "\$PENDING_MARKER" "\$LAST_APPLIED_MARKER"' "$RUNTIME_STATE"
expect_pattern PENDING_MARKER_HASH_CHECK 'CONFIG_HASH_MATCH=' "$RUNTIME_STATE"
expect_pattern PENDING_MARKER_GLOBAL_CHECK 'podkop global_check' "$RUNTIME_STATE"
expect_pattern PENDING_MARKER_BOOT_ENABLED '"\$runtime_state_init" enable' "$BOOTSTRAP"
expect_absent MARKER_CLEAR_NO_RESTART '/etc/init\.d/podkop[[:space:]]+(stop|start|restart)|sing-box.*restart|restart.*sing-box' "$RUNTIME_STATE" "$RUNTIME_INIT"
expect_absent MARKER_CLEAR_NO_SINGBOX_KILL 'killall[[:space:]]+sing-box|kill[[:space:]][^#]*sing-box' "$RUNTIME_STATE" "$RUNTIME_INIT"

expect_pattern OPENWRT_24_10_SUPPORT '24\.10' "$BOOTSTRAP"
expect_pattern OPENWRT_25_12_SUPPORT '25\.12' "$BOOTSTRAP"
expect_pattern NO_OPKG_IN_APK_PATH "apk:\*\.apk\).*apk add --allow-untrusted" "$BOOTSTRAP"
expect_pattern NO_APK_IN_OPKG_PATH "opkg:\*\.ipk\).*opkg install" "$BOOTSTRAP"
expect_pattern IPK_SHA256_VALIDATION "package_format='ipk'" "$SYNC"
expect_pattern APK_SHA256_VALIDATION "package_format='apk'" "$SYNC"
expect_pattern IPK_GZIP_TAR_VALIDATOR 'validate_ipk_gzip_tar' "$SYNC"
expect_pattern GITHUB_DIGEST_VALIDATOR 'verify_github_digest' "$SYNC"
expect_absent AR_NOT_REQUIRED_FOR_IPK 'ar[[:space:]]+(t|p)[[:space:]]|command_name[^#]*[[:space:]]ar([[:space:]]|$)' "$SYNC"
expect_pattern UNSUPPORTED_PACKAGE_MANAGER_FAILS_CLOSED 'Unsupported OpenWrt package manager' "$BOOTSTRAP"
expect_pattern ARCHITECTURE_MISMATCH_FAILS_CLOSED 'No .* packages for router architecture' "$BOOTSTRAP"

syntax_failures=0
while IFS= read -r script; do
  first_line="$(sed -n '1p' "$script")"
  case "$first_line" in
    *bash*)
      if command -v bash >/dev/null 2>&1; then bash -n "$script" || syntax_failures=$((syntax_failures + 1))
      else echo "BASH_N_SKIPPED=$script"; fi
      ;;
    *) sh -n "$script" || syntax_failures=$((syntax_failures + 1)) ;;
  esac
done < "$shell_files"
[ "$syntax_failures" -eq 0 ] && pass SHELL_SYNTAX || fail SHELL_SYNTAX

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck_failures=0
  while IFS= read -r script; do
    shellcheck "$script" || shellcheck_failures=$((shellcheck_failures + 1))
  done < "$shell_files"
  [ "$shellcheck_failures" -eq 0 ] && pass SHELLCHECK || fail SHELLCHECK
else
  echo 'SHELLCHECK=SKIP_NOT_INSTALLED'
fi

echo "STATIC_TEST_FAILURES=$FAILURES"
[ "$FAILURES" -eq 0 ]
