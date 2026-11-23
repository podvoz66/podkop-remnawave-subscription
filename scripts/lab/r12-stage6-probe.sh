set -eu
S=/root/r12-stage6
bash "$S/control.sh" verify
token=r12s6-$(date +%s)-$$
printf '%s\n' "$token" > "$S/last-test-token"
ip netns exec r12-lan curl --noproxy '*' --fail --connect-timeout 2 --max-time 5 -sS -o "$S/http.body" -w 'HTTP=%{http_code}\n' "http://10.253.203.1:8080/r12/$token-http"
grep -Fx "R12 $token-http" "$S/http.body"
ip netns exec r12-lan curl --noproxy '*' --fail --connect-timeout 2 --max-time 5 --cacert "$S/server.crt" --resolve fixture.r12.test:8443:10.253.203.1 -sS -o "$S/https.body" -w 'HTTPS=%{http_code} TLS_VERIFY=%{ssl_verify_result}\n' "https://fixture.r12.test:8443/r12/$token-https"
grep -Fx "R12 $token-https" "$S/https.body"
set +e
ip netns exec r12-lan curl --noproxy '*' --connect-timeout 2 --max-time 5 --cacert "$S/server.crt" --resolve wrong.r12.test:8443:10.253.203.1 -sS -o /dev/null "https://wrong.r12.test:8443/r12/$token-wrong-name" 2>"$S/tls-negative.log"
rc=$?
set -e
test "$rc" = 60
echo TLS_WRONG_NAME_REJECTED
ip netns exec r12-lan /usr/bin/python3 "$S/fixture.py" probe udp "$token-udp"
ip netns exec r12-lan /usr/bin/python3 "$S/fixture.py" probe tcp "$token-tcp"
for suffix in http https udp tcp; do
 value="$token-$suffix"
 case "$suffix" in udp|tcp) value="$value.r12.test";; esac
 grep -F "\"token\": \"$value\"" "$S/requests.jsonl" | grep -F '"peer": "10.253.203.2"'
done
if ip -n r12-lan route get 1.1.1.1 >/dev/null 2>&1; then echo STOP_EXTERNAL_ROUTE; exit 1; fi
if ip -n r12-wan route get 1.1.1.1 >/dev/null 2>&1; then echo STOP_EXTERNAL_ROUTE; exit 1; fi
echo EXTERNAL_IPV4_ROUTES_ABSENT
printf 'STAGE6_TRANSIT_PASS\n'
