#!/bin/bash
# Inside Debian LAB204 only. Baseline must be prepared independently before first apply.
set -Eeuo pipefail
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin
S=/root/r12-stage6
bad() { echo "STOP: $*" >&2; exit 1; }
[[ $EUID == 0 && $# == 1 ]] || bad 'root and action required'
[[ -d $S && ! -L $S && $(stat -c '%u:%a' "$S") == 0:700 ]] || bad 'state ownership'
[[ $(cat "$S/boot") == "$(cat /proc/sys/kernel/random/boot_id)" ]] || bad 'boot changed'
[[ $(readlink /proc/self/ns/net) == "$(readlink /proc/1/ns/net)" ]] || bad 'not initial netns'
cd "$S"
sha256sum -c assets.sha256 >/dev/null
for pair in r12-lan:ens2:02:52:12:02:04:01 r12-wan:ens4:02:52:12:02:04:02; do
  n=${pair%%:*}; rest=${pair#*:}; d=${rest%%:*}; mac=${rest#*:}
  [[ $(stat -Lc %i /run/netns/"$n") == "$(cat "$n.inode")" ]] || bad 'namespace changed'
  ip -n "$n" -o link show dev "$d" | grep -Fq "link/ether $mac" || bad 'wrong LAB MAC'
  [[ -z $(ip -n "$n" -4 route show default) && -z $(ip -n "$n" -6 route show default) ]] || bad 'default route found'
done
[[ $(ip -o link show | wc -l) == 1 ]] || bad 'root netns has NIC'
[[ -z $(ip -4 route show default) && -z $(ip -6 route show default) ]] || bad 'root default found'
exec 9>/run/r12-stage6.lock
flock -n 9 || bad 'concurrent Stage6 action'
# Children must not inherit this lock: fixture start closes fd9 explicitly.
route_line='10.253.203.1 via 10.253.202.1 dev ens2 proto static'
route_current=$(ip -n r12-lan -4 route show table main exact 10.253.203.1/32 | sed 's/[[:space:]]*$//')
[[ -z $route_current || $route_current == "$route_line" ]] || bad 'unexpected fixture route'
ip -n r12-lan -4 route show | awk -v skip="$route_line" '{original=$0; $1=$1; if($0!=skip) print original}' > routes.lan.current
cmp -s routes.lan.before routes.lan.current || bad 'foreign LAN route change'
ip -n r12-wan -4 route show > routes.wan.current
cmp -s routes.wan.before routes.wan.current || bad 'foreign WAN route change'
ip -4 route show > routes.root.current
cmp -s routes.root.before routes.root.current || bad 'root routes changed'
stop_fixture() {
  [[ -f $S/fixture.pid ]] || return 0
  pid=$(cat "$S/fixture.pid"); [[ $pid =~ ^[0-9]+$ ]] || bad 'invalid fixture PID'
  if [[ -d /proc/$pid ]]; then
    [[ $(stat -Lc %i /proc/"$pid"/ns/net) == "$(cat "$S/r12-wan.inode")" ]] || bad 'PID namespace mismatch'
    tr '\0' '\n' < /proc/"$pid"/cmdline | grep -Fxq "$S/fixture.py" || bad 'PID command mismatch'
    kill -TERM "$pid"
    for i in {1..30}; do [[ -d /proc/$pid ]] || break; sleep 0.1; done
    [[ ! -d /proc/$pid ]] || bad 'fixture failed to exit'
  fi
  rm -f "$S/fixture.pid"
}
start_fixture() {
  [[ ! -e $S/fixture.pid ]] || bad 'fixture marker exists'
  # Any unexpected listener is a conflict, not an excuse to kill another process.
  [[ -z $(ip netns exec r12-wan ss -H -ltnup) ]] || bad 'WAN listener conflict'
  : > "$S/fixture.out"
  (exec 9>&-; exec nohup ip netns exec r12-wan /usr/bin/python3 "$S/fixture.py" serve "$S") </dev/null >"$S/fixture.out" 2>&1 &
  echo $! > "$S/fixture.pid"
  for i in {1..40}; do grep -q '^R12_FIXTURE_READY$' "$S/fixture.out" && return; sleep 0.1; done
  bad 'fixture start failed; inspect fixture.out, do not blindly retry'
}
case "$1" in
apply)
  [[ -z $route_current ]] || bad 'already applied; use verify'
  # Negative baseline proves target is unreachable before adding the only route.
  if ip netns exec r12-lan curl --noproxy '*' --connect-timeout 1 --max-time 2 -sS http://10.253.203.1:8080/r12/before-route >/dev/null 2>&1; then bad 'unexpected bypass'; fi
  ip -n r12-lan route add 10.253.203.1/32 via 10.253.202.1 dev ens2 proto static
  start_fixture
  echo STAGE6_APPLIED
  ;;
stop) stop_fixture; echo FIXTURE_STOPPED;;
start) [[ $route_current == "$route_line" ]] || bad 'route missing'; start_fixture; echo FIXTURE_STARTED;;
rollback)
  stop_fixture
  [[ -z $route_current ]] || ip -n r12-lan route del 10.253.203.1/32 via 10.253.202.1 dev ens2 proto static
  [[ -z $(ip netns exec r12-wan ss -H -ltnup) ]] || bad 'listeners remain'
  ip -n r12-lan -4 route show > routes.lan.current
  cmp -s routes.lan.before routes.lan.current || bad 'LAN rollback differs'
  echo STAGE6_ROLLBACK_PASS
  ;;
verify)
  [[ $route_current == "$route_line" && -f $S/fixture.pid ]] || bad 'not active'
  ip -n r12-lan route get 10.253.203.1
  ip netns exec r12-wan ss -H -ltnup
  echo STAGE6_CONFIG_PASS
  ;;
*) bad 'apply|verify|stop|start|rollback';;
esac
