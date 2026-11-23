#!/bin/bash
# VM202 only. Runs on Proxmox without DNS, Codespaces, VPN or the new guard.
set -euo pipefail
umask 077
ROOT=${PROXMOX_ROLLBACK_ROOT:-/var/lib/podkop-emergency-202}
CONF=${PROXMOX_ROLLBACK_CONFIG:-/etc/podkop-emergency-202/ssh.conf}
ID=${2:-}
[[ $ID =~ ^[a-zA-Z0-9_-]+$ ]] || { echo 'Invalid rollback ID' >&2; exit 64; }
mkdir -p "$ROOT"
chmod 700 "$ROOT"
exec 9>"$ROOT/host.lock"
flock -n 9 || exit 75
D="$ROOT/$ID"
G=/etc/podkop-emergency
# ssh.conf is an OpenSSH client config, not executable shell. The target and
# credentials must be provisioned and tested separately; no new key is generated.
remote() {
    timeout -k 3 40 ssh -F "$CONF" -o BatchMode=yes -o StrictHostKeyChecking=yes \
        -o UpdateHostKeys=no -o ConnectTimeout=5 -o ConnectionAttempts=1 \
        -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o ForwardAgent=no \
        -o ClearAllForwardings=yes -T openwrt-rollback-202 "$@"
}
now() { cut -d . -f 1 /proc/uptime; }
boot() { cat /proc/sys/kernel/random/boot_id; }
state() { printf '%s\n' "$1" > "$D/state.new"; mv "$D/state.new" "$D/state"; }
verify() {
    (cd "$D"; sha256sum -c pinned.sha256 >/dev/null 2>&1)
}
case ${1:-} in
 stage)
    for other in "$ROOT"/*/state; do
        [[ ! -f $other || $(cat "$other") != ARMED ]] || exit 75
    done
    [[ ! -e $D ]] || exit 73
    mkdir -m 700 "$D"
    # Remote files are produced only by a separately approved guest capture.
    remote "cat $G/$ID/bundle.tar" > "$D/bundle.tar"
    remote "cat $G/$ID/bundle.sha256" > "$D/bundle.sha256"
    [[ $(wc -l < "$D/bundle.sha256") -eq 1 ]]
    read -r expected filename < "$D/bundle.sha256"
    [[ $expected =~ ^[0-9a-f]{64}$ && $filename == bundle.tar ]]
    [[ $expected == "$(sha256sum "$D/bundle.tar" | awk '{print $1}')" ]]
    cp /usr/local/libexec/openwrt-emergency-rollback "$D/restore.sh"
    (cd "$D"; sha256sum bundle.tar restore.sh > pinned.sha256)
    state STAGED ;;
 arm-canary)
    for other in "$ROOT"/*/state; do
        [[ ! -f $other || $(cat "$other") != ARMED ]] || exit 75
    done
    [[ ! -e $D ]] || exit 73
    seconds=${3:-}; [[ $seconds =~ ^[0-9]+$ && $seconds -ge 60 && $seconds -le 3600 ]]
    mkdir -m 700 "$D"; : > "$D/canary"
    boot > "$D/boot"; echo "$(($(now)+seconds))" > "$D/deadline"
    echo 0 > "$D/attempts"; state ARMED; sync ;;
 arm)
    systemctl is-active --quiet proxmox-rollback.timer
    verify
    [[ $(cat "$D/state") == STAGED && -f $D/accepted ]]
    seconds=${3:-}; [[ $seconds =~ ^[0-9]+$ && $seconds -ge 60 && $seconds -le 3600 ]]
    for other in "$ROOT"/*/state; do
        [[ ! -f $other || $(cat "$other") != ARMED ]] || exit 75
    done
    # ARM THE HOST FIRST. Guest arm failure does not silently disarm the host.
    boot > "$D/boot"; echo "$(($(now)+seconds))" > "$D/deadline"
    echo 0 > "$D/attempts"; state ARMED; sync
    remote "/usr/sbin/openwrt-emergency-rollback arm $ID $seconds"
    remote "cat $G/$ID/token" > "$D/token"
    # Until both ARMED statuses and timers are verified, deployment is forbidden.
    ;;
 accept)
    verify
    [[ ${3:-} == "$(sha256sum "$D/bundle.tar" | awk '{print $1}')" ]]
    remote "/usr/sbin/openwrt-emergency-rollback accept $ID $3"
    : > "$D/accepted" ;;
 confirm)
    [[ $(cat "$D/state") == ARMED ]]
    [[ $(cat "$D/boot") == "$(boot)" && $(now) -lt $(cat "$D/deadline") ]]
    [[ ${3:-} == "$(cat "$D/token")" ]]
    # Explicit operator acceptance only; no automatic success on PID/ping.
    remote "/usr/sbin/openwrt-emergency-rollback confirm $ID $3"
    [[ $(cat "$D/boot") == "$(boot)" && $(now) -lt $(cat "$D/deadline") ]]
    state CONFIRMED; sync ;;
 check|restore)
    [[ $(cat "$D/state") == ARMED ]] || exit 0
    if [[ $1 == check && $(cat "$D/boot") == "$(boot)" && $(now) -lt $(cat "$D/deadline") ]]; then exit 0; fi
    if [[ -f $D/canary ]]; then state CANARY_FIRED; exit 0; fi
    verify
    attempts=$(cat "$D/attempts")
    if ((attempts >= 3)); then state BLOCKED; echo 'BLOCKER: host retry limit reached' >&2; exit 1; fi
    echo "$((attempts+1))" > "$D/attempts"
    boot > "$D/boot"; echo "$(($(now)+60))" > "$D/deadline"
    # Push a trusted standalone engine AND bundle: do not rely on the guest's
    # guard, installed recovery script or backup copy surviving the failed rollout.
    if remote "umask 077; mkdir -p $G; cat > $G/host-restore-$ID.sh" < "$D/restore.sh" &&
       remote "/bin/sh $G/host-restore-$ID.sh import $ID $(sha256sum "$D/bundle.tar" | awk '{print $1}')" < "$D/bundle.tar" &&
       remote "/bin/sh $G/host-restore-$ID.sh restore $ID"; then
        result=$(remote "/bin/sh $G/host-restore-$ID.sh status $ID")
        case "$result" in RESTORED_UNVERIFIED|DIRECT_UNVERIFIED) state "$result";; *) exit 1;; esac
    else
        echo 'BLOCKER: local SSH transport or restore unavailable; guest timer is separate' >&2
        exit 1
    fi ;;
 status) cat "$D/state" ;;
 *) echo 'stage|accept|arm|confirm|check|restore|status ID' >&2; exit 64 ;;
esac
