#!/usr/bin/env bash
# R12 isolated OpenWrt/Linux lab: verified images then OFFLINE VMs, NO NIC.
# This script must NEVER touch VM201/202 or host network settings.
set -Eeuo pipefail
umask 077

STAGE=/var/lib/vz/r12-lab-images
OW=openwrt-25.12.4-x86-64-generic-ext4-combined.img.gz
DEB=debian-12-genericcloud-amd64-20261117-2665.qcow2
OW_SHA=9d080bcae28d7cdf86dabb4b29c10d36d89e0bd79e20a4799454380bc1619695
DEB_SHA=946b917a37882f16e5b3b0b2cbe5744637d0cd36190b5b53cbb21d14a54557d5b45e9e523021b8f52c1707dbe470489f3515458e0680ded76ee2574b4a8daf1b
OW_URL=https://downloads.openwrt.org/releases/25.12.4/targets/x86/64/$OW
DEB_URL=https://cloud.debian.org/images/cloud/bookworm/20261117-2665/$DEB

stop() { printf 'STOP: %s\n' "$*" >&2; exit 1; }
check_root() { (( EUID == 0 )) || stop 'run as root on podvoz-beelink'; }
check_host() {
  [[ "$(hostname -s)" == podvoz-beelink ]] || stop 'unexpected Proxmox host'
  command -v qm >/dev/null && command -v pvesh >/dev/null && command -v pvesm >/dev/null || stop 'Proxmox tools missing'
}
check_file() {
  local method=$1 sum=$2 file=$3
  [[ -s "$file" ]] || stop "missing image: $file"
  printf '%s  %s\n' "$sum" "$file" | "$method" -c - >/dev/null || stop "checksum mismatch: $file"
}
check_qemu_image() {
  local file=$1 fmt=$2
  qemu-img info --output=json "$file" | python3 -c '
import json,sys
v=json.load(sys.stdin)
expected=sys.argv[1]
if v.get("format") != expected or v.get("backing-filename") or v.get("full-backing-filename") or v.get("backing-filename-format"):
    sys.exit("unexpected disk format or backing file")
print("IMAGE_OK format=%s virtual_size=%d" % (expected, v["virtual-size"]))
' "$fmt" || stop "image validation: $file"
}
check_images() {
  check_file sha256sum "$OW_SHA" "$STAGE/$OW"
  check_file sha512sum "$DEB_SHA" "$STAGE/$DEB"
  [[ -s "$STAGE/openwrt.img" ]] || stop 'OpenWrt decompressed raw image missing'
  check_qemu_image "$STAGE/openwrt.img" raw
  check_qemu_image "$STAGE/$DEB" qcow2
}
download_checked() {
  local url=$1 file=$2 method=$3 sum=$4
  if [[ -s "$STAGE/$file" ]]; then
    check_file "$method" "$sum" "$STAGE/$file"
    printf 'REUSED_VERIFIED %s\n' "$file"
    return
  fi
  curl --fail --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 12 --max-time 600 --retry 2 --output "$STAGE/$file.part" "$url" \
    || stop "download failed: $file"
  check_file "$method" "$sum" "$STAGE/$file.part"
  mv -- "$STAGE/$file.part" "$STAGE/$file"
}
prepare() {
  check_root; check_host
  local free_kib
  free_kib=$(df -Pk /var/lib/vz | awk 'NR==2 {print $4}')
  [[ "$free_kib" =~ ^[0-9]+$ ]] && ((free_kib >= 2 * 1024 * 1024)) || stop 'less than 2 GiB free on staging filesystem'
  mkdir -p -m 0700 "$STAGE"; chmod 0700 "$STAGE"
  download_checked "$OW_URL" "$OW" sha256sum "$OW_SHA"
  download_checked "$DEB_URL" "$DEB" sha512sum "$DEB_SHA"
  gzip -t "$STAGE/$OW" || stop 'OpenWrt gzip damaged'
  if [[ ! -s "$STAGE/openwrt.img" ]]; then
    gzip -dc "$STAGE/$OW" > "$STAGE/openwrt.img.part" || stop 'OpenWrt decompression failed'
    mv -- "$STAGE/openwrt.img.part" "$STAGE/openwrt.img"
  fi
  check_images
  printf '\nPREPARE_OK: verified official images; NO VMs changed.\n'
}
vmid_free() {
  local id=$1 returned
  [[ ! -e "/etc/pve/qemu-server/$id.conf" ]] || stop "VMID $id exists"
  returned=$(pvesh get /cluster/nextid --vmid "$id" --output-format json | tr -d '[:space:]"') || stop "cannot query VMID $id"
  [[ "$returned" == "$id" ]] || stop "VMID $id not free: $returned"
}
check_vm_offline() {
  local id=$1 cfg cmd
  [[ "$(qm status "$id")" == 'status: stopped' ]] || stop "VM$id is not stopped"
  cfg=$(qm config "$id") || stop "cannot read VM$id config"
  grep -qx 'onboot: 0' <<< "$cfg" || stop "VM$id must be onboot=0"
  if grep -Eq '^(net[0-9]+|args|hostpci[0-9]+|usb[0-9]+):' <<< "$cfg"; then
    stop "VM$id unexpected NIC/custom args/passthrough"
  fi
  grep -q '^scsi0: extra-storage:' <<< "$cfg" || stop "VM$id disk not on extra-storage"
  grep -qx 'boot: order=scsi0' <<< "$cfg" || stop "VM$id wrong boot disk"
  cmd=$(qm showcmd "$id" --pretty) || stop "qm showcmd VM$id failed"
  if grep -Eq -- '-netdev|-nic|hostfwd|tap|vmbr0|vmbr1|passthrough|vfio' <<< "$cmd"; then
    stop "VM$id generated network/passthrough options"
  fi
  printf 'VM%d_OFFLINE_OK\n' "$id"
}
create_offline() {
  check_root; check_host
  check_images
  vmid_free 203; vmid_free 204
  pvesm status | awk '$1 == "extra-storage" && $3 == "active" {ok=1} END {exit !ok}' || stop 'extra-storage unavailable'
  printf 'PRECHECK_OK: IDs203/204 free, images verified, extra-storage active.\n'
  # No --netN, no --args, no --start. Never delete anything on partial failure.
  qm create 203 --name LAB203-OpenWrt --memory 1024 --cores 1 --cpulimit 0.5 --onboot 0 --scsihw virtio-scsi-pci --serial0 socket --vga serial0
  qm create 204 --name LAB204-Fixture --memory 1024 --cores 1 --cpulimit 0.5 --onboot 0 --scsihw virtio-scsi-pci --serial0 socket --vga serial0
  qm disk import 203 "$STAGE/openwrt.img" extra-storage --format raw
  qm disk import 204 "$STAGE/$DEB" extra-storage --format raw
  local id disk cfg
  for id in 203 204; do
    cfg=$(qm config "$id") || stop "VM$id config unavailable"
    [[ "$(grep -c '^unused[0-9]*:' <<< "$cfg")" == 1 ]] || stop "VM$id expected exactly one imported disk"
    disk=$(awk '$1 == "unused0:" {print $2}' <<< "$cfg")
    [[ "$disk" == extra-storage:* ]] || stop "VM$id unexpected volume ID"
    qm set "$id" --scsi0 "$disk" --boot 'order=scsi0'
    check_vm_offline "$id"
  done
  printf '\nCREATE_OFFLINE_OK: LAB203/204 stopped, onboot=0, no NIC, no custom args.\n'
  printf 'NEXT: separate validation of Unix stream network and guest console BEFORE first boot.\n'
}
case "${1:-}" in
  prepare) prepare ;;
  create-offline) create_offline ;;
  *) printf 'Usage: %s prepare|create-offline\n' "$0" >&2; exit 2 ;;
esac
