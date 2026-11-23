#!/bin/sh
# LAB203-only bounded test; run detached, retrieve its log in a new serial session.
set -eu
[ "$(id -u)" = 0 ]
[ "$(cat /sys/class/net/eth1/address)" = 02:52:12:02:03:02 ]
[ -z "$(ip -4 route show default)" ]
getpid(){ ubus call service list '{"name":"sing-box"}' | jsonfilter -e '@["sing-box"].instances["sing-box.main"].pid'; }
for n in $(seq 1 40); do
 p=$(cat /var/run/podkop_list_update.pid 2>/dev/null || true)
 if { [ -z "$p" ] || [ ! -d /proc/$p ]; } && ! pgrep -f 'podkop list_updat[e]' >/dev/null; then break; fi
 [ "$n" -lt 40 ] || { echo STOP_LIST_UPDATE_STILL_ACTIVE; exit 1; }
 sleep 5
done
dig +short +timeout=3 +tries=1 @127.0.0.42 fakeip.podkop.fyi | grep -Eq '^198\.1[89]\.'
# Allow the native 20 s observer to see a successful FakeIP answer and arm itself.
sleep 25
pid=$(getpid)
case "$pid" in ''|*[!0-9]*) exit 1;; esac
[ "$(readlink /proc/$pid/exe)" = /usr/bin/sing-box ]
born=$(awk '{print $22}' /proc/$pid/stat)
resume(){
 if [ -r /proc/$pid/stat ] && [ "$(awk '{print $22}' /proc/$pid/stat)" = "$born" ] && [ "$(readlink /proc/$pid/exe)" = /usr/bin/sing-box ]; then kill -CONT "$pid"; fi
}
trap resume EXIT HUP INT TERM
start=$(date +%s)
kill -STOP "$pid"
echo "SING_BOX_HANG_STARTED=$start"
for n in $(seq 1 24); do
 sleep 5
 current=$(getpid || true)
 if [ -n "$current" ] && [ "$current" != "$pid" ]; then
  [ "$(readlink /proc/$current/exe)" = /usr/bin/sing-box ]
  dig +short +timeout=3 +tries=1 @127.0.0.42 fakeip.podkop.fyi | grep -Eq '^198\.1[89]\.'
  echo "LIVENESS_REPLACED_HUNG_PROCESS_SECONDS=$(($(date +%s)-start))"
  logread | grep 'has not answered DNS' | tail -1
  echo HANG_RECOVERY_PROCESS_DNS_PASS_CLIENT_PROBE_REQUIRED
  exit 0
 fi
done
echo HANG_RECOVERY_TIMEOUT_RESUMING_ORIGINAL_PROCESS
exit 1
