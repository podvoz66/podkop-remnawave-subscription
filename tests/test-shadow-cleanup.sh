#!/bin/sh
# Process-lifecycle regression: health checks called during an outer EXIT rollback.
set -eu
repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
. "$repo/scripts/podkop-failover-lib.sh"
R=$tmp; RUN=$tmp/run; CFG=$tmp/config; REQUIRED_SECTIONS='main USA'
mkdir -p "$RUN" "$CFG" "$R/var/lock" "$tmp/bin"
cat > "$tmp/bin/sing-box" <<'CHILD'
#!/bin/sh
printf '%s\n' "$$" > "$SHADOW_TEST_PID"
exec sleep 60
CHILD
chmod 700 "$tmp/bin/sing-box"
PATH=$tmp/bin:$PATH; export PATH
SHADOW_TEST_PID=$tmp/child.pid; export SHADOW_TEST_PID
validate_sections(){ :; }
make_probe_config(){ printf '{}\n' > "$2"; }
http_via(){ [ ! -f "$tmp/inject-http-failure" ]; }
assert_reaped(){
 pid=$(cat "$SHADOW_TEST_PID")
 ! kill -0 "$pid" 2>/dev/null
 [ -z "$(find "$RUN" -mindepth 1 -maxdepth 1 -type d -print)" ]
}
shadow_health "$CFG"
assert_reaped
(trap 'shadow_health "$CFG"' EXIT; exit 0)
assert_reaped
touch "$tmp/inject-http-failure"
if (trap 'shadow_health "$CFG"' EXIT; exit 1); then exit 1; fi
assert_reaped
echo SHADOW_NORMAL_AND_NESTED_EXIT_SUCCESS_FAILURE_REAP_PASS
