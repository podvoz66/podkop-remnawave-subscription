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

[ "$#" -eq 1 ] || { usage; exit 2; }

for command_name in curl jq sha256sum stat sort cmp mktemp ar tar; do
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
  if [ "$package_manager" = 'opkg' ]; then
    control_archive="$(ar t "$destination" | grep '^control\.tar' | head -n 1 || true)"
    [ -n "$control_archive" ] || die "Cannot locate IPK control metadata: $asset_name"
    case "$control_archive" in
      *.gz) ipk_arch="$(ar p "$destination" "$control_archive" | tar -xzOf - ./control | sed -n 's/^Architecture:[[:space:]]*//p')" ;;
      *) die "Unsupported IPK control archive: $control_archive" ;;
    esac
    [ "$ipk_arch" = 'all' ] || die "Unexpected IPK architecture '$ipk_arch' in $asset_name"
  fi
  sha256="$(sha256sum "$destination" | awk '{print $1}')"
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
