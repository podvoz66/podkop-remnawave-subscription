#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
BOOTSTRAP="$ROOT/scripts/bootstrap-openwrt-router.sh"
UPDATER="$ROOT/scripts/update-podkop-from-remnawave.sh"
GUARD="$ROOT/scripts/update-podkop-from-remnawave.guard.sh"
LIST_GUARD="$ROOT/scripts/podkop-all-lists-guard.sh"
TAILSCALE="$ROOT/scripts/install-tailscale-direct-access.sh"
POSTBOOT="$ROOT/scripts/adeptpro-postboot.sh"
POSTBOOT_INIT="$ROOT/scripts/adeptpro-postboot.init"
SYNC="$ROOT/scripts/sync-podkop-mirror.sh"
FAILURES=0

pass() {
  echo "$1=PASS"
}

fail() {
  echo "$1=FAIL"
  FAILURES=$((FAILURES + 1))
}

expect_pattern() {
  label="$1"
  pattern="$2"
  shift 2
  if grep -Eq "$pattern" "$@"; then pass "$label"; else fail "$label"; fi
}

expect_absent() {
  label="$1"
  pattern="$2"
  shift 2
  if grep -Eiq "$pattern" "$@"; then fail "$label"; else pass "$label"; fi
}

github_count="$(grep -Eih 'github\.com|api\.github\.com|raw\.githubusercontent\.com|objects\.githubusercontent\.com' \
  "$BOOTSTRAP" "$UPDATER" "$GUARD" "$LIST_GUARD" "$TAILSCALE" "$POSTBOOT" "$POSTBOOT_INIT" \
  2>/dev/null | wc -l | tr -d ' ')"
echo "ROUTER_GITHUB_DEPENDENCY_COUNT=$github_count"
if [ "$github_count" = '0' ]; then echo 'GITHUB_IN_ROUTER_SCRIPTS=0'; else fail GITHUB_IN_ROUTER_SCRIPTS; fi

expect_pattern SYNC_CRON_DAILY 'REMNAWAVE_SYNC_CRON="50 3 \* \* \* ' "$BOOTSTRAP"
expect_absent NO_4H_CRON '0 \*/4 \* \* \*' "$BOOTSTRAP" "$UPDATER" "$GUARD"
updater_podkop_restart_count="$(grep -Eih '/etc/init\.d/podkop[[:space:]]+(stop|start|restart)|service[[:space:]]+podkop[[:space:]]+restart' "$UPDATER" "$GUARD" 2>/dev/null | wc -l | tr -d ' ')"
updater_singbox_restart_count="$(grep -Eih 'sing-box.*restart|restart.*sing-box' "$UPDATER" "$GUARD" 2>/dev/null | wc -l | tr -d ' ')"
updater_singbox_kill_count="$(grep -Eih 'killall[[:space:]]+sing-box|kill[[:space:]].*sing-box' "$UPDATER" "$GUARD" 2>/dev/null | wc -l | tr -d ' ')"
echo "UPDATER_PODKOP_RESTART=$updater_podkop_restart_count"
echo "UPDATER_SINGBOX_RESTART=$updater_singbox_restart_count"
echo "UPDATER_SINGBOX_KILL=$updater_singbox_kill_count"
[ "$updater_podkop_restart_count" = '0' ] || FAILURES=$((FAILURES + 1))
[ "$updater_singbox_restart_count" = '0' ] || FAILURES=$((FAILURES + 1))
[ "$updater_singbox_kill_count" = '0' ] || FAILURES=$((FAILURES + 1))

expect_pattern PODKOP_RU_NONINTERACTIVE 'PODKOP_RU=AUTO' "$BOOTSTRAP"
expect_absent PODKOP_INSTALLER_PROMPT 'PODKOP_INSTALL_URL|Русский язык интерфейса|while true.*printf.*y' "$BOOTSTRAP"
ttyd_critical_count="$(grep -Eih 'opkg install ttyd|apk add ttyd|pkg_install_repo ttyd' "$BOOTSTRAP" 2>/dev/null | wc -l | tr -d ' ')"
echo "TTYYD_IN_CRITICAL_PATH=$ttyd_critical_count"
[ "$ttyd_critical_count" = '0' ] || FAILURES=$((FAILURES + 1))
expect_pattern TTYYD_POSTBOOT 'POSTBOOT_TTYD=PASS' "$POSTBOOT"
expect_pattern DONT_TOUCH_DHCP "podkop\.settings\.dont_touch_dhcp='1'" "$BOOTSTRAP"
expect_pattern SHA256_VALIDATION 'actual_sha=.*sha256sum' "$BOOTSTRAP"
expect_pattern MANUAL_LINK_PRESERVATION_PRESENT 'collect_manual_links' "$UPDATER"
expect_pattern SUB_URL_MASKING_PRESENT 'mask_url' "$BOOTSTRAP"
expect_pattern TAILSCALE_KEY_MASKING_PRESENT 'tskey-\*\*\*MASKED\*\*\*|auth key.*not be printed' "$BOOTSTRAP"
expect_pattern MIRROR_VERSION_PINNED "PODKOP_APPROVED_VERSION='0\.7\.22'" "$BOOTSTRAP" "$SYNC"

expect_pattern OPENWRT_24_10_OPKG '24\.10.*|24\.10\)' "$BOOTSTRAP"
expect_pattern OPENWRT_25_12_APK '25\.12.*|25\.12\)' "$BOOTSTRAP"
expect_pattern NO_OPKG_IN_APK_PATH "apk:\*\.apk\).*apk add --allow-untrusted" "$BOOTSTRAP"
expect_pattern NO_APK_IN_OPKG_PATH "opkg:\*\.ipk\).*opkg install" "$BOOTSTRAP"
expect_pattern IPK_SHA256_VALIDATION "package_format='ipk'" "$SYNC"
expect_pattern APK_SHA256_VALIDATION "package_format='apk'" "$SYNC"
expect_pattern UNSUPPORTED_PACKAGE_MANAGER_FAILS_CLOSED 'Unsupported OpenWrt package manager' "$BOOTSTRAP"
expect_pattern ARCHITECTURE_MISMATCH_FAILS_CLOSED 'No .* packages for router architecture' "$BOOTSTRAP"
expect_pattern PACKAGE_MANAGER_AUTODETECT 'command -v apk.*|command -v opkg' "$BOOTSTRAP"
expect_pattern ARCHITECTURE_AUTODETECT 'apk --print-arch|opkg print-architecture' "$BOOTSTRAP"
expect_pattern MIRROR_OPKG_ALL_LAYOUT 'opkg/all' "$SYNC"
expect_pattern MIRROR_APK_ALL_LAYOUT 'apk/all' "$SYNC"

syntax_failures=0
shell_file_list="${TMPDIR:-/tmp}/adeptpro-shell-files.$$"
trap 'rm -f "$shell_file_list"' EXIT
find "$ROOT" -type f \( -name '*.sh' -o -name '*.init' \) -not -path '*/.git/*' | sort > "$shell_file_list"
while IFS= read -r script; do
  first_line="$(sed -n '1p' "$script")"
  case "$first_line" in
    *bash*)
      if command -v bash >/dev/null 2>&1; then bash -n "$script" || syntax_failures=$((syntax_failures + 1));
      else echo "BASH_N_SKIPPED=$script"; fi
      ;;
    *) sh -n "$script" || syntax_failures=$((syntax_failures + 1)) ;;
  esac
done < "$shell_file_list"
[ "$syntax_failures" -eq 0 ] && pass SHELL_SYNTAX || fail SHELL_SYNTAX

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$ROOT"/scripts/*.sh "$ROOT"/tests/*.sh "$ROOT"/deploy/bootstrap.adeptpro.online/scripts/*.sh \
    && pass SHELLCHECK || fail SHELLCHECK
else
  echo 'SHELLCHECK=SKIP_NOT_INSTALLED'
fi

echo "STATIC_TEST_FAILURES=$FAILURES"
[ "$FAILURES" -eq 0 ]
