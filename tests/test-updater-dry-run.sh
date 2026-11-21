#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/update-podkop-from-remnawave.sh"
TMP="${TMPDIR:-/tmp}/podkop-updater-test.$$"

cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP/bin"

cat > "$TMP/bin/uci" <<'EOF'
#!/bin/sh
case "$*" in
  "-q show podkop.main") exit 0 ;;
  "-q show podkop.USA") exit 1 ;;
  "-q get podkop.main.urltest_proxy_links") cat "$TEST_CURRENT_LINKS"; exit 0 ;;
  "-q get podkop.USA.urltest_proxy_links") exit 1 ;;
esac
exit 1
EOF

cat > "$TMP/bin/curl" <<'EOF'
#!/bin/sh
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift; out="$1" ;;
  esac
  shift || true
done
[ -n "$out" ] || exit 2
cp "$TEST_SUBSCRIPTION_BODY" "$out"
EOF

chmod +x "$TMP/bin/uci" "$TMP/bin/curl"

hash_full() {
  printf '%s' "$1" | sha256sum | awk '{print $1}'
}

hash12() {
  printf '%s' "$1" | sha256sum | awk '{print substr($1,1,12)}'
}

write_conf() {
  preserve="$1"
  deny="$2"
  cat > "$TMP/subscription.conf" <<EOF
SUB_URL='https://example.invalid/sub'
PRESERVE_MANUAL_LINKS='$preserve'
DENYLIST_SHA256='$deny'
EOF
}

write_subscription() {
  cat > "$TMP/subscription.txt"
  base64 "$TMP/subscription.txt" > "$TMP/subscription.b64"
}

run_dry() {
  PATH="$TMP/bin:$PATH" \
  CONF="$TMP/subscription.conf" \
  DENYLIST_FILE="$TMP/denylist.sha256" \
  TEST_CURRENT_LINKS="$TMP/current.links" \
  TEST_SUBSCRIPTION_BODY="$TMP/subscription.b64" \
  sh "$SCRIPT" --dry-run > "$TMP/out" 2> "$TMP/err"
}

assert_contains() {
  file="$1"
  pattern="$2"
  if ! grep -Fq "$pattern" "$file"; then
    echo "missing pattern: $pattern" >&2
    echo "--- $file" >&2
    cat "$file" >&2
    exit 1
  fi
}

sub='vless://sub@example.com:443?security=reality#sub'
sub_norm='vless://sub@example.com:443?security=reality&spx=%2F#sub-rwsub'
manual='ss://manual@example.com:2040#manual'

printf '%s\n%s\n' "$manual" "$sub_norm" > "$TMP/current.links"
write_subscription <<EOF
$sub
EOF
write_conf 0 ''
run_dry
assert_contains "$TMP/out" "[INFO] preserve_manual=0"
assert_contains "$TMP/out" "[INFO] main_candidate_count=1"
assert_contains "$TMP/out" "[INFO] preserved_manual_main=0"
assert_contains "$TMP/out" "hash=$(hash12 "$sub_norm")"

write_conf 1 ''
run_dry
assert_contains "$TMP/out" "[INFO] preserve_manual=1"
assert_contains "$TMP/out" "[INFO] main_candidate_count=1"
assert_contains "$TMP/out" "[INFO] preserved_manual_main=1"
assert_contains "$TMP/out" "hash=$(hash12 "$manual")"

deny_sub="$(hash_full "$sub_norm")"
deny_manual="$(hash_full "$manual")"
write_conf 1 "$deny_sub $deny_manual"
run_dry
assert_contains "$TMP/out" "[INFO] main_candidate_count=0"
assert_contains "$TMP/out" "[INFO] preserved_manual_main=0"
assert_contains "$TMP/err" "decision=deny"

echo "ok updater dry-run tests"
