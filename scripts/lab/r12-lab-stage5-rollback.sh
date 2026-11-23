#!/bin/sh
# Exact rollback tested inside LAB203, not a Proxmox script.
set -eu
[ "$(cat /sys/class/net/eth0/address)" = 02:52:12:02:03:01 ]
[ "$(cat /sys/class/net/eth1/address)" = 02:52:12:02:03:02 ]
cd /root/r12-stage5
sha256sum -c network.sha256
[ -z "$(uci -q changes network)" ]
cp -p network.before /etc/config/network
/etc/init.d/network reload
printf 'R12_ROLLBACK_APPLIED\n'
