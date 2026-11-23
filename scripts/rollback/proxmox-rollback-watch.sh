#!/bin/bash
set -u
for path in /var/lib/podkop-emergency-202/*/state; do
    [[ -f $path ]] || continue
    id=${path%/state}; id=${id##*/}
    /usr/local/sbin/proxmox-rollback-202 check "$id" || true
done
