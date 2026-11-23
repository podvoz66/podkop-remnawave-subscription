#!/bin/sh
# Separate procd service; it does not invoke Podkop or the new guard to schedule.
while :; do
    for path in /etc/podkop-emergency/*/state; do
        [ -f "$path" ] || continue
        id=${path%/state}; id=${id##*/}
        /usr/sbin/openwrt-emergency-rollback check "$id" >/dev/null 2>&1 || true
    done
    sleep 5
done
