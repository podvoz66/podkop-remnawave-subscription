#!/bin/sh
# Read-only verification of LAB203 baseline: Stage6 needs no router config changes.
set -eu
[ "$(cat /sys/class/net/eth0/address)" = 02:52:12:02:03:01 ]
[ "$(cat /sys/class/net/eth1/address)" = 02:52:12:02:03:02 ]
cd /root/r12-stage6
sha256sum -c baseline.sha256
for f in network firewall dhcp; do cmp -s "$f" "/etc/config/$f"; done
# Use independent temporary output; never flush or reload firewall to check it.
t=$(mktemp -d /tmp/r12-s6verify.XXXXXX)
trap 'rm -f "$t/nft" "$t/routes" "$t/rules"; rmdir "$t"' EXIT
nft -s list ruleset > "$t/nft"
ip -4 route > "$t/routes"
ip rule > "$t/rules"
cmp -s nft.before "$t/nft"
cmp -s routes.before "$t/routes"
cmp -s rules.before "$t/rules"
[ -z "$(ip -4 route show default)" ]
[ -z "$(ip -6 route show default)" ]
echo STAGE6_ROUTER_NETWORK_FIREWALL_DNS_UNCHANGED_PASS
