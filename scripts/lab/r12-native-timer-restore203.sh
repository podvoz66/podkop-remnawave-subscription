#!/bin/sh
set -eu
[ "$(id -u)" = 0 ]
[ "$(cat /sys/class/net/eth0/address)" = 02:52:12:02:03:01 ]
[ "$(cat /sys/class/net/eth1/address)" = 02:52:12:02:03:02 ]
[ -z "$(ip -4 route show default)" ]
case ${1:-} in
probe) echo LAB203_TIMER_PROBE_GUEST_REACHED;;
restore)
 /etc/init.d/podkop stop >/dev/null 2>&1
 cp -p /root/r12-native-test/podkop.urltest-baseline /etc/config/podkop
 /etc/init.d/podkop start >/dev/null 2>&1
 /etc/init.d/dropbear start >/dev/null 2>&1
 ok=0
 for n in 1 2 3 4 5 6 7 8; do
  sleep 1
  if dig +short +timeout=2 +tries=1 @127.0.0.42 fakeip.podkop.fyi | grep -Eq '^198\.1[89]\.'; then ok=1; break; fi
 done
 [ "$ok" = 1 ]
 echo LAB203_TIMER_NATIVE_RESTORE_DNS_PASS_CLIENT_PROBE_REQUIRED
 ;;
*) exit 2;;
esac
