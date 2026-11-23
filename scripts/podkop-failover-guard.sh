#!/bin/sh
set -u
. "${GUARD_LIB:-/usr/lib/podkop-failover.sh}"
guard_setup
case "${1:-status}" in
    daemon)
        while :; do
            started=$(cut -d . -f 1 /proc/uptime)
            if (lock_control && guard_tick) >/dev/null 2>&1; then
                rm -f "$RUN/control-error"
            elif [ ! -f "$RUN/control-error" ]; then
                event 'Guard transition incomplete or lock busy: retry pending; inspect Console if persistent'
                : > "$RUN/control-error"
            fi
            elapsed=$(($(cut -d . -f 1 /proc/uptime)-started))
            delay=$((INTERVAL-elapsed)); [ "$delay" -gt 0 ] || delay=1
            sleep "$delay"
        done ;;
    prepare)
        lock_control || exit 75
        validate_sections "$CFG" && normal_health && shadow_health "$CFG" && snapshot_dns ;;
    boot)
        lock_control || exit 75
        [ -f "$DATA/normal-dns/dhcp" ] || exit 1
        recover_transaction || exit 1
        fail_open || exit 1
        # Cold boot has no flapping history: keep three probes, skip outage cooldown.
        rm -f "$RUN/last-transition" ;;
    fail-open)
        lock_control || exit 75
        : > "$DATA/manual-direct"
        snapshot_dns && fail_open ;;
    normal|auto)
        lock_control || exit 75
        rm -f "$DATA/manual-direct"
        # NORMAL means request verified recovery, never force unsafe routing.
        printf '0\n' > "$RUN/successes"
        guard_tick ;;
    tick) lock_control && guard_tick ;;
    status)
        mode=$(cat "$RUN/mode" 2>/dev/null || echo UNKNOWN)
        successes=$(cat "$RUN/successes" 2>/dev/null || echo 0)
        phase=$mode
        [ "$successes" -eq 0 ] || phase=RECOVERY
        printf 'mode=%s phase=%s manual_direct=%s failures=%s successes=%s wan=%s\n' "$mode" "$phase" "$(test -f "$DATA/manual-direct" && echo yes || echo no)" "$(cat "$RUN/failures" 2>/dev/null || echo 0)" "$successes" "$(cat "$RUN/wan" 2>/dev/null || echo UNKNOWN)" ;;
    *) echo 'Usage: podkop-failover-guard prepare|boot|daemon|tick|status|fail-open|normal|auto'; exit 2 ;;
esac
