#!/bin/sh
# Real LAB203 native updater tests. No external route/production data.
set -eu
umask 077
[ "$(cat /sys/class/net/eth1/address)" = 02:52:12:02:03:02 ]
[ -z "$(ip -4 route show default)" ]
S=/root/r12-native-test
export GUARD_LIB=$S/podkop-failover-lib.sh NATIVE_LIB=$S/podkop-native-update-lib.sh
export UPDATER_MODE=native CONF=$S/subscription.conf
export CURL_CA_BUNDLE=/root/r12-engine-runtime/ca.crt
export PROBE_URLS=http://10.253.203.1:8001/probe64k DNS_PROBE_NAME=fixture.r12.test
run(){ sh "$S/update-podkop-from-remnawave.sh" > "$S/$1.log" 2>&1; }
url(){ printf "SUB_URL='https://10.253.203.1:8002/subscription/%s'\n" "$1" > "$CONF"; }
case ${1:-negative} in
negative)
 sha256sum /etc/config/podkop > "$S/config.before-negative"
 for kind in empty main-only 500 timeout; do
  url "$kind"; rc=0; run "$kind" || rc=$?
  [ "$rc" != 0 ]
  sha256sum -c "$S/config.before-negative" >/dev/null
  [ ! -e /etc/podkop-failover/native/pending ]
  echo "NEGATIVE_$kind=REJECTED_CONFIG_UNCHANGED"
 done
 ;;
positive)
 url valid
 mkdir -p "$S/positive.expected/.uci"
 cp -p /etc/config/podkop "$S/positive.expected/podkop"
 run positive || { grep -E '^(Update |Native |CRITICAL:)' "$S/positive.log" || true; exit 1; }
 for sec in main USA; do
  links=$(uci -q get podkop.$sec.urltest_proxy_links)
  printf '%s\n' "$links" | grep -Fq "#manual-$sec-rwsub"
  [ "$(printf '%s\n' "$links" | wc -w)" = 2 ]
  [ "$(wc -l < /etc/podkop-failover/native/managed/$sec)" = 1 ]
 done
 unset links
 uci -c "$S/positive.expected" -t "$S/positive.expected/.uci" show podkop | sed '/^podkop.settings.shutdown_correctly=/d' > "$S/positive.expected.private"
 uci -c /etc/podkop-failover/native/previous-good -t "$S/positive.expected/.uci" show podkop | sed '/^podkop.settings.shutdown_correctly=/d' > "$S/positive.saved.private"
 cmp "$S/positive.expected.private" "$S/positive.saved.private"
 [ ! -e /etc/podkop-failover/native/pending ]
 echo NATIVE_APPLY_MANUAL_RWSUB_AND_PREVIOUS_GOOD_PASS_CLIENT_PROBE_REQUIRED
 ;;
rollback)
 url valid
 mkdir -p "$S/rollback.expected/.uci"
 cp -p /etc/config/podkop "$S/rollback.expected/podkop"
 uci -c "$S/rollback.expected" -t "$S/rollback.expected/.uci" show podkop | sed '/^podkop.settings.shutdown_correctly=/d' > "$S/rollback.expected.private"
 cat > "$S/fail-once-service.sh" <<'HOOK'
#!/bin/sh
if [ "$1" = restart ] && [ -f /root/r12-native-test/fail-restart.once ]; then
 rm /root/r12-native-test/fail-restart.once
 exit 1
fi
exec /etc/init.d/podkop "$@"
HOOK
 chmod 700 "$S/fail-once-service.sh"
 touch "$S/fail-restart.once"
 export NATIVE_SERVICE=$S/fail-once-service.sh
 rc=0; run rollback || rc=$?
 [ "$rc" != 0 ] && [ ! -e "$S/fail-restart.once" ]
 uci -c /etc/config -t "$S/rollback.expected/.uci" show podkop | sed '/^podkop.settings.shutdown_correctly=/d' > "$S/rollback.actual.private"
 cmp "$S/rollback.expected.private" "$S/rollback.actual.private"
 [ ! -e /etc/podkop-failover/native/pending ]
 echo NATIVE_POST_RENAME_FAILURE_ROLLBACK_CONFIG_RESTORED_CLIENT_PROBE_REQUIRED
 ;;
cleanup)
 export DRY_RUN=0
 . "$GUARD_LIB"
 guard_setup
 shadow_health "$CFG"
 shadow_health "$CFG"
 for proc in /proc/[0-9]*; do
  [ -r "$proc/comm" ] && [ "$(cat "$proc/comm")" = sing-box ] || continue
  if tr '\000' '\n' < "$proc/cmdline" | grep -Eq '^/tmp/podkop-failover/probe\.[A-Za-z0-9]+/config.json$'; then
   echo STOP_ORPHAN_PROBE_PRESENT; exit 1
  fi
 done
 echo TWO_SHADOW_HTTP_PASSES_NO_ORPHAN
 ;;
unchanged)
 url valid
 sha256sum /etc/config/podkop > "$S/config.before-unchanged"
 before=$(ubus call service list '{"name":"sing-box"}' | jsonfilter -e '@["sing-box"].instances["sing-box.main"].pid')
 [ -n "$before" ]
 run unchanged
 sha256sum -c "$S/config.before-unchanged" >/dev/null
 after=$(ubus call service list '{"name":"sing-box"}' | jsonfilter -e '@["sing-box"].instances["sing-box.main"].pid')
 [ "$before" = "$after" ]
 [ ! -e /etc/podkop-failover/native/pending ]
 echo UNCHANGED_SUBSCRIPTION_CONFIG_AND_PID_PRESERVED
 ;;
concurrent)
 sha256sum /etc/config/podkop > "$S/config.before-concurrent"
 url timeout
 sh "$S/update-podkop-from-remnawave.sh" > "$S/concurrent-first.log" 2>&1 &
 child=$!
 sleep 1
 rc=0; run concurrent-second || rc=$?
 [ "$rc" = 75 ]
 first=0; wait "$child" || first=$?
 [ "$first" != 0 ]
 sha256sum -c "$S/config.before-concurrent" >/dev/null
 [ ! -e /etc/podkop-failover/native/pending ]
 echo CONCURRENT_SECOND_RC75_FIRST_DOWNLOAD_REJECTED
 ;;
*) exit 2;;
esac
