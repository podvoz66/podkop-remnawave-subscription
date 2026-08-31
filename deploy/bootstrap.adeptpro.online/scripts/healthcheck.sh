#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-https://bootstrap.adeptpro.online}"
[ "$(curl -fsS "$BASE_URL/health.txt")" = 'OK' ]
curl -fsS "$BASE_URL/openwrt/v1/manifest.json" | jq -e \
  '.schemaVersion == 1 and .podkopVersion == "0.7.22" and (.files | length == 6)' >/dev/null
echo 'MIRROR_HEALTHCHECK=PASS'
