#!/bin/sh
# Guest package/config rollback only. NOT recovery from a broken kernel or disk.
set -eu
S=/root/r12-engine-baseline
[ "$(id -u)" = 0 ]
[ "$(cat /sys/class/net/eth0/address)" = 02:52:12:02:03:01 ]
[ "$(cat /sys/class/net/eth1/address)" = 02:52:12:02:03:02 ]
[ -z "$(ip -4 route show default)" ]
sha256sum -c "$S/SHA256SUMS" >/dev/null
case ${1:-check} in
check)
    [ -s "$S/etc.tgz" ] && [ -s "$S/packages.before" ]
    tar -tzf "$S/etc.tgz" >/dev/null
    echo R12_GUEST_ROLLBACK_ASSETS_OK_NOT_HOST_RECOVERY
    ;;
apply)
    [ -s "$S/transaction-new.names" ]
    # List must contain only new packages, captured from the reviewed solver result.
    while read -r package; do
        case "$package" in *[!a-zA-Z0-9+-]*|'') exit 1;; esac
        if grep -q "^$package-[0-9]" "$S/packages.before"; then
            echo STOP_BASELINE_PACKAGE_IN_DELETE_SET; exit 1
        fi
    done < "$S/transaction-new.names"
    for service in podkop sing-box podkop-engine; do
        [ ! -x /etc/init.d/$service ] || /etc/init.d/$service stop
    done
    # No download or dependency upgrades are possible. Never restore APK DB by copying it.
    : > "$S/rollback-installed.names"
    while read -r package; do
        if apk info -e "$package" >/dev/null 2>&1; then
            printf '%s\n' "$package" >> "$S/rollback-installed.names"
        fi
    done < "$S/transaction-new.names"
    if [ -s "$S/rollback-installed.names" ]; then
        apk --no-network --repositories-file /dev/null del --purge $(cat "$S/rollback-installed.names")
    fi
    tar -xzf "$S/etc.tgz" -C /
    apk info -v 2>/dev/null | sort > "$S/packages.after-rollback"
    cmp "$S/packages.before" "$S/packages.after-rollback"
    cmp "$S/world.before" /etc/apk/world
    /etc/init.d/network reload
    sleep 3
    ip -4 route > "$S/routes.after-rollback"
    ip rule > "$S/rules.after-rollback"
    cmp "$S/routes.before" "$S/routes.after-rollback"
    cmp "$S/rules.before" "$S/rules.after-rollback"
    # nft prints empty counters as "counter", populated counters with values.
    # Compare rules, not traffic-dependent packet/byte statistics.
    sed -E 's/counter packets [0-9]+ bytes [0-9]+/counter/g' "$S/nft.before" > "$S/nft.before.semantic"
    nft list ruleset | sed -E 's/counter packets [0-9]+ bytes [0-9]+/counter/g' > "$S/nft.after.semantic"
    cmp "$S/nft.before.semantic" "$S/nft.after.semantic"
    /etc/init.d/dnsmasq restart
    echo R12_PACKAGE_CONFIG_ROLLBACK_PASS_TRANSIT_STILL_REQUIRES_PROBE
    ;;
*) echo 'usage: check|apply' >&2; exit 1;;
esac
