set -eu
[ "$(cat /sys/class/net/eth1/address)" = 02:52:12:02:03:02 ]
/etc/init.d/podkop stop
! nft list table inet PodkopTable >/dev/null 2>&1
! ip rule show | grep -q 'lookup podkop'
! uci -q get dhcp.@dnsmasq[0].server | grep -q 127.0.0.42
echo NATIVE_STOP_REMOVED_PODKOP_RULES_AND_PROXY_DNS
