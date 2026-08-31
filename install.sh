#!/bin/sh
set -eu

BASE_URL="${BASE_URL:-https://bootstrap.adeptpro.online/openwrt/v1}"
BOOTSTRAP_URL="$BASE_URL/bootstrap.sh"
bootstrap_tmp="${TMPDIR:-/tmp}/adeptpro-bootstrap.$$"

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
export BASE_URL
sh "$bootstrap_tmp" "$@"
