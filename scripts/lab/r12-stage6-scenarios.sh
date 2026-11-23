set -eu
S=/root/r12-stage6
# Transfer the tracked r12-stage6-probe.sh to $S/probe.sh before this script.
sh -n "$S/probe.sh"
echo BEGIN_NO_BYPASS
bash "$S/control.sh" verify >/dev/null
ip -n r12-lan route del 10.253.203.1/32 via 10.253.202.1 dev ens2 proto static
# Restore only our known route on a failed negative check, without flushing others.
trap 'ip -n r12-lan route add 10.253.203.1/32 via 10.253.202.1 dev ens2 proto static 2>/dev/null || true' EXIT
bypass=r12-bypass-$(date +%s)-$$
if ip netns exec r12-lan curl --noproxy '*' --connect-timeout 1 --max-time 2 -sS "http://10.253.203.1:8080/r12/$bypass" >"$S/bypass.body" 2>"$S/bypass.error"; then echo STOP_BYPASS_WORKED; exit 1; fi
if grep -Fq "$bypass" "$S/requests.jsonl"; then echo STOP_BYPASS_REACHED_WAN; exit 1; fi
ip -n r12-lan route add 10.253.203.1/32 via 10.253.202.1 dev ens2 proto static
trap - EXIT
echo NO_BYPASS_PASS
echo BEGIN_FIXTURE_FAILURE
bash "$S/control.sh" stop
set +e
ip netns exec r12-lan curl --noproxy '*' --connect-timeout 1 --max-time 2 -sS http://10.253.203.1:8080/r12/stopped >"$S/stopped.body" 2>"$S/stopped-http.error"
http_rc=$?
ip netns exec r12-lan /usr/bin/python3 "$S/fixture.py" probe udp stopped-udp >"$S/stopped-udp.error" 2>&1
udp_rc=$?
ip netns exec r12-lan /usr/bin/python3 "$S/fixture.py" probe tcp stopped-tcp >"$S/stopped-tcp.error" 2>&1
tcp_rc=$?
set -e
test "$http_rc" = 7; test "$udp_rc" != 0; test "$tcp_rc" != 0
ip netns exec r12-lan ping -c 1 -W 1 10.253.202.1 >/dev/null
printf 'SERVICE_FAILURE_CLASSIFIED HTTP_RC=%s DNS_UDP_RC=%s DNS_TCP_RC=%s ROUTER_ALIVE\n' "$http_rc" "$udp_rc" "$tcp_rc"
bash "$S/control.sh" start
sh "$S/probe.sh"
echo FIXTURE_RECOVERY_PASS
echo BEGIN_ROLLBACK_ROUNDTRIP
bash "$S/control.sh" rollback
if ip netns exec r12-lan curl --noproxy '*' --connect-timeout 1 --max-time 2 -sS http://10.253.203.1:8080/r12/rolledback >/dev/null 2>&1; then echo STOP_ROLLBACK_REACHABLE; exit 1; fi
cmp -s "$S/routes.lan.before" "$S/routes.lan.current"
ip -n r12-wan -4 route > "$S/routes.wan.current"
cmp -s "$S/routes.wan.before" "$S/routes.wan.current"
echo INDEPENDENT_STAGE6_ROLLBACK_PASS
bash "$S/control.sh" apply
sh "$S/probe.sh"
echo STAGE6_FINAL_WORKING_RESTORED
