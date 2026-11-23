#!/bin/sh
# Ordinary LAB203 reboot only. Never evidence of recovery from a broken disk/kernel.
set -eu
[ "$(id -u)" = 0 ]
[ "$(cat /sys/class/net/eth0/address)" = 02:52:12:02:03:01 ]
[ "$(cat /sys/class/net/eth1/address)" = 02:52:12:02:03:02 ]
[ -z "$(ip -4 route show default)" ] && [ -z "$(ip -6 route show default)" ]
S=/root/r12-engine-baseline
case ${1:-preflight} in
preflight)
 sh "$S/rollback.sh" check
 [ -L /etc/rc.d/S95podkop-engine ] && [ -L /etc/rc.d/S99podkop ]
 sing-box check -c /etc/sing-box/config.json >/dev/null 2>&1
 cat /proc/sys/kernel/random/boot_id > "$S/boot.before-reboot"
 sync
 echo LAB203_REBOOT_PREFLIGHT_PASS
 ;;
request)
 [ -s "$S/boot.before-reboot" ]
 [ "$(cat "$S/boot.before-reboot")" = "$(cat /proc/sys/kernel/random/boot_id)" ]
 (trap '' HUP; sleep 3; reboot) </dev/null >"$S/reboot.log" 2>&1 &
 echo ONLY_LAB203_REBOOT_SCHEDULED
 ;;
verify)
 [ "$(cat "$S/boot.before-reboot")" != "$(cat /proc/sys/kernel/random/boot_id)" ]
 pid=$(ubus call service list '{"name":"sing-box"}' | jsonfilter -e '@["sing-box"].instances["sing-box.main"].pid')
 [ -n "$pid" ] && [ "$(readlink /proc/$pid/exe)" = /usr/bin/sing-box ]
 nft list table inet PodkopTable >/dev/null
 ip rule | grep 'lookup podkop'
 dig +short +timeout=3 +tries=1 @127.0.0.42 fakeip.podkop.fyi | grep -E '^198\.1[89]\.'
 echo NEW_BOOT_NATIVE_AUTOSTART_LOCAL_DNS_PASS_CLIENT_PROBE_REQUIRED
 ;;
*) exit 2;;
esac
