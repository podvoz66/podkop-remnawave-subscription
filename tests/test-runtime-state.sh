#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
HANDLER="$ROOT/scripts/adeptpro-runtime-state.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/adeptpro-runtime-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

make_mock() {
  name="$1"
  body="$2"
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' "$body"
  } > "$TEST_ROOT/bin/$name"
  chmod 700 "$TEST_ROOT/bin/$name"
}

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/state"
make_mock pgrep 'exit "${MOCK_PGREP_EXIT:-0}"'
make_mock podkop 'exit "${MOCK_PODKOP_EXIT:-0}"'
make_mock uci "printf '%s\\n' \"podkop.settings=main\""
make_mock logger 'exit 0'

expected_hash="$(printf '%s\n' 'podkop.settings=main' | sha256sum | awk '{print $1}')"
printf 'CONFIG_HASH=%s\n' "$expected_hash" > "$TEST_ROOT/state/pending"

PATH="$TEST_ROOT/bin:$PATH" \
PENDING_MARKER="$TEST_ROOT/state/pending" \
LAST_APPLIED_MARKER="$TEST_ROOT/state/last-applied" \
LOG_FILE="$TEST_ROOT/state/success.log" \
WAIT_ATTEMPTS=1 WAIT_SECONDS=0 \
  sh "$HANDLER"

[ ! -e "$TEST_ROOT/state/pending" ]
[ -f "$TEST_ROOT/state/last-applied" ]
grep -q 'RUNTIME_PENDING_FOUND=YES' "$TEST_ROOT/state/success.log"
grep -q 'CONFIG_HASH_MATCH=YES' "$TEST_ROOT/state/success.log"
grep -q 'SINGBOX_RUNNING=YES' "$TEST_ROOT/state/success.log"
grep -q 'RUNTIME_RELOAD_APPLIED_AT_BOOT=YES' "$TEST_ROOT/state/success.log"
echo 'RUNTIME_MARKER_SUCCESS_PATH=PASS'

mv "$TEST_ROOT/state/last-applied" "$TEST_ROOT/state/pending"
if PATH="$TEST_ROOT/bin:$PATH" \
  MOCK_PGREP_EXIT=1 \
  PENDING_MARKER="$TEST_ROOT/state/pending" \
  LAST_APPLIED_MARKER="$TEST_ROOT/state/last-applied" \
  LOG_FILE="$TEST_ROOT/state/failure.log" \
  WAIT_ATTEMPTS=1 WAIT_SECONDS=0 \
    sh "$HANDLER"; then
  echo 'RUNTIME_MARKER_FAILURE_PATH=FAIL'
  exit 1
fi

[ -f "$TEST_ROOT/state/pending" ]
[ ! -e "$TEST_ROOT/state/last-applied" ]
grep -q 'RUNTIME_RELOAD_APPLIED_AT_BOOT=NO' "$TEST_ROOT/state/failure.log"
grep -q 'WARNING=PENDING_RUNTIME_MARKER_PRESERVED' "$TEST_ROOT/state/failure.log"
echo 'RUNTIME_MARKER_FAILURE_PATH=PASS'
