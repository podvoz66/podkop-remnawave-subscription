#!/bin/sh
set -eu

COMMENT="podkop-router-output-bypass"
TABLE_FAMILY="inet"
TABLE_NAME="PodkopTable"
CHAIN_NAME="mangle_output"

log() {
  echo "[podkop-router-output-bypass] $*"
}

if ! command -v nft >/dev/null 2>&1; then
  log "nft command not found; skipping."
  exit 0
fi

if ! nft list chain "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" >/dev/null 2>&1; then
  log "$TABLE_FAMILY $TABLE_NAME $CHAIN_NAME not found; skipping."
  exit 0
fi

if nft list chain "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" 2>/dev/null | grep -Fq "$COMMENT"; then
  log "rule already present."
  exit 0
fi

if nft insert rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" counter return comment "$COMMENT" 2>/dev/null; then
  log "inserted first rule in $TABLE_FAMILY $TABLE_NAME $CHAIN_NAME."
else
  log "failed to insert rule; leaving router state unchanged."
fi

exit 0
