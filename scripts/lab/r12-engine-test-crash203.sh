set -eu
[ "$(cat /sys/class/net/eth1/address)" = 02:52:12:02:03:02 ]
getpid(){ ubus call service list '{"name":"sing-box"}' | jsonfilter -e '@["sing-box"].instances["sing-box.main"].pid'; }
for n in 1 2 3 4 5 6; do
 pid=$(getpid)
 case "$pid" in ''|*[!0-9]*) echo STOP_MISSING_EXPECTED_PID; exit 1;; esac
 [ "$(readlink /proc/$pid/exe)" = /usr/bin/sing-box ]
 kill -KILL "$pid"
 echo "GUEST_SING_BOX_CRASH=$n"
 [ "$n" -eq 6 ] || sleep 6
done
sleep 8
[ -s /etc/sing-box/failsafe.last ]
cat /etc/sing-box/failsafe.last
! nft list table inet PodkopTable >/dev/null 2>&1
! ip rule show | grep -q 'lookup podkop'
! uci -q get dhcp.@dnsmasq[0].server | grep -q 127.0.0.42
echo TERMINAL_FAILSAFE_DIRECT_CONFIGURATION_PASS
