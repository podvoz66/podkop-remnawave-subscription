#!/bin/sh
# Native Podkop owns DNS (dont_touch_dhcp=0). No guard daemon or DNS ownership migration.
native_setup() {
    NDATA="$DATA/native"
    [ "${DRY_RUN:-0}" != 1 ] || return 0
    mkdir -p "$NDATA/managed"
    chmod 700 "$NDATA" "$NDATA/managed"
}
native_service() {
    # Init may spawn long-lived children: they must not retain transaction locks.
    bounded_run 35 "${NATIVE_SERVICE:-$R/etc/init.d/podkop}" "$1" 9>&- 8>&- 7>&- 6>&-
}
native_stage_ownership() (
    # Existing identical manual links stay manual; only an exact old snapshot owns them.
    : > "$4" || exit 1
    while IFS= read -r no_link; do
        if ! grep -Fxq -- "$no_link" "$2" ||
           { [ -f "$3" ] && grep -Fxq -- "$no_link" "$3"; }; then
            printf '%s\n' "$no_link" >> "$4" || exit 1
        fi
    done < "$1"
)
native_local_health() {
    [ "$(uget "$CFG" podkop.settings.dont_touch_dhcp)" = 0 ] || return 1
    sing-box check -c "$R/etc/sing-box/config.json" >/dev/null 2>&1 || return 1
    nl_pid=$(ubus call service list '{"name":"sing-box"}' 2>/dev/null | jsonfilter -e '@["sing-box"].instances["sing-box.main"].pid') || return 1
    case "$nl_pid" in ''|*[!0-9]*) return 1;; esac
    kill -0 "$nl_pid" 2>/dev/null || return 1
    nl_dns=$(bounded_run 4 dig +short +timeout=2 +tries=1 @127.0.0.1 "${DNS_PROBE_NAME:-example.com}" A 2>/dev/null) || return 1
    printf '%s\n' "$nl_dns" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || return 1
}
native_live_health() { native_local_health && shadow_health "$CFG"; }
native_wait_ready() {
    # Native init returns before procd necessarily publishes/listens on its PID.
    for nw_try in 1 2 3 4 5 6 7 8; do
        sleep 1
        if native_local_health; then shadow_health "$CFG"; return $?; fi
    done
    return 1
}
native_restore() {
    [ -f "$NDATA/pending" ] || return 0
    (cd "$NDATA/previous-good" && sha256sum -c SHA256SUMS >/dev/null) || return 1
    # Native stop restores DIRECT DNS BEFORE stopping the last DNS process.
    native_service stop >/dev/null 2>&1 || return 1
    atomic_copy "$NDATA/previous-good/podkop" "$CFG/podkop" || return 1
    atomic_copy "$NDATA/previous-good/sing-box.json" "$R/etc/sing-box/config.json" || return 1
    for nr_sec in $REQUIRED_SECTIONS; do
        atomic_copy "$NDATA/previous-good/$nr_sec.managed" "$NDATA/managed/$nr_sec" || return 1
    done
    if native_service start >/dev/null 2>&1 && native_wait_ready; then
        rm -f "$NDATA/pending"
        event 'Native update rolled back: previous working config restored'
        return 0
    fi
    native_service stop >/dev/null 2>&1 || return 1
    event 'Native rollback incomplete: previous keys restored; native DIRECT requested; pending retained'
    return 1
}
native_apply() (
    # One subscription + control lock cover backup, config and ownership snapshots.
    lock_control || exit 75
    [ ! -f "$NDATA/pending" ] || exit 1
    [ "$original_hash" = "$(sha256sum "$CFG/podkop" | awk '{print $1}')" ] || exit 1
    [ -z "$(uci -c "$CFG" -q changes podkop 2>/dev/null)" ] || exit 1
    [ -z "$(uci -c "$CFG" -q changes dhcp 2>/dev/null)" ] || exit 1
    native_live_health || exit 1
    na_tmp=$(mktemp -d "$NDATA/.previous-good.XXXXXX") || exit 1
    trap 'rm -rf "$na_tmp"; if [ -f "$NDATA/pending" ]; then native_restore || event "Native recovery pending: operator review required"; fi' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    cp -p "$CFG/podkop" "$na_tmp/podkop" || exit 1
    cp -p "$CFG/dhcp" "$na_tmp/dhcp" || exit 1
    cp -p "$R/etc/sing-box/config.json" "$na_tmp/sing-box.json" || exit 1
    for na_sec in $REQUIRED_SECTIONS; do
        if [ -f "$NDATA/managed/$na_sec" ]; then cp -p "$NDATA/managed/$na_sec" "$na_tmp/$na_sec.managed" || exit 1
        else : > "$na_tmp/$na_sec.managed"; fi
    done
    (cd "$na_tmp" && sha256sum podkop dhcp sing-box.json *.managed > SHA256SUMS) || exit 1
    # Never rotate a still-pending transaction; an interrupted rename is detected.
    rm -rf "$NDATA/previous-good.old"
    [ ! -d "$NDATA/previous-good" ] || mv "$NDATA/previous-good" "$NDATA/previous-good.old" || exit 1
    mv "$na_tmp" "$NDATA/previous-good" || exit 1
    : > "$NDATA/pending"
    sync
    atomic_copy "$work/podkop" "$CFG/podkop" || exit 1
    if ! native_service restart >/dev/null 2>&1 || ! native_wait_ready; then exit 1; fi
    for na_sec in $REQUIRED_SECTIONS; do
        atomic_copy "$work/$na_sec.managed" "$NDATA/managed/$na_sec" || exit 1
    done
    sync
    rm -f "$NDATA/pending"
    event 'Native subscription committed: main USA validated; previous-good retained'
)
