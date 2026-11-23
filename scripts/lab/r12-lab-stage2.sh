#!/usr/bin/env bash
# R12 LAB Stage 2: attach Unix stream virtual cables ONLY to powered-off 203/204.
# No qm start, no host network changes, no VM201/202 actions.
set -Eeuo pipefail
umask 077
bad() { printf 'STOP: %s\n' "$*" >&2; exit 1; }
[[ $EUID == 0 && $(hostname -s) == podvoz-beelink ]] || bad 'expected root on podvoz-beelink'

SOCK_DIR=/run/r12-lab
LAN="$SOCK_DIR/lan.sock"
WAN="$SOCK_DIR/wan.sock"
args204="-netdev stream,id=lablan,server=on,addr.type=unix,addr.path=$LAN -device virtio-net-pci,netdev=lablan,mac=02:52:12:02:04:01 -netdev stream,id=labwan,server=on,addr.type=unix,addr.path=$WAN -device virtio-net-pci,netdev=labwan,mac=02:52:12:02:04:02"
args203="-netdev stream,id=lablan,server=off,addr.type=unix,addr.path=$LAN,reconnect-ms=5000 -device virtio-net-pci,netdev=lablan,mac=02:52:12:02:03:01 -netdev stream,id=labwan,server=off,addr.type=unix,addr.path=$WAN,reconnect-ms=5000 -device virtio-net-pci,netdev=labwan,mac=02:52:12:02:03:02"

precheck() {
  local id cfg
  for id in 203 204; do
    [[ $(qm status "$id") == 'status: stopped' ]] || bad "VM$id must be stopped"
    cfg=$(qm config "$id") || bad "VM$id config unavailable"
    grep -qx 'onboot: 0' <<< "$cfg" || bad "VM$id onboot must be 0"
    grep -q '^scsi0: extra-storage:' <<< "$cfg" || bad "VM$id disk must be extra-storage"
    grep -qx 'boot: order=scsi0' <<< "$cfg" || bad "VM$id wrong boot"
    grep -qx 'serial0: socket' <<< "$cfg" || bad "VM$id serial console missing"
    if grep -Eq '^(net[0-9]+|hostpci[0-9]+|usb[0-9]+):' <<< "$cfg"; then
      bad "VM$id has unexpected network or passthrough"
    fi
  done
}
verify() {
  precheck
  local id cfg cmd expected macs num
  for id in 203 204; do
    cfg=$(qm config "$id") || bad "cannot read VM$id"
    if [[ $id == 203 ]]; then expected=$args203; macs='02:52:12:02:03:'; else expected=$args204; macs='02:52:12:02:04:'; fi
    grep -Fxq "args: $expected" <<< "$cfg" || bad "VM$id custom args not exactly pinned"
    cmd=$(qm showcmd "$id" --pretty) || bad "qm showcmd VM$id failed"
    num=$(grep -Foc -- '-netdev stream' <<< "$cmd" || true)
    [[ $num == 2 ]] || bad "VM$id expected exactly two stream backends, got $num"
    num=$(grep -Foc -- '-device virtio-net-pci' <<< "$cmd" || true)
    [[ $num == 2 ]] || bad "VM$id expected two virtio devices, got $num"
    grep -Fq -- "addr.path=$LAN" <<< "$cmd" || bad "VM$id no lab LAN path"
    grep -Fq -- "addr.path=$WAN" <<< "$cmd" || bad "VM$id no lab WAN path"
    grep -Fq -- "mac=$macs" <<< "$cmd" || bad "VM$id MACs absent"
    if grep -Eq -- 'vmbr0|vmbr1|tap[0-9]|-netdev[[:space:]]+(user|tap|bridge|passt)|-nic[[:space:]]+(user|tap)|hostfwd|vfio|host-tunnel' <<< "$cmd"; then
      bad "VM$id appears to have a host or production network"
    fi
    printf 'VM%d_STREAM_ARGS_OK (stopped, no PVE NIC)\n' "$id"
  done
}
configure() {
  precheck
  local id cfg
  for id in 203 204; do
    cfg=$(qm config "$id")
    grep -q '^args:' <<< "$cfg" && bad "VM$id already has custom args; refusing overwrite"
  done
  [[ ! -e "$LAN" && ! -e "$WAN" ]] || bad 'socket paths already exist'
  install -d -o root -g root -m 0700 "$SOCK_DIR" || bad 'cannot create private socket directory'
  qm set 204 --args "$args204"
  qm set 203 --args "$args203"
  verify
  printf 'STAGE2_CONFIGURED: both VMs still stopped. DO NOT START before guest console/fixture preparation.\n'
}
case "${1:-}" in
 configure) configure;;
 verify) verify;;
 *) printf 'Usage: %s configure|verify\n' "$0" >&2; exit 2;;
esac
