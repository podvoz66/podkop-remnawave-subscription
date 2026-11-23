#!/bin/bash
# Debian LAB204 only. No PVE commands, packages, DNS or persistent configuration.
set -Eeuo pipefail
export LC_ALL=C
PATH=/usr/sbin:/usr/bin:/sbin:/bin
STATE=/run/r12-stage4
MODE=${1:-check}
NAMES=(r12-lan r12-wan)
DEVS=(ens2 ens4)
MACS=(02:52:12:02:04:01 02:52:12:02:04:02)
ADDRS=(10.253.202.2/24 10.253.203.1/24)
fail() { echo "STOP: $*" >&2; exit 1; }
[[ $MODE =~ ^(check|apply|verify|rollback)$ ]] || fail 'use check|apply|verify|rollback'
[[ $EUID == 0 ]] || fail 'root inside LAB204 required'
for c in ip awk grep stat readlink flock; do command -v "$c" >/dev/null || fail "missing $c"; done
[[ $(readlink /proc/self/ns/net) == "$(readlink /proc/1/ns/net)" ]] || fail 'not initial network namespace'
[[ $(awk -F= '$1=="ID" {gsub(/"/,"",$2); print $2}' /etc/os-release) == debian ]] || fail 'Debian required'
[[ $(awk -F= '$1=="VERSION_ID" {gsub(/"/,"",$2); print $2}' /etc/os-release) == 12 ]] || fail 'Debian12 required'
# Never source a state file. Root-only /run directory, same boot and netns required.
owned() {
  [[ -d $STATE && ! -L $STATE && $(stat -c '%u:%a' "$STATE") == 0:700 ]] || fail 'no trusted state directory'
  [[ $(cat "$STATE/boot") == "$(cat /proc/sys/kernel/random/boot_id)" ]] || fail 'state boot mismatch'
  [[ $(cat "$STATE/rootns") == "$(readlink /proc/1/ns/net)" ]] || fail 'state netns mismatch'
}
exists() { ip netns list | awk '{print $1}' | grep -Fxq "$1"; }
in_ns() { ip -n "$1" link show dev "$2" >/dev/null 2>&1; }
mac() { ip "$@" | awk '{for(i=1;i<=NF;i++) if($i=="link/ether") print $(i+1)}'; }
no_master_up_addr() {
  local d=$1
  [[ $(ip -o link show dev "$d") != *' master '* ]] || fail "$d enslaved"
  [[ $(ip -o link show dev "$d") != *'<UP,'* && $(ip -o link show dev "$d") != *',UP'* ]] || fail "$d already UP"
  [[ -z $(ip -o addr show dev "$d") ]] || fail "$d has addresses"
  [[ -z $(ip -4 route show table all dev "$d") && -z $(ip -6 route show table all dev "$d") ]] || fail "$d has routes"
}
fresh() {
  [[ ! -e $STATE && ! -L $STATE ]] || fail 'state exists; use verify or rollback'
  for n in "${NAMES[@]}"; do ! exists "$n" || fail "$n already exists"; done
  [[ $(ip -o link show | wc -l) -eq 3 ]] || fail 'expected only lo,ens2,ens4'
  [[ -z $(ip -4 route show default) && -z $(ip -6 route show default) ]] || fail 'unexpected root default route'
  local i
  for i in 0 1; do
    [[ $(mac -o link show dev "${DEVS[i]}") == "${MACS[i]}" ]] || fail "wrong LAB MAC ${DEVS[i]}"
    no_master_up_addr "${DEVS[i]}"
    ip -d -o link show dev "${DEVS[i]}" | grep -q 'addrgenmode ' || fail 'cannot capture IPv6 addrgenmode'
  done
}
ns_owned() {
  local n=$1
  exists "$n" || fail "$n missing"
  [[ -f $STATE/$n.inode && $(stat -Lc %i "/run/netns/$n") == "$(cat "$STATE/$n.inode")" ]] || fail "$n identity mismatch"
}
verify() {
  owned
  [[ $(ip -o link show | wc -l) -eq 1 ]] || fail 'unexpected root interface'
  local i n d a
  for i in 0 1; do
    n=${NAMES[i]}; d=${DEVS[i]}; a=${ADDRS[i]}; ns_owned "$n"
    [[ $(ip -n "$n" -o link show | wc -l) -eq 2 ]] || fail "$n unexpected interface"
    [[ $(mac -n "$n" -o link show dev "$d") == "${MACS[i]}" ]] || fail "$n MAC mismatch"
    [[ $(ip -n "$n" -o -4 addr show dev "$d" | awk '{print $4}') == "$a" ]] || fail "$n wrong address"
    [[ -z $(ip -n "$n" -o -6 addr show dev "$d") ]] || fail "$n unexpected IPv6"
    [[ -z $(ip -n "$n" -4 route show default) && -z $(ip -n "$n" -6 route show default) ]] || fail "$n default route forbidden"
    [[ $(ip -n "$n" -4 route show table main | wc -l) -eq 1 ]] || fail "$n unexpected route"
    ip -n "$n" -o link show dev "$d" | grep -qE '<([^>]*,)?UP[,>]' || fail "$n interface DOWN"
    ip -n "$n" -o link show dev lo | grep -qE '<([^>]*,)?UP[,>]' || fail "$n loopback DOWN"
  done
  echo 'PASS: LAB204 namespaces, MAC/IP, no default routes; no transit test performed'
}
if [[ $MODE == check ]]; then
  if [[ -e $STATE ]]; then verify; else fresh; echo 'PREFLIGHT_PASS: no conflicts; nothing changed'; fi
  exit
fi
if [[ $MODE == verify ]]; then verify; exit; fi
# Serialize only mutations. Do not use PID files or kill other processes.
[[ ! -L /run/r12-stage4.lock ]] || fail 'lock symlink'
exec 9>/run/r12-stage4.lock
flock -n 9 || fail 'another stage4 mutation active'
if [[ $MODE == apply ]]; then
  if [[ -e $STATE ]]; then verify; exit; fi
  fresh
  umask 077
  mkdir -m 700 "$STATE"
  cat /proc/sys/kernel/random/boot_id > "$STATE/boot"
  readlink /proc/1/ns/net > "$STATE/rootns"
  for i in 0 1; do
    n=${NAMES[i]}; d=${DEVS[i]}
    ip -d -o link show dev "$d" | awk '{for(i=1;i<=NF;i++) if($i=="addrgenmode") print $(i+1)}' > "$STATE/$d.mode"
  done
  trap 'echo "STOP: partial apply; state retained. Run rollback; no automatic retries" >&2' ERR
  for i in 0 1; do
    n=${NAMES[i]}; d=${DEVS[i]}
    ip netns add "$n"
    stat -Lc %i "/run/netns/$n" > "$STATE/$n.inode"
    ip link set dev "$d" netns "$n"
    ip -n "$n" link set dev "$d" addrgenmode none
    ip -n "$n" addr add "${ADDRS[i]}" dev "$d"
    ip -n "$n" link set lo up
    ip -n "$n" link set "$d" up
  done
  verify
else
  # Validate BOTH namespaces before removing anything. Unknown modifications -> STOP.
  [[ -e $STATE ]] || { echo 'ROLLBACK_NO_STATE: nothing changed'; exit; }
  owned
  for i in 0 1; do
    n=${NAMES[i]}; d=${DEVS[i]}
    [[ -f $STATE/$d.mode ]] || fail 'missing original mode'
    [[ $(cat "$STATE/$d.mode") =~ ^(eui64|none|stable_secret|random)$ ]] || fail 'invalid original mode'
    if exists "$n"; then
      ns_owned "$n"
      [[ -z $(ip netns pids "$n") ]] || fail "$n has processes"
      [[ $(ip -n "$n" -o link show | wc -l) -le 2 ]] || fail "$n foreign interfaces"
      if in_ns "$n" "$d"; then
        [[ $(mac -n "$n" -o link show dev "$d") == "${MACS[i]}" ]] || fail 'MAC mismatch'
        [[ -z $(ip -n "$n" -o -6 addr show dev "$d") ]] || fail 'foreign IPv6 addresses'
        [[ -z $(ip -n "$n" -o -4 addr show dev "$d" | awk -v a="${ADDRS[i]}" '$4!=a') ]] || fail 'foreign IPv4 addresses'
        # Ignore loopback-local IPv6 routes (::1); reject IPv6 on the LAB NIC and any default route.
        [[ -z $(ip -n "$n" -4 route show default) && -z $(ip -n "$n" -6 route show default) ]] || fail 'foreign default route'
        [[ -z $(ip -n "$n" -6 route show table main dev "$d") ]] || fail 'foreign IPv6 main-table route on LAB NIC'
        prefix=10.253.202.0/24; [[ $i == 0 ]] || prefix=10.253.203.0/24
        [[ -z $(ip -n "$n" -4 route show table main | awk -v p="$prefix" -v d="$d" '$1!=p || $2!="dev" || $3!=d || $4!="proto" || $5!="kernel"') ]] || fail 'foreign namespace route'
      else
        ip link show dev "$d" >/dev/null || fail 'interface lost'
      fi
    fi
    if ip link show dev "$d" >/dev/null 2>&1; then
      [[ $(mac -o link show dev "$d") == "${MACS[i]}" ]] || fail 'root MAC mismatch'
      no_master_up_addr "$d"
    fi
  done
  for i in 0 1; do
    n=${NAMES[i]}; d=${DEVS[i]}
    if exists "$n"; then
      if in_ns "$n" "$d"; then
        ip -n "$n" link set "$d" down
        if ip -n "$n" -o -4 addr show dev "$d" | awk '{print $4}' | grep -Fxq "${ADDRS[i]}"; then
          ip -n "$n" addr del "${ADDRS[i]}" dev "$d"
        fi
        ip -n "$n" link set "$d" netns 1
      fi
      ip netns del "$n"
    fi
    ip link set "$d" addrgenmode "$(cat "$STATE/$d.mode")"
  done
  # Retain audit state outside active marker; subsequent apply may begin fresh.
  mv "$STATE" "${STATE}.rolled-back.$(date +%s).$$"
  fresh
  echo 'ROLLBACK_PASS: interfaces restored DOWN/no addresses to initial netns'
fi
