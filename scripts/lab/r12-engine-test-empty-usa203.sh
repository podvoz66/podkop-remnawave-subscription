#!/bin/sh
# LAB203 only. 90 s guest-local rollback independent of podkop-engine.
set -eu
[ "$(cat /sys/class/net/eth1/address)" = 02:52:12:02:03:02 ]
[ -z "$(ip -4 route show default)" ]
umask 077
S=/root/r12-engine-runtime
case ${1:-apply} in
restore)
 [ -s "$S/podkop.before-empty-USA" ]
 /etc/init.d/podkop stop >/dev/null 2>&1 || true
 cp -p "$S/podkop.before-empty-USA" /etc/config/podkop
 /etc/init.d/podkop start >/dev/null 2>&1
 touch "$S/empty-USA-restored"
 echo EMPTY_USA_ORIGINAL_CONFIG_RESTORED
 ;;
apply)
 [ ! -e "$S/podkop.before-empty-USA" ]
 cp -p /etc/config/podkop "$S/podkop.before-empty-USA"
 # Install our rollback script before any mutations. No keys in this script.
 cp "$0" "$S/empty-USA-controller.sh"
 (trap '' HUP; sleep 90; [ -e "$S/empty-USA-restored" ] || sh "$S/empty-USA-controller.sh" restore) </dev/null >"$S/empty-USA-timer.log" 2>&1 &
 echo $! > "$S/empty-USA-timer.pid"
 uci set podkop.USA.proxy_config_type=urltest
 uci -q delete podkop.USA.outbound_json || true
 uci -q delete podkop.USA.urltest_proxy_links || true
 uci commit podkop
 test_id="r12-empty-USA-$(date +%s)-$$"
 logger -t r12-engine-test "$test_id"
 rc=0
 /etc/init.d/podkop restart > "$S/empty-USA-start.log" 2>&1 || rc=$?
 printf 'EMPTY_USA_NATIVE_START_RC=%s\n' "$rc"
 # Podkop sends fatal diagnostics to syslog, not the init script's stdout.
 logread | sed -n "/$test_id/,\$p" | grep -F 'URLTest proxy links is not set'
 if nft list table inet PodkopTable >/dev/null 2>&1; then echo PODKOP_TABLE_STILL_PRESENT; else echo PODKOP_TABLE_ABSENT; fi
 if ip rule show | grep -q 'lookup podkop'; then echo PODKOP_RULE_STILL_PRESENT; else echo PODKOP_RULE_ABSENT; fi
 if uci -q get dhcp.@dnsmasq[0].server | grep -q 127.0.0.42; then echo PROXY_DNS_STILL_CONFIGURED; else echo PROXY_DNS_ABSENT; fi
 echo EMPTY_USA_STATE_READY_FOR_CLIENT_PROBE_TIMER_ARMED
 ;;
*) exit 2;;
esac
