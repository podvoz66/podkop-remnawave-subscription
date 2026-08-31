#!/bin/sh
set -eu

[ -f /etc/config/podkop ] || {
  echo '[ERROR] Existing Podkop configuration was not found.' >&2
  exit 1
}

BASE_URL="${BASE_URL:-https://bootstrap.adeptpro.online/openwrt/v1}"
BOOTSTRAP_URL="$BASE_URL/bootstrap.sh"
bootstrap_tmp="${TMPDIR:-/tmp}/adeptpro-bootstrap-existing.$$"

cleanup() {
  rm -f "$bootstrap_tmp"
}
trap cleanup EXIT HUP INT TERM

if command -v curl >/dev/null 2>&1; then
  curl -fsSL --connect-timeout 25 --max-time 180 "$BOOTSTRAP_URL" -o "$bootstrap_tmp"
elif command -v wget >/dev/null 2>&1; then
  wget -T 180 -O "$bootstrap_tmp" "$BOOTSTRAP_URL"
else
  echo '[ERROR] curl or wget is required.' >&2
  exit 1
fi

[ -s "$bootstrap_tmp" ] || { echo '[ERROR] Downloaded bootstrap is empty.' >&2; exit 1; }
chmod 700 "$bootstrap_tmp"

INSTALL_PODKOP="${INSTALL_PODKOP:-0}"
UPDATE_PODKOP="${UPDATE_PODKOP:-0}"
SET_OPENWRT_HOSTNAME="${SET_OPENWRT_HOSTNAME:-0}"
REBOOT_AFTER="${REBOOT_AFTER:-0}"
export BASE_URL INSTALL_PODKOP UPDATE_PODKOP SET_OPENWRT_HOSTNAME REBOOT_AFTER
sh "$bootstrap_tmp" "$@"
