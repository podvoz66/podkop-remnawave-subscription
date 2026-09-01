#!/usr/bin/env bash
set -euo pipefail

# Server-side only. GitHub is deliberately allowed here, never on the router.
PODKOP_APPROVED_VERSION='0.7.22'
UPSTREAM_REPOSITORY='itdoginfo/podkop'
GITHUB_API_URL="https://api.github.com/repos/${UPSTREAM_REPOSITORY}/releases/tags/${PODKOP_APPROVED_VERSION}"
PODKOP_MAKEFILE_URL="https://raw.githubusercontent.com/${UPSTREAM_REPOSITORY}/${PODKOP_APPROVED_VERSION}/podkop/Makefile"
LUCI_MAKEFILE_URL="https://raw.githubusercontent.com/${UPSTREAM_REPOSITORY}/${PODKOP_APPROVED_VERSION}/luci-app-podkop/Makefile"
IPK_DOCKERFILE_URL="https://raw.githubusercontent.com/${UPSTREAM_REPOSITORY}/${PODKOP_APPROVED_VERSION}/Dockerfile-ipk"
APK_DOCKERFILE_URL="https://raw.githubusercontent.com/${UPSTREAM_REPOSITORY}/${PODKOP_APPROVED_VERSION}/Dockerfile-apk"
LISTS_UPSTREAM_BASE='https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Subnets/IPv4'

EXPECTED_ASSETS=(
  'luci-app-podkop-0.7.22-r1.apk'
  'luci-app-podkop-v0.7.22-r1-all.ipk'
  'luci-i18n-podkop-ru-0.7.22.apk'
  'luci-i18n-podkop-ru-0.7.22.ipk'
  'podkop-0.7.22-r1.apk'
  'podkop-v0.7.22-r1-all.ipk'
)

LIST_FILES=(cloudflare.lst discord.lst meta.lst telegram.lst twitter.lst)

usage() {
  echo "Usage: $0 OPENWRT_V1_ROOT" >&2
}

die() {
  echo "[ERROR] $*" >&2
  exit 1
}

expected_ipk_metadata() {
  case "$1" in
    'podkop-v0.7.22-r1-all.ipk') printf '%s\t%s\n' 'podkop' 'v0.7.22-r1' ;;
    'luci-app-podkop-v0.7.22-r1-all.ipk') printf '%s\t%s\n' 'luci-app-podkop' 'v0.7.22-r1' ;;
    'luci-i18n-podkop-ru-0.7.22.ipk') printf '%s\t%s\n' 'luci-i18n-podkop-ru' '0.260818.58098' ;;
    *) die "No approved IPK metadata contract for $1" ;;
  esac
}

verify_github_digest() {
  computed_sha256="$1"
  github_digest="$2"
  asset_name="$3"

  if [ -z "$github_digest" ] || [ "$github_digest" = 'null' ]; then
    echo "GITHUB_DIGEST=UNAVAILABLE ASSET=$asset_name"
    return 0
  fi

  case "$github_digest" in
    sha256:*) expected_sha256="${github_digest#sha256:}" ;;
    *) die "Unsupported GitHub digest format for $asset_name" ;;
  esac
  [ "${#expected_sha256}" -eq 64 ] || die "Invalid GitHub SHA256 length for $asset_name"
  case "$expected_sha256" in *[!0-9a-fA-F]*) die "Invalid GitHub SHA256 for $asset_name" ;; esac
  [ "$computed_sha256" = "$expected_sha256" ] || die "GitHub digest mismatch for $asset_name"
  echo "GITHUB_DIGEST_MATCH=YES ASSET=$asset_name"
}

validate_ipk_gzip_tar() {
  package_path="$1"
  expected_package="$2"
  expected_version="$3"
  asset_name="$4"

  # OpenWrt v24.10.6 scripts/ipkg-build emits an outer TAR compressed with gzip,
  # containing debian-binary, control.tar.gz, and data.tar.gz. Keep original bytes.
  [ -s "$package_path" ] || die "Missing or empty IPK: $asset_name"
  magic="$(od -An -tx1 -N2 "$package_path" | tr -d ' \n')"
  [ "$magic" = '1f8b' ] || die "IPK gzip magic mismatch for $asset_name"
  gzip -t "$package_path" 2>/dev/null || die "Invalid IPK gzip stream: $asset_name"

  validation_parent="${IPK_VALIDATION_TMP_ROOT:-${TMPDIR:-/tmp}}"
  validation_dir="$(mktemp -d "$validation_parent/adeptpro-ipk-validation.XXXXXX")"
  if ! outer_entries="$(gzip -dc "$package_path" | tar -tf -)"; then
    rm -rf "$validation_dir"
    die "Unreadable IPK outer tar: $asset_name"
  fi
  if ! printf '%s\n' "$outer_entries" | while IFS= read -r entry; do
    case "$entry" in /*|../*|*/../*|*/..) exit 1 ;; esac
  done; then
    rm -rf "$validation_dir"
    die "Unsafe IPK outer tar path: $asset_name"
  fi
  if ! gzip -dc "$package_path" | tar -xf - -C "$validation_dir"; then
    rm -rf "$validation_dir"
    die "Cannot extract IPK validation tree: $asset_name"
  fi

  for required_member in debian-binary control.tar.gz data.tar.gz; do
    if [ ! -f "$validation_dir/$required_member" ]; then
      rm -rf "$validation_dir"
      die "Missing IPK member $required_member: $asset_name"
    fi
  done
  if [ "$(cat "$validation_dir/debian-binary")" != '2.0' ]; then
    rm -rf "$validation_dir"
    die "Unsupported debian-binary value: $asset_name"
  fi

  if ! gzip -t "$validation_dir/control.tar.gz" 2>/dev/null; then
    rm -rf "$validation_dir"
    die "Invalid control.tar.gz stream: $asset_name"
  fi
  control_entry="$(tar -tzf "$validation_dir/control.tar.gz" | grep -E '^(\./)?control$' | head -n 1 || true)"
  if [ -z "$control_entry" ]; then
    rm -rf "$validation_dir"
    die "Missing control metadata: $asset_name"
  fi
  if ! control_metadata="$(tar -xzOf "$validation_dir/control.tar.gz" "$control_entry")"; then
    rm -rf "$validation_dir"
    die "Unreadable control metadata: $asset_name"
  fi
  package_name="$(printf '%s\n' "$control_metadata" | sed -n 's/^Package:[[:space:]]*//p' | head -n 1)"
  package_version="$(printf '%s\n' "$control_metadata" | sed -n 's/^Version:[[:space:]]*//p' | head -n 1)"
  package_architecture="$(printf '%s\n' "$control_metadata" | sed -n 's/^Architecture:[[:space:]]*//p' | head -n 1)"
  if [ "$package_name" != "$expected_package" ]; then
    rm -rf "$validation_dir"
    die "Unexpected Package '$package_name' in $asset_name"
  fi
  if [ "$package_version" != "$expected_version" ]; then
    rm -rf "$validation_dir"
    die "Unexpected Version '$package_version' in $asset_name"
  fi
  if [ "$package_architecture" != 'all' ]; then
    rm -rf "$validation_dir"
    die "Unexpected Architecture '$package_architecture' in $asset_name"
  fi

  if ! gzip -t "$validation_dir/data.tar.gz" 2>/dev/null \
    || ! tar -tzf "$validation_dir/data.tar.gz" >/dev/null; then
    rm -rf "$validation_dir"
    die "Invalid data.tar.gz archive: $asset_name"
  fi

  rm -rf "$validation_dir"
  echo "IPK_CONTAINER=gzip-tar ASSET=$asset_name"
  echo "IPK_DEBIAN_BINARY=2.0 ASSET=$asset_name"
  echo "IPK_CONTROL_METADATA=PASS ASSET=$asset_name"
  echo "IPK_DATA_ARCHIVE=PASS ASSET=$asset_name"
  echo "IPK_ARCHITECTURE=all ASSET=$asset_name"
}

if [ "${ADEPTPRO_SYNC_LIB_ONLY:-0}" = '1' ]; then
  return 0 2>/dev/null || exit 0
fi

[ "$#" -eq 1 ] || { usage; exit 2; }

for command_name in curl jq sha256sum stat sort cmp mktemp tar gzip od tr grep sed head awk; do
  command -v "$command_name" >/dev/null 2>&1 || die "Missing server dependency: $command_name"
done

publish_root="$1"
parent_dir="$(dirname "$publish_root")"
mkdir -p "$parent_dir"
[ ! -e "$publish_root" ] || die "Publish target already exists; use a new immutable release path: $publish_root"
stage_root="$(mktemp -d "${parent_dir}/.openwrt-v1-sync.XXXXXX")"
cleanup() {
  rm -rf "$stage_root"
}
trap cleanup EXIT

api_json="$stage_root/release.json"
curl -fsSL --retry 3 --connect-timeout 20 "$GITHUB_API_URL" -o "$api_json"
curl -fsSL --retry 3 --connect-timeout 20 "$PODKOP_MAKEFILE_URL" -o "$stage_root/podkop.Makefile"
curl -fsSL --retry 3 --connect-timeout 20 "$LUCI_MAKEFILE_URL" -o "$stage_root/luci.Makefile"
curl -fsSL --retry 3 --connect-timeout 20 "$IPK_DOCKERFILE_URL" -o "$stage_root/Dockerfile-ipk"
curl -fsSL --retry 3 --connect-timeout 20 "$APK_DOCKERFILE_URL" -o "$stage_root/Dockerfile-apk"
grep -Eq '^[[:space:]]*PKGARCH[[:space:]]*:=[[:space:]]*all[[:space:]]*$' "$stage_root/podkop.Makefile" \
  || die "Upstream Podkop package is no longer declared architecture-independent."
grep -Eq '^[[:space:]]*LUCI_PKGARCH[[:space:]]*:=[[:space:]]*all[[:space:]]*$' "$stage_root/luci.Makefile" \
  || die "Upstream LuCI package is no longer declared architecture-independent."
grep -q '^FROM itdoginfo/openwrt-sdk-ipk:24\.10\.6$' "$stage_root/Dockerfile-ipk" \
  || die "Approved IPK SDK contract changed."
grep -q '^FROM itdoginfo/openwrt-sdk-apk:25\.12\.3$' "$stage_root/Dockerfile-apk" \
  || die "Approved APK SDK contract changed."

actual_tag="$(jq -r '.tag_name // empty' "$api_json")"
[ "$actual_tag" = "$PODKOP_APPROVED_VERSION" ] || die "Unexpected upstream tag: ${actual_tag:-missing}"

printf '%s\n' "${EXPECTED_ASSETS[@]}" | sort > "$stage_root/expected-assets.txt"
jq -r '.assets[].name' "$api_json" | sort > "$stage_root/actual-assets.txt"
if ! cmp -s "$stage_root/expected-assets.txt" "$stage_root/actual-assets.txt"; then
  echo "[ERROR] Podkop ${PODKOP_APPROVED_VERSION} asset set differs from the approved contract." >&2
  echo "[ERROR] Refusing to guess package names or publish a partial mirror." >&2
  diff -u "$stage_root/expected-assets.txt" "$stage_root/actual-assets.txt" || true
  exit 1
fi

version_dir="$stage_root/openwrt/v1/podkop/$PODKOP_APPROVED_VERSION"
lists_dir="$stage_root/openwrt/v1/lists"
mkdir -p "$version_dir/opkg/all" "$version_dir/apk/all" "$lists_dir"

files_json='[]'
for asset_name in "${EXPECTED_ASSETS[@]}"; do
  asset_url="$(jq -r --arg name "$asset_name" '.assets[] | select(.name == $name) | .browser_download_url' "$api_json")"
  [ -n "$asset_url" ] && [ "$asset_url" != 'null' ] || die "Missing download URL for $asset_name"
  case "$asset_name" in
    *.ipk) package_manager='opkg'; package_format='ipk' ;;
    *.apk) package_manager='apk'; package_format='apk' ;;
    *) die "Unapproved package format: $asset_name" ;;
  esac
  architecture='all'
  destination="$version_dir/$package_manager/$architecture/$asset_name"
  curl -fsSL --retry 3 --connect-timeout 20 "$asset_url" -o "$destination"
  [ -s "$destination" ] || die "Downloaded empty asset: $asset_name"
  sha256="$(sha256sum "$destination" | awk '{print $1}')"
  github_digest="$(jq -r --arg name "$asset_name" '.assets[] | select(.name == $name) | (.digest // empty)' "$api_json")"
  verify_github_digest "$sha256" "$github_digest" "$asset_name"
  if [ "$package_manager" = 'opkg' ]; then
    metadata_contract="$(expected_ipk_metadata "$asset_name")"
    expected_package="${metadata_contract%%	*}"
    expected_version="${metadata_contract#*	}"
    validate_ipk_gzip_tar "$destination" "$expected_package" "$expected_version" "$asset_name"
  fi
  size="$(stat -c '%s' "$destination")"
  relative_path="$package_manager/$architecture/$asset_name"
  files_json="$(jq -c \
    --arg name "$asset_name" \
    --arg sha256 "$sha256" \
    --argjson size "$size" \
    --arg packageManager "$package_manager" \
    --arg packageFormat "$package_format" \
    --arg architecture "$architecture" \
    --arg path "$relative_path" \
    '. + [{name:$name,sha256:$sha256,size:$size,packageManager:$packageManager,packageFormat:$packageFormat,architecture:$architecture,path:$path}]' \
    <<<"$files_json")"
done

generated_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
manifest_tmp="$version_dir/manifest.json.tmp"
jq -n \
  --arg podkopVersion "$PODKOP_APPROVED_VERSION" \
  --arg generatedAt "$generated_at" \
  --argjson files "$files_json" \
  '{
    schemaVersion:1,
    podkopVersion:$podkopVersion,
    generatedAt:$generatedAt,
    files:$files,
    platforms:{
      opkg:{architectures:{all:[$files[] | select(.packageManager == "opkg")]}},
      apk:{architectures:{all:[$files[] | select(.packageManager == "apk")]}}
    }
  }' \
  > "$manifest_tmp"
mv "$manifest_tmp" "$version_dir/manifest.json"
cp "$version_dir/manifest.json" "$stage_root/openwrt/v1/podkop/manifest.json"
cp "$stage_root/openwrt/v1/podkop/manifest.json" "$stage_root/openwrt/v1/manifest.json"

for list_name in "${LIST_FILES[@]}"; do
  curl -fsSL --retry 3 --connect-timeout 20 "$LISTS_UPSTREAM_BASE/$list_name" -o "$lists_dir/$list_name"
  [ -s "$lists_dir/$list_name" ] || die "Downloaded empty list: $list_name"
done

mv "$stage_root/openwrt/v1" "$publish_root"

echo "PODKOP_APPROVED_VERSION=$PODKOP_APPROVED_VERSION"
echo "MIRROR_SYNC=PASS"
