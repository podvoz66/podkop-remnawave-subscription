#!/bin/sh
set -eu

PENDING_MARKER="${PENDING_MARKER:-/etc/podkop-remnawave/pending-runtime-reload}"
LAST_APPLIED_MARKER="${LAST_APPLIED_MARKER:-/etc/podkop-remnawave/last-applied-runtime}"
LOG_FILE="${LOG_FILE:-/root/adeptpro-runtime-state.log}"
UCI_CFG="${UCI_CFG:-podkop}"
WAIT_ATTEMPTS="${WAIT_ATTEMPTS:-60}"
WAIT_SECONDS="${WAIT_SECONDS:-2}"

log() {
  line="$1"
  printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$line" >> "$LOG_FILE"
  logger -t adeptpro-runtime-state "$line" 2>/dev/null || true
}

if [ ! -f "$PENDING_MARKER" ]; then
  log 'RUNTIME_PENDING_FOUND=NO'
  exit 0
fi

log 'RUNTIME_PENDING_FOUND=YES'
expected_hash="$(sed -n 's/^CONFIG_HASH=//p' "$PENDING_MARKER" | sed -n '1p')"
case "$expected_hash" in
  ''|*[!0-9a-fA-F]*) log 'WARNING=INVALID_OR_MISSING_CONFIG_HASH'; exit 1 ;;
esac

attempt=0
singbox_running=NO
global_check_ok=NO
while [ "$attempt" -lt "$WAIT_ATTEMPTS" ]; do
  if pgrep -x sing-box >/dev/null 2>&1; then
    singbox_running=YES
  fi
  if command -v podkop >/dev/null 2>&1 && podkop global_check >/dev/null 2>&1; then
    global_check_ok=YES
  fi
  if [ "$singbox_running" = YES ] && [ "$global_check_ok" = YES ]; then
    break
  fi
  attempt=$((attempt + 1))
  [ "$attempt" -lt "$WAIT_ATTEMPTS" ] && sleep "$WAIT_SECONDS"
done

log "SINGBOX_RUNNING=$singbox_running"
log "PODKOP_GLOBAL_CHECK=$global_check_ok"
current_state="$(uci -q show "$UCI_CFG" 2>/dev/null || true)"
if [ -z "$current_state" ]; then
  current_hash=''
  hash_match=NO
  log 'WARNING=UCI_CONFIG_HASH_UNAVAILABLE'
else
  current_hash="$(printf '%s\n' "$current_state" | sha256sum | awk '{print $1}')"
fi
if [ -n "$current_hash" ] && [ "$current_hash" = "$expected_hash" ]; then
  hash_match=YES
else
  hash_match=NO
fi
log "CONFIG_HASH_MATCH=$hash_match"

if [ "$singbox_running" = YES ] && [ "$global_check_ok" = YES ] && [ "$hash_match" = YES ]; then
  mkdir -p "$(dirname "$LAST_APPLIED_MARKER")"
  mv -f "$PENDING_MARKER" "$LAST_APPLIED_MARKER"
  log 'RUNTIME_RELOAD_APPLIED_AT_BOOT=YES'
  exit 0
fi

log 'RUNTIME_RELOAD_APPLIED_AT_BOOT=NO'
log 'WARNING=PENDING_RUNTIME_MARKER_PRESERVED'
exit 1
