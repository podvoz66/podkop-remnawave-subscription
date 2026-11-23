#!/bin/sh
# Regression for native OpenWrt helpers sourced by the strict updater.
set -eu
repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
printf '%s\n' ': "${IPKG_INSTROOT}"' > "$tmp/functions"
: > "$tmp/constants"
printf '%s\n' 'sing_box_cf_add_proxy_outbound(){ printf "%s" "$1"; }' > "$tmp/facade"
printf '#!/bin/sh\nprintf "synthetic-link\\n"\n' > "$tmp/bin/uci"
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/sing-box"
chmod 700 "$tmp/bin/uci" "$tmp/bin/sing-box"
export PATH="$tmp/bin:$PATH" PODKOP_FUNCTIONS="$tmp/functions" PODKOP_CONSTANTS="$tmp/constants" PODKOP_FACADE="$tmp/facade"
unset IPKG_INSTROOT
. "$repo/scripts/podkop-failover-lib.sh"
REQUIRED_SECTIONS='main USA' PROBE_MARK=2097152 PROBE_URLS=http://fixture.invalid
make_probe_config "$tmp" "$tmp/config.json"
jq -e '.inbounds|length==3' "$tmp/config.json" >/dev/null
case $- in *u*) ;; *) echo CALLER_NOUNSET_LOST; exit 1;; esac
echo OPENWRT_OPTIONAL_VARIABLES_SUBSHELL_REGRESSION_PASS
