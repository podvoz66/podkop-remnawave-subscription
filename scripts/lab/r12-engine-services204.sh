#!/bin/bash
# LAB204 only; temporary guest fixture processes. No host service/bridge changes.
set -Eeuo pipefail
S=/root/r12-engine-baseline204
C=/root/r12-engine-offline
bad(){ echo "STOP: $*" >&2; exit 1; }
[[ $EUID == 0 && $# == 1 ]] || bad 'root/action'
[[ $(ip -o link show | wc -l) == 1 ]] || bad 'root netns NIC'
for pair in r12-lan:ens2:02:52:12:02:04:01 r12-wan:ens4:02:52:12:02:04:02; do
 n=${pair%%:*}; rest=${pair#*:}; dev=${rest%%:*}; mac=${rest#*:}
 ip -n "$n" -o link show dev "$dev" | grep -Fq "link/ether $mac" || bad 'MAC mismatch'
 [[ -z $(ip -n "$n" -4 route show default) && -z $(ip -n "$n" -6 route show default) ]] || bad 'default route'
done
[[ -z $(ip -4 route show default) && -z $(ip -6 route show default) ]] || bad 'root default'
umask 077
route='198.18.0.0/15 via 10.253.202.1 dev ens2 proto static'
check_state(){
 [[ $(cat "$S/boot") == "$(cat /proc/sys/kernel/random/boot_id)" ]] || bad 'boot changed'
 [[ $(stat -Lc %i /run/netns/r12-wan) == "$(cat "$S/wan.inode")" ]] || bad 'WAN netns changed'
 ip -4 route > "$S/root.current"; cmp -s "$S/root.before" "$S/root.current" || bad 'root route changed'
 ip -n r12-wan -4 route > "$S/wan.current"; cmp -s "$S/wan.before" "$S/wan.current" || bad 'WAN route changed'
 ip -n r12-lan -4 route | sed '/^198\.18\.0\.0\/15 via 10\.253\.202\.1 dev ens2 proto static[[:space:]]*$/d' > "$S/lan.current"
 cmp -s "$S/lan.before" "$S/lan.current" || bad 'foreign LAN route'
}
stop_one(){
 name=$1; [[ -f $S/$name.pid ]] || return 0
 pid=$(cat "$S/$name.pid"); [[ $pid =~ ^[0-9]+$ ]] || bad 'PID'
 if [[ -d /proc/$pid ]]; then
  [[ $(stat -Lc %i /proc/"$pid"/ns/net) == "$(cat "$S/wan.inode")" ]] || bad 'PID netns'
  tr '\0' '\n' < /proc/"$pid"/cmdline | grep -Fxq "$C/r12-$name-fixture.py" || bad 'PID command'
  kill -TERM "$pid"
  for i in {1..50}; do [[ ! -d /proc/$pid ]] && break; sleep .1; done
  [[ ! -d /proc/$pid ]] || bad 'own process did not stop'
 fi
 rm -f "$S/$name.pid"
}
start_one(){
 name=$1; [[ ! -e $S/$name.pid ]] || bad 'service marker exists'
 nohup ip netns exec r12-wan timeout 7200 /usr/bin/python3 "$C/r12-$name-fixture.py" "$C" </dev/null > "$S/$name.log" 2>&1 &
 echo $! > "$S/$name.pid"
 for i in {1..50}; do grep -q 'R12_.*READY' "$S/$name.log" 2>/dev/null && return; sleep .1; done
 bad "$name startup failed"
}
case $1 in
prepare)
 [[ ! -e $S ]] || bad 'baseline exists; do not overwrite'
 bash /root/r12-stage6/control.sh verify >/dev/null
 mkdir -m 700 "$S"
 cat /proc/sys/kernel/random/boot_id > "$S/boot"
 stat -Lc %i /run/netns/r12-wan > "$S/wan.inode"
 ip -4 route > "$S/root.before"
 ip -n r12-lan -4 route > "$S/lan.before"
 ip -n r12-wan -4 route > "$S/wan.before"
 # Remove ONLY our earlier bounded package staging fixture, not Stage6.
 if [[ -f /tmp/r12-offline.pid ]]; then
  pid=$(cat /tmp/r12-offline.pid); [[ $pid =~ ^[0-9]+$ ]] || bad 'staging PID'
  if [[ -d /proc/$pid ]]; then
   [[ $(stat -Lc %i /proc/"$pid"/ns/net) == "$(cat "$S/wan.inode")" ]] || bad 'staging netns'
   tr '\0' '\n' < /proc/"$pid"/cmdline | grep -Fxq http.server || bad 'not own staging fixture'
   kill -TERM "$pid"; sleep 1
  fi
  rm -f /tmp/r12-offline.pid
 fi
 [[ ! -e $C/uuid ]] || bad 'credential already exists'
 /usr/bin/python3 -c 'import os,uuid,sys; p=sys.argv[1]; u=str(uuid.uuid4()); open(p+"/uuid","w").write(u); os.chmod(p+"/uuid",0o600); link="vless://"+u+"@10.253.203.1:10443?security=tls&sni=fixture.r12.test#"; open(p+"/subscription.txt","w").write(link+"lab-main\n"+link+"USA\n"); os.chmod(p+"/subscription.txt",0o600)' "$C"
 echo ENGINE_SERVICES_BASELINE_READY
 ;;
apply)
 check_state
 [[ -z $(ip -n r12-lan -4 route show exact 198.18.0.0/15) ]] || bad 'FakeIP route already exists'
 ip -n r12-lan route add 198.18.0.0/15 via 10.253.202.1 dev ens2 proto static
 start_one offline; start_one vless; start_one dns
 echo ENGINE_LAB_SERVICES_READY
 ;;
verify)
 check_state
 [[ $(ip -n r12-lan -4 route show exact 198.18.0.0/15 | sed 's/[[:space:]]*$//') == "$route" ]] || bad 'FakeIP route'
 for name in offline vless dns; do
  [[ -f $S/$name.pid ]] && kill -0 "$(cat "$S/$name.pid")" || bad 'service absent'
 done
 echo ENGINE_LAB_ISOLATION_AND_SERVICES_PASS
 ;;
rollback)
 check_state
 stop_one dns; stop_one vless; stop_one offline
 current=$(ip -n r12-lan -4 route show exact 198.18.0.0/15 | sed 's/[[:space:]]*$//')
 [[ -z $current || $current == "$route" ]] || bad 'foreign FakeIP route'
 [[ -z $current ]] || ip -n r12-lan route del 198.18.0.0/15 via 10.253.202.1 dev ens2 proto static
 bash /root/r12-stage6/control.sh verify >/dev/null
 echo ENGINE_LAB204_ROLLBACK_PASS
 ;;
vpn-stop) check_state; stop_one vless;;
vpn-start) check_state; start_one vless;;
dns-stop) check_state; stop_one dns;;
dns-start) check_state; start_one dns;;
*) bad 'prepare|apply|verify|rollback|vpn-stop|vpn-start|dns-stop|dns-start';;
esac
