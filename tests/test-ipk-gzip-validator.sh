#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC="$ROOT/scripts/sync-podkop-mirror.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/adeptpro-ipk-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

ADEPTPRO_SYNC_LIB_ONLY=1 source "$SYNC"
export IPK_VALIDATION_TMP_ROOT="$TEST_ROOT"

make_fixture() {
  output="$1"
  package_name="$2"
  package_version="$3"
  architecture="$4"
  include_control="$5"
  fixture_root="$TEST_ROOT/fixture-$(basename "$output")"
  rm -rf "$fixture_root"
  mkdir -p "$fixture_root/outer" "$fixture_root/control" "$fixture_root/data/usr/share/adeptpro-test"
  printf 'fixture\n' > "$fixture_root/data/usr/share/adeptpro-test/payload"
  printf '2.0\n' > "$fixture_root/outer/debian-binary"
  if [ "$include_control" = 'yes' ]; then
    {
      printf 'Package: %s\n' "$package_name"
      printf 'Version: %s\n' "$package_version"
      printf 'Architecture: %s\n' "$architecture"
      printf 'Description: synthetic validation fixture\n'
    } > "$fixture_root/control/control"
    tar -czf "$fixture_root/outer/control.tar.gz" -C "$fixture_root/control" ./control
  fi
  tar -czf "$fixture_root/outer/data.tar.gz" -C "$fixture_root/data" .
  (
    cd "$fixture_root/outer"
    members='./debian-binary ./data.tar.gz'
    [ "$include_control" = 'yes' ] && members="$members ./control.tar.gz"
    # shellcheck disable=SC2086
    tar -cf - $members | gzip -n > "$output"
  )
}

valid_ipk="$TEST_ROOT/podkop-v0.7.22-r1-all.ipk"
make_fixture "$valid_ipk" podkop v0.7.22-r1 all yes
validate_ipk_gzip_tar "$valid_ipk" podkop v0.7.22-r1 "$(basename "$valid_ipk")" >/dev/null
echo 'IPK_GZIP_MAGIC_VALIDATION=PASS'
echo 'IPK_OUTER_TAR_VALIDATION=PASS'
echo 'IPK_DEBIAN_BINARY_2_0=PASS'
echo 'IPK_CONTROL_TAR_VALIDATION=PASS'
echo 'IPK_DATA_TAR_VALIDATION=PASS'
echo 'IPK_ARCHITECTURE_ALL=PASS'
echo 'IPK_PACKAGE_NAME_VALIDATION=PASS'
echo 'IPK_VERSION_VALIDATION=PASS'

valid_sha="$(sha256sum "$valid_ipk" | awk '{print $1}')"
verify_github_digest "$valid_sha" "sha256:$valid_sha" "$(basename "$valid_ipk")" >/dev/null
echo 'GITHUB_ASSET_DIGEST_VALIDATION=PASS'
wrong_digest='0000000000000000000000000000000000000000000000000000000000000000'
if (verify_github_digest "$valid_sha" "sha256:$wrong_digest" "$(basename "$valid_ipk")" >/dev/null 2>&1); then
  echo 'FAIL_CLOSED_GITHUB_DIGEST_MISMATCH=FAIL'
  exit 1
fi
echo 'FAIL_CLOSED_GITHUB_DIGEST_MISMATCH=PASS'
unavailable_log="$(verify_github_digest "$valid_sha" '' "$(basename "$valid_ipk")")"
if [ "$unavailable_log" != "GITHUB_DIGEST=UNAVAILABLE ASSET=$(basename "$valid_ipk")" ]; then
  echo 'GITHUB_DIGEST_UNAVAILABLE_LOGGING=FAIL'
  exit 1
fi
echo 'GITHUB_DIGEST_UNAVAILABLE_LOGGING=PASS'

if grep -Eq '(^|[^[:alnum:]_])ar[[:space:]]+(t|p)([^[:alnum:]_]|$)|command_name[^#]*[[:space:]]ar([[:space:]]|$)' "$SYNC"; then
  echo 'AR_REQUIRED_FOR_IPK=YES'
  exit 1
fi
echo 'AR_REQUIRED_FOR_IPK=NO'

if grep -q 'if \[ "$package_manager" = '\''opkg'\'' \]; then' "$SYNC"; then
  echo 'APK_VALIDATION_UNCHANGED=PASS'
else
  echo 'APK_VALIDATION_UNCHANGED=FAIL'
  exit 1
fi

corrupt_ipk="$TEST_ROOT/corrupt.ipk"
printf 'not-a-gzip-stream\n' > "$corrupt_ipk"
if (validate_ipk_gzip_tar "$corrupt_ipk" podkop v0.7.22-r1 corrupt.ipk >/dev/null 2>&1); then
  echo 'FAIL_CLOSED_CORRUPT_GZIP=FAIL'
  exit 1
fi
echo 'FAIL_CLOSED_CORRUPT_GZIP=PASS'

missing_control_ipk="$TEST_ROOT/missing-control.ipk"
make_fixture "$missing_control_ipk" podkop v0.7.22-r1 all no
if (validate_ipk_gzip_tar "$missing_control_ipk" podkop v0.7.22-r1 missing-control.ipk >/dev/null 2>&1); then
  echo 'FAIL_CLOSED_MISSING_CONTROL=FAIL'
  exit 1
fi
echo 'FAIL_CLOSED_MISSING_CONTROL=PASS'

wrong_arch_ipk="$TEST_ROOT/wrong-arch.ipk"
make_fixture "$wrong_arch_ipk" podkop v0.7.22-r1 x86_64 yes
if (validate_ipk_gzip_tar "$wrong_arch_ipk" podkop v0.7.22-r1 wrong-arch.ipk >/dev/null 2>&1); then
  echo 'FAIL_CLOSED_WRONG_ARCH=FAIL'
  exit 1
fi
echo 'FAIL_CLOSED_WRONG_ARCH=PASS'
