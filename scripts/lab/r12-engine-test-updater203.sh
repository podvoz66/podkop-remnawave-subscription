#!/bin/sh
# Sandbox UCI/dry-run only: does NOT activate guard, replace live keys, or change routes.
set -eu
umask 077
[ "$(cat /sys/class/net/eth1/address)" = 02:52:12:02:03:02 ]
S=/root/r12-engine-updater-test-$(date +%s)
[ ! -e "$S" ]
mkdir -m 700 "$S"
for name in podkop-failover-lib.sh update-podkop-from-remnawave.sh; do
 curl -fsS "http://10.253.203.1:8001/$name" -o "$S/$name"
done
printf '%s  %s\n' 'cedc1766b3dde65ae7c12febbfb56e727f9ed8b2b42f7d89f1c22126891f8bbb' "$S/podkop-failover-lib.sh" 'fdaa776fbc6e32d8d3e982eb1ce445a40e9478dde47ec1485300517203a615b9' "$S/update-podkop-from-remnawave.sh" | sha256sum -c - >/dev/null
mkdir -p "$S/root/etc/config/.uci" "$S/root/etc/podkop-remnawave"
CFG=$S/root/etc/config
: > "$CFG/podkop"; : > "$CFG/dhcp"
uuid=$(cat /root/r12-engine-runtime/uuid)
for sec in main USA; do
 uci -c "$CFG" set "podkop.$sec=section"
 uci -c "$CFG" set "podkop.$sec.connection_type=proxy"
 uci -c "$CFG" set "podkop.$sec.proxy_config_type=urltest"
 uci -c "$CFG" add_list "podkop.$sec.urltest_proxy_links=vless://$uuid@10.253.203.1:10443?security=tls&sni=fixture.r12.test#manual-$sec"
done
unset uuid
uci -c "$CFG" commit podkop
sha256sum "$CFG/podkop" > "$S/sandbox.before"
sha256sum /etc/config/podkop > "$S/live.before"
export PODKOP_ROOT=$S/root GUARD_LIB=$S/podkop-failover-lib.sh
export CURL_CA_BUNDLE=/root/r12-engine-runtime/ca.crt
export PROBE_URLS=http://10.253.203.1:8001/probe64k
for kind in valid empty malformed 500 timeout unavailable; do
 url=https://10.253.203.1:8002/subscription/$kind
 [ "$kind" != unavailable ] || url=https://10.253.203.1:8999/subscription/valid
 printf "SUB_URL='%s'\n" "$url" > "$S/root/etc/podkop-remnawave/subscription.conf"
 rc=0
 sh "$S/update-podkop-from-remnawave.sh" --dry-run > "$S/$kind.log" 2>&1 || rc=$?
 # Only fixed sanitized updater messages may be printed, never its config or links.
 case "$kind" in valid) [ "$rc" = 0 ];; *) [ "$rc" != 0 ];; esac
 sha256sum -c "$S/sandbox.before" >/dev/null
 sha256sum -c "$S/live.before" >/dev/null
 printf 'UPDATER_SANDBOX_%s_EXPECTED_RC=%s_CONFIG_UNCHANGED\n' "$kind" "$rc"
done
echo UPDATER_DOWNLOAD_VALIDATION_ONLY_NOT_ACTIVATION_TRANSACTION
