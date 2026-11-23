#!/bin/sh
# Independent, fixed VM202 profile. No source/exec of Fail-Open code.
set -eu
umask 077
R=${ROLLBACK_ROOT:-}
BASE="$R/etc/podkop-emergency"
ID=${2:-}
case "$ID" in ''|*[!a-zA-Z0-9_-]*) echo 'Invalid rollback ID' >&2; exit 64;; esac
D="$BASE/$ID"
mkdir -p "$BASE" "$R/var/lock"
chmod 700 "$BASE"
exec 8>"$R/var/lock/podkop-emergency.lock"
flock -n 8 || exit 75
now() { cut -d . -f 1 "$R/proc/uptime"; }
boot() { cat "$R/proc/sys/kernel/random/boot_id"; }
state() { printf '%s\n' "$1" > "$D/state.new"; mv "$D/state.new" "$D/state"; }
log() { printf '%s\n' "$1" >> "$D/events"; }
copy_file() {
    cf_src=$1 cf_dst=$2
    mkdir -p "$(dirname "$cf_dst")"
    cf_tmp=$(mktemp "$cf_dst.XXXXXX") || return 1
    if cp -p "$cf_src" "$cf_tmp" && mv -f "$cf_tmp" "$cf_dst"; then return 0; fi
    rm -f "$cf_tmp"; return 1
}
fixed_paths() {
    cat <<'PATHS'
etc/config/podkop
etc/config/dhcp
etc/config/sing-box
etc/config/network
etc/config/firewall
etc/sing-box/config.json
etc/crontabs/root
etc/init.d/podkop
etc/init.d/sing-box
etc/init.d/dnsmasq
etc/init.d/cron
usr/bin/podkop
usr/bin/update-podkop-from-remnawave.sh
usr/bin/update-podkop-from-remnawave.real.sh
usr/bin/podkop-all-lists-guard.sh
usr/lib/podkop-failover.sh
usr/bin/podkop-failover-guard
etc/init.d/podkop-failover-guard
etc/podkop-failover/normal-dns/dhcp
etc/podkop-failover/manual-direct
PATHS
}
verify() {
    [ -f "$D/bundle.sha256" ] || return 1
    (cd "$D"; sha256sum -c bundle.sha256 >/dev/null 2>&1) || return 1
    # Bundle is generated here, never accept archives from a URL/user input.
    (cd "$D/snapshot"; sha256sum -c manifest >/dev/null 2>&1)
}
remove_interception() {
    if nft list table inet PodkopTable >/dev/null 2>&1; then nft delete table inet PodkopTable || return 1; fi
    ri=0
    while ip -4 rule show | grep -Eq '^105:.*fwmark 0x100000/0x100000 lookup podkop( |$)'; do
        [ "$ri" -lt 16 ] || return 1
        ip -4 rule del priority 105 fwmark 0x100000/0x100000 table podkop || return 1
        ri=$((ri+1))
    done
    if ip -4 route show table podkop 2>/dev/null | grep -q '^local default dev lo'; then
        ip -4 route del local default dev lo table podkop || return 1
    fi
}
barrier() {
    nft list table inet podkop_emergency >/dev/null 2>&1 && return 0
    nft -f - <<'NFT'
table inet podkop_emergency {
 chain forward { type filter hook forward priority -5; policy accept; ip daddr 198.18.0.0/15 reject; }
 chain output { type filter hook output priority -5; policy accept; ip daddr 198.18.0.0/15 reject; }
}
NFT
}
restore() {
    verify || { log 'BLOCKER: backup integrity'; return 1; }
    # Neither foreign WAN/network config nor fw4 may be blindly overwritten.
    for p in etc/config/network etc/config/firewall; do
        cmp -s "$D/snapshot/files/$p" "$R/$p" || { log 'BLOCKER: protected network/firewall changed'; return 1; }
    done
    fw_current=$(mktemp "$BASE/fw4.XXXXXX") || return 1
    if ! nft -s list table inet fw4 > "$fw_current" || ! cmp -s "$D/snapshot/fw4.audit" "$fw_current"; then
        rm -f "$fw_current"; log 'BLOCKER: foreign fw4 runtime changed'; return 1
    fi
    rm -f "$fw_current"
    services=$(ubus call service list '{"name":"podkop-failover-guard"}') || return 1
    if printf '%s' "$services" | jq -e 'has("podkop-failover-guard")' >/dev/null; then
        # Native procd API, never invoke the new init script or guard executable.
        ubus call service delete '{"name":"podkop-failover-guard"}' >/dev/null || return 1
    fi
    exec 9>"$R/var/lock/podkop-control.lock"
    flock -w 5 9 || { log 'BLOCKER: guard/control process did not release lock'; return 1; }
    barrier || return 1
    remove_interception || return 1
    # Remove only explicit files that did not exist at snapshot time.
    while IFS= read -r p; do rm -f "$R/$p" || return 1; done < "$D/snapshot/absent"
    while IFS= read -r p; do
        case "$p" in etc/config/network|etc/config/firewall) continue;; esac
        copy_file "$D/snapshot/files/$p" "$R/$p" || return 1
    done < "$D/snapshot/present"
    # Restore only this profile's autostart links. No network/SSH/ZeroTier units.
    for service in podkop sing-box dnsmasq podkop-failover-guard; do
        for p in "$R/etc/rc.d/"[SK][0-9][0-9]"$service"; do [ ! -L "$p" ] || rm "$p" || return 1; done
    done
    while IFS=' ' read -r p target; do
        [ -n "$p" ] || continue
        ln -s "$target" "$R/etc/rc.d/$p" || return 1
    done < "$D/snapshot/rc-links"
    # Use captured, native init/config and cached local rulesets. No list download.
    "$R/etc/init.d/sing-box" stop >/dev/null 2>&1 || return 1
    if sing-box check -c "$R/etc/sing-box/config.json" >/dev/null 2>&1 &&
       "$R/etc/init.d/sing-box" start >/dev/null 2>&1; then
        sleep 2
        runtime=$(ubus call service list '{"name":"sing-box"}') || return 1
        if printf '%s' "$runtime" | jq -e '.["sing-box"].instances | any(.running == true)' >/dev/null 2>&1; then
            nft -f "$D/snapshot/podkop.nft" || return 1
            ip -4 route add local default dev lo table podkop || return 1
            ip -4 rule add priority 105 fwmark 0x100000/0x100000 table podkop || return 1
            "$R/etc/init.d/dnsmasq" restart >/dev/null 2>&1 || return 1
            if nft list table inet podkop_failopen >/dev/null 2>&1; then nft delete table inet podkop_failopen || return 1; fi
            nft delete table inet podkop_emergency || return 1
            state RESTORED_UNVERIFIED
            log 'Baseline files/runtime restored; WAN/LAN health NOT attested'
            return 0
        fi
    fi
    # Emergency DIRECT is independent of the new guard. Never claim baseline health.
    remove_interception || return 1
    copy_file "$D/snapshot/direct-dhcp" "$R/etc/config/dhcp" || return 1
    "$R/etc/init.d/dnsmasq" restart >/dev/null 2>&1 || return 1
    state DIRECT_UNVERIFIED
    log 'BLOCKER: baseline sing-box unavailable; emergency DIRECT requires verification'
}
case "${1:-}" in
 import)
    expected=${3:-}; [ "${#expected}" -eq 64 ]; case "$expected" in *[!0-9a-f]*) exit 64;; esac
    mkdir -p "$D"
    incoming=$(mktemp -d "$D/import.XXXXXX")
    trap 'rm -rf "$incoming"' EXIT
    cat > "$incoming/bundle.tar"
    [ "$(sha256sum "$incoming/bundle.tar" | awk '{print $1}')" = "$expected" ]
    # Only locally generated, checksum-pinned host archives are accepted.
    tar -tf "$incoming/bundle.tar" | while IFS= read -r name; do
        case "$name" in snapshot/|snapshot/*) ;; *) exit 1;; esac
        case "$name" in *..*|*[!a-zA-Z0-9_./-]*) exit 1;; esac
    done
    tar -xf "$incoming/bundle.tar" -C "$incoming"
    (cd "$incoming/snapshot"; sha256sum -c manifest >/dev/null 2>&1)
    # Do not discard the old copy before the replacement is complete.
    if [ -d "$D/snapshot" ]; then mv "$D/snapshot" "$incoming/previous"; fi
    mv "$incoming/snapshot" "$D/snapshot"
    mv "$incoming/bundle.tar" "$D/bundle.tar"
    (cd "$D"; sha256sum bundle.tar > bundle.sha256)
    verify ;;
 capture)
    for other in "$BASE"/*/state; do
        [ ! -f "$other" ] || [ "$(cat "$other")" != ARMED ] || exit 75
    done
    [ ! -e "$D" ] || exit 73
    mkdir -p "$D/snapshot/files"; chmod 700 "$D" "$D/snapshot"
    fixed_paths > "$D/snapshot/paths"
    # The captured JSON must be the one native procd will actually start.
    [ "$(uci -c "$R/etc/config" -q get sing-box.main.enabled)" = 1 ]
    [ "$(uci -c "$R/etc/config" -q get sing-box.main.conffile)" = /etc/sing-box/config.json ]
    [ "$(ip -4 rule show | grep -Ec '^105:.*fwmark 0x100000/0x100000 lookup podkop( |$)')" -eq 1 ]
    saved_route=$(ip -4 route show table podkop)
    [ "$(printf '%s\n' "$saved_route" | wc -l)" -eq 1 ]
    printf '%s\n' "$saved_route" | grep -Eq '^local default dev lo( |$)'
    # No remote rulesets: their offline availability is not established.
    jq -e '[.route.rule_set[]? | select(.type != "local")] | length == 0' "$R/etc/sing-box/config.json" >/dev/null || exit 1
    jq -r '.route.rule_set[]? | .path' "$R/etc/sing-box/config.json" | while IFS= read -r p; do
        case "$p" in /tmp/sing-box/rulesets/*) ;; *) exit 1;; esac
        case "$p" in *..*|*[!a-zA-Z0-9_./-]*) exit 1;; esac
        printf '%s\n' "${p#/}" >> "$D/snapshot/paths"
    done
    : > "$D/snapshot/present"; : > "$D/snapshot/absent"
    while IFS= read -r p; do
        [ ! -L "$R/$p" ] || exit 1
        if [ -f "$R/$p" ]; then
            mkdir -p "$D/snapshot/files/$(dirname "$p")"; cp -p "$R/$p" "$D/snapshot/files/$p"
            echo "$p" >> "$D/snapshot/present"
        else echo "$p" >> "$D/snapshot/absent"; fi
    done < "$D/snapshot/paths"
    for p in etc/config/network etc/config/firewall etc/config/dhcp etc/config/sing-box etc/sing-box/config.json etc/init.d/sing-box etc/init.d/dnsmasq; do
        test -f "$D/snapshot/files/$p"
    done
    : > "$D/snapshot/rc-links"
    for service in podkop sing-box dnsmasq podkop-failover-guard; do
        for p in "$R/etc/rc.d/"[SK][0-9][0-9]"$service"; do
            [ -L "$p" ] || continue
            target=$(readlink "$p"); [ "$target" = "../init.d/$service" ] || exit 1
            printf '%s %s\n' "${p##*/}" "$target" >> "$D/snapshot/rc-links"
        done
    done
    nft -s list table inet PodkopTable > "$D/snapshot/podkop.nft"
    nft -s list table inet fw4 > "$D/snapshot/fw4.audit"
    ip -4 rule show > "$D/snapshot/ip-rule.audit"
    ip -4 route show table all > "$D/snapshot/ip-route.audit"
    ip -6 rule show > "$D/snapshot/ip6-rule.audit"
    ip -6 route show table all > "$D/snapshot/ip6-route.audit"
    # Candidate DIRECT DNS is local only, never activated during capture.
    mkdir "$D/dns-stage" "$D/dns-stage/.uci"
    cp "$R/etc/config/dhcp" "$D/dns-stage/dhcp"
    uci -c "$D/dns-stage" -t "$D/dns-stage/.uci" -q delete 'dhcp.@dnsmasq[0].server' || true
    uci -c "$D/dns-stage" -t "$D/dns-stage/.uci" -q delete 'dhcp.@dnsmasq[0].resolvfile' || true
    uci -c "$D/dns-stage" -t "$D/dns-stage/.uci" set 'dhcp.@dnsmasq[0].noresolv=1'
    uci -c "$D/dns-stage" -t "$D/dns-stage/.uci" set 'dhcp.@dnsmasq[0].cachesize=150'
    for dns in 1.1.1.1 9.9.9.9; do uci -c "$D/dns-stage" -t "$D/dns-stage/.uci" add_list "dhcp.@dnsmasq[0].server=$dns"; done
    uci -c "$D/dns-stage" -t "$D/dns-stage/.uci" commit dhcp
    cp "$D/dns-stage/dhcp" "$D/snapshot/direct-dhcp"; rm -rf "$D/dns-stage"
    (cd "$D/snapshot"; find . -type f ! -name manifest -exec sha256sum '{}' \; > manifest)
    (cd "$D"; tar -cf bundle.tar snapshot; sha256sum bundle.tar > bundle.sha256)
    state CAPTURED
    echo 'CAPTURED: baseline health and restore acceptance still required' ;;
 verify) verify ;;
 accept) verify; [ "${3:-}" = "$(sha256sum "$D/bundle.tar" | awk '{print $1}')" ]; : > "$D/accepted" ;;
 arm|arm-canary)
    for other in "$BASE"/*/state; do
        [ ! -f "$other" ] || [ "$(cat "$other")" != ARMED ] || exit 75
    done
    watcher=$(ubus call service list '{"name":"openwrt-emergency-rollback"}')
    printf '%s' "$watcher" | jq -e '.["openwrt-emergency-rollback"].instances | any(.running == true)' >/dev/null 2>&1
    if [ "$1" = arm-canary ]; then [ ! -e "$D" ] || exit 73; mkdir -p "$D"; : > "$D/canary"; state CAPTURED; else verify; [ -f "$D/accepted" ]; fi
    seconds=${3:-}; case "$seconds" in ''|*[!0-9]*) exit 64;; esac
    [ "$seconds" -ge 60 ] && [ "$seconds" -le 3600 ]
    [ "$(cat "$D/state")" = CAPTURED ]
    boot > "$D/boot"; printf '%s\n' "$(($(now)+seconds))" > "$D/deadline"
    head -c 24 "$R/dev/urandom" | od -An -tx1 | tr -d ' \n' > "$D/token"
    : > "$D/attempts"; state ARMED; sync
    echo 'ARMED' ;;
 confirm)
    [ "$(cat "$D/state")" = ARMED ]
    [ "$(cat "$D/boot")" = "$(boot)" ] && [ "$(now)" -lt "$(cat "$D/deadline")" ]
    [ "${3:-}" = "$(cat "$D/token")" ]; state CONFIRMED; sync ;;
 check)
    [ "$(cat "$D/state")" = ARMED ] || exit 0
    if [ "$(cat "$D/boot")" = "$(boot)" ] && [ "$(now)" -lt "$(cat "$D/deadline")" ]; then exit 0; fi
    attempts=$(cat "$D/attempts"); attempts=${attempts:-0}
    [ "$attempts" -lt 3 ] || { state BLOCKED; log 'BLOCKER: retry limit reached'; exit 1; }
    printf '%s\n' "$((attempts+1))" > "$D/attempts"
    # Retry at most once a minute, independently of wall clock/NTP.
    boot > "$D/boot"; printf '%s\n' "$(($(now)+60))" > "$D/deadline"
    if [ -f "$D/canary" ]; then state CANARY_FIRED; log 'Local timer fired without restore'; else restore; fi ;;
 restore)
    current=$(cat "$D/state" 2>/dev/null || true)
    case "$current" in RESTORED_UNVERIFIED|DIRECT_UNVERIFIED) exit 0;; esac
    restore ;;
 status) cat "$D/state" ;;
 *) echo 'capture|verify|arm|confirm|check|restore|status ID' >&2; exit 64 ;;
esac
