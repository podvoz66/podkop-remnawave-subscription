#!/bin/bash
# PROPOSED owner-only bootstrap; no capture/restore/timer/VM action during install.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
umask 077
bad(){ echo "STOP: $*" >&2; exit 1; }
[[ $# == 1 && ( $1 == install || $1 == rollback ) ]] || bad 'install|rollback'
[[ $EUID == 0 && $(hostname -s) == podvoz-beelink ]] || bad 'PVE root required'
BIN=/usr/local/sbin/codexops-r12-recovery
RULE=/etc/sudoers.d/codexops-r12-recovery
S=/var/lib/r12-lab203-recovery
HASH=f6ce60fbfd94f9d9ee27d82beabdb0543379a93bfc4e72d3a04b7d5313da3ea0
if [[ $1 == install ]]; then
 [[ ! -e $BIN && ! -L $BIN && ! -e $RULE && ! -L $RULE && ! -e $S && ! -L $S ]] || bad 'existing paths; no overwrite'
 for c in qm pvesm qemu-img blockdev findmnt fuser flock timeout dd systemd-run visudo; do command -v "$c" >/dev/null || bad "missing $c"; done
 visudo -c >/dev/null
 /usr/local/sbin/codexops-r12-lab inspect 203 >/dev/null
 src=$(cd "$(dirname "$0")" && pwd)/codexops-r12-recovery
 printf '%s  %s\n' "$HASH" "$src" | sha256sum -c - >/dev/null
 bash -n "$src"
 install -d -o root -g root -m 0700 "$S"
 printf 'BIN_ABSENT\nRULE_ABSENT\nNO_VM_ACTION_PERFORMED\n' > "$S/install.before"
 trap 'rm -f -- "$RULE" "$BIN"; echo "STOP: new grant removed; state retained" >&2' ERR
 install -o root -g root -m 0755 "$src" "$BIN"
 printf '%s\n' "$HASH" > "$S/install.wrapper.sha256"
 for a in status capture accept restore arm confirm; do
  printf 'codexops ALL=(root) NOPASSWD: %s %s 203\n' "$BIN" "$a"
 done > "$S/sudoers.candidate"
 visudo -cf "$S/sudoers.candidate" >/dev/null
 install -o root -g root -m 0440 "$S/sudoers.candidate" "$RULE"
 sha256sum "$RULE" | awk '{print $1}' > "$S/install.rule.sha256"
 visudo -c >/dev/null
 trap - ERR
 echo 'INSTALLED_RECOVERY203_ONLY: no disk/VM/timer action performed'
else
 [[ -d $S && ! -L $S && $(stat -c '%u:%a' "$S") == 0:700 ]] || bad 'trusted install state missing'
 [[ ! -e $S/armed ]] || bad 'unconfirmed deployment armed; preserve safety timer'
 for pair in "$BIN:wrapper" "$RULE:rule"; do
  f=${pair%:*}; k=${pair##*:}
  [[ ! -e $f ]] || { [[ ! -L $f && $(stat -c %u "$f") == 0 && $(sha256sum "$f" | awk '{print $1}') == "$(cat "$S/install.$k.sha256")" ]] || bad 'file changed'; }
 done
 systemctl stop r12-lab203-deadline.timer >/dev/null 2>&1 || true
 rm -f -- "$RULE"
 visudo -c >/dev/null
 rm -f -- "$BIN"
 echo 'ROLLED_BACK_ACCESS: images/state retained; disks/VMs untouched'
fi
