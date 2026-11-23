#!/bin/sh
# State/ownership/rollback regression only; real network acceptance is LAB evidence.
set -eu
repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
. "$repo/scripts/podkop-native-update-lib.sh"
R=$tmp; DATA=$tmp/state; CFG=$tmp/cfg; REQUIRED_SECTIONS='main USA'; DRY_RUN=0
mkdir -p "$CFG" "$R/etc/sing-box" "$tmp/work"
work=$tmp/work
printf 'previous\n' > "$CFG/podkop"; printf 'candidate\n' > "$work/podkop"
printf 'dns\n' > "$CFG/dhcp"; printf '{}\n' > "$R/etc/sing-box/config.json"
for sec in $REQUIRED_SECTIONS; do echo managed > "$work/$sec.managed"; done
native_setup
uget(){ echo 0; }
uci(){ :; }
lock_control(){ :; }
event(){ printf '%s\n' "$1" >> "$tmp/events"; }
atomic_copy(){ cp "$1" "$2.tmp" && mv "$2.tmp" "$2"; }
native_live_health(){ return 0; }
native_wait_ready(){ return 0; }
native_service(){ [ "$1" != restart ] || [ ! -f "$tmp/inject-restart" ]; }
original_hash=$(sha256sum "$CFG/podkop" | awk '{print $1}')
touch "$tmp/inject-restart"
if native_apply; then echo UNEXPECTED_SUCCESS; exit 1; fi
grep -qx previous "$CFG/podkop"
[ ! -e "$NDATA/pending" ]
rm "$tmp/inject-restart"
native_apply
grep -qx candidate "$CFG/podkop"
grep -qx previous "$NDATA/previous-good/podkop"
grep -qx managed "$NDATA/managed/USA"
[ ! -e "$NDATA/pending" ]
# Dry-run never creates native persistent state.
DATA=$tmp/dry; DRY_RUN=1; native_setup; [ ! -e "$DATA" ]
echo NATIVE_STATE_ROLLBACK_AND_DRY_RUN_REGRESSION_PASS
# A native init child may daemonize; never leak subscription/control lock FDs.
(
 . "$repo/scripts/podkop-native-update-lib.sh"
 cat > "$tmp/service-child" <<'CHILD'
#!/bin/sh
[ ! -e /proc/$$/fd/8 ] && [ ! -e /proc/$$/fd/9 ]
CHILD
 chmod 700 "$tmp/service-child"
 NATIVE_SERVICE=$tmp/service-child
 bounded_run(){ shift; "$@"; }
 exec 8>"$tmp/lock8" 9>"$tmp/lock9"
 native_service start
)
# Delayed procd readiness is retried, not confused with permanent failure.
(
 . "$repo/scripts/podkop-native-update-lib.sh"
 sleep(){ :; }
 readiness=0
 native_local_health(){ readiness=$((readiness+1)); [ "$readiness" -ge 3 ]; }
 shadow_health(){ return 0; }
 native_wait_ready
 [ "$readiness" = 3 ]
)
echo NATIVE_INIT_FD_AND_DELAYED_READINESS_PASS
(
 . "$repo/scripts/podkop-native-update-lib.sh"
 printf '%s\n' manual-rwsub identical-rwsub owned-rwsub > "$tmp/old-links"
 printf '%s\n' owned-rwsub > "$tmp/previous-managed"
 printf '%s\n' identical-rwsub fresh-rwsub owned-rwsub > "$tmp/fresh-links"
 native_stage_ownership "$tmp/fresh-links" "$tmp/old-links" "$tmp/previous-managed" "$tmp/new-managed"
 printf '%s\n' fresh-rwsub owned-rwsub > "$tmp/expected-managed"
 cmp "$tmp/new-managed" "$tmp/expected-managed"
 native_stage_ownership "$tmp/fresh-links" "$tmp/old-links" "$tmp/absent-snapshot" "$tmp/new-managed"
 printf '%s\n' fresh-rwsub > "$tmp/expected-managed"
 cmp "$tmp/new-managed" "$tmp/expected-managed"
)
echo NATIVE_IDENTICAL_MANUAL_LINK_NOT_CLAIMED_PASS
