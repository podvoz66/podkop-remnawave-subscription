#!/usr/bin/env bash
set -euo pipefail

SERVER_ROOT="${SERVER_ROOT:-/srv/bootstrap.adeptpro.online}"
REPOSITORY_ROOT="${REPOSITORY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
release_id="${1:-$(date -u +'%Y%m%dT%H%M%SZ')}"
case "$release_id" in
  ''|.|..|*[!A-Za-z0-9._-]*) echo "[ERROR] Invalid release id: $release_id" >&2; exit 2 ;;
esac
release_root="$SERVER_ROOT/releases/$release_id"

[ ! -e "$release_root" ] || { echo "[ERROR] Release already exists: $release_root" >&2; exit 1; }
mkdir -p "$release_root/openwrt"

"$REPOSITORY_ROOT/scripts/sync-podkop-mirror.sh" "$release_root/openwrt/v1"

cp "$REPOSITORY_ROOT/scripts/bootstrap-openwrt-router.sh" "$release_root/openwrt/v1/bootstrap.sh"
mkdir -p "$release_root/openwrt/v1/scripts"
for script_name in \
  update-podkop-from-remnawave.sh \
  update-podkop-from-remnawave.guard.sh \
  podkop-all-lists-guard.sh \
  install-tailscale-direct-access.sh \
  adeptpro-postboot.sh \
  adeptpro-postboot.init; do
  cp "$REPOSITORY_ROOT/scripts/$script_name" "$release_root/openwrt/v1/scripts/$script_name"
done
printf 'OK\n' > "$release_root/health.txt"

ln -s "$release_root" "$SERVER_ROOT/.current.$release_id"
mv -Tf "$SERVER_ROOT/.current.$release_id" "$SERVER_ROOT/current"

echo "PUBLISHED_RELEASE=$release_id"
echo "CURRENT=$SERVER_ROOT/current"
