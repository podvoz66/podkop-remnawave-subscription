#!/bin/bash
# One owner-approved root bootstrap. No VM actions, no packages, no network changes.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
umask 077
bad() { echo "STOP: $*" >&2; exit 1; }
[[ $# == 1 && ( $1 == install || $1 == rollback ) ]] || bad 'use install|rollback'
[[ $EUID == 0 && $(hostname -s) == podvoz-beelink ]] || bad 'Proxmox root required'
BIN=/usr/local/sbin/codexops-r12-lab
RULE=/etc/sudoers.d/codexops-r12-lab
STATE=/var/lib/codexops-r12-lab-access
HASH=3fb991f06371f8d6a98ca9e959f87cb061e6ced494a0d38b48da5e7ebb7bc338
# This bootstrap only owns new files. Refuse overwrite of any existing deployment.
if [[ $1 == install ]]; then
  for f in "$BIN" "$RULE" "$STATE"; do [[ ! -e $f && ! -L $f ]] || bad "already exists: $f"; done
  visudo -c >/dev/null
  id codexops >/dev/null
  for c in qm socat timeout flock ss visudo sha256sum; do command -v "$c" >/dev/null || bad "missing $c"; done
  src=$(cd -- "$(dirname -- "$0")" && pwd)/codexops-r12-lab
  printf '%s  %s\n' "$HASH" "$src" | sha256sum -c - >/dev/null || bad 'wrapper hash mismatch'
  bash -n "$src"
  install -d -o root -g root -m 0700 "$STATE"
  printf 'BIN_ABSENT\nRULE_ABSENT\n' > "$STATE/before"
  trap 'rm -f -- "$RULE" "$BIN"; echo "STOP: bootstrap failed; new grant/wrapper removed, state retained" >&2' ERR
  install -o root -g root -m 0755 "$src" "$BIN"
  printf '%s\n' "$HASH" > "$STATE/wrapper.sha256"
  {
    echo '# R12: exact LAB capabilities only; no SETENV, no host shell.'
    for a in inspect serial start stop; do
      for id in 203 204; do printf 'codexops ALL=(root) NOPASSWD: %s %s %s\n' "$BIN" "$a" "$id"; done
    done
  } > "$STATE/sudoers.candidate"
  visudo -cf "$STATE/sudoers.candidate" >/dev/null
  install -o root -g root -m 0440 "$STATE/sudoers.candidate" "$RULE"
  sha256sum "$RULE" | awk '{print $1}' > "$STATE/rule.sha256"
  visudo -c >/dev/null
  trap - ERR
  echo 'INSTALLED: inspect/serial/start/stop only203/204; no VM action performed'
else
  [[ -d $STATE && ! -L $STATE && $(stat -c '%u:%a' "$STATE") == 0:700 ]] || bad 'no trusted install state'
  for pair in "$BIN:wrapper" "$RULE:rule"; do
    file=${pair%:*}; key=${pair##*:}
    if [[ -e $file ]]; then
      [[ ! -L $file && $(stat -c %u "$file") == 0 ]] || bad 'unexpected file ownership'
      [[ $(sha256sum "$file" | awk '{print $1}') == "$(cat "$STATE/$key.sha256")" ]] || bad "modified $file; do not remove blindly"
    fi
  done
  # Revoke access first. Keep source/manifest for audit and manual future review.
  rm -f -- "$RULE"
  visudo -c >/dev/null
  rm -f -- "$BIN"
  echo 'ROLLED_BACK: sudo grant and wrapper removed; VM/disks/network unchanged'
fi
