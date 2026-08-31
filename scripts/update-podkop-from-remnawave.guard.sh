#!/bin/sh
set -eu

REAL_UPDATER='/usr/bin/update-podkop-from-remnawave.real.sh'
GUARD_BIN='/usr/bin/podkop-all-lists-guard.sh'

ensure_guard_cron() {
  command -v crontab >/dev/null 2>&1 || return 0
  (
    crontab -l 2>/dev/null | grep -v 'podkop-all-lists-guard.sh' || true
    echo '*/2 * * * * /usr/bin/podkop-all-lists-guard.sh --apply >/tmp/podkop-all-lists-guard-apply.log 2>&1'
    echo '17 */6 * * * /usr/bin/podkop-all-lists-guard.sh --refresh >/tmp/podkop-all-lists-guard-refresh.log 2>&1'
  ) | crontab -
}

[ -x "$REAL_UPDATER" ] || {
  echo "[SAFE-PODKOP-GUARD][ERROR] Missing real updater: $REAL_UPDATER"
  exit 31
}

[ -x "$GUARD_BIN" ] || {
  echo "[SAFE-PODKOP-GUARD][ERROR] Missing subnet guard: $GUARD_BIN"
  exit 32
}

echo "[SAFE-PODKOP-GUARD] Ensuring guard cron before update..."
ensure_guard_cron

echo "[SAFE-PODKOP-GUARD] Prechecking Podkop subnet lists before Podkop restart..."
if ! "$GUARD_BIN" --precheck; then
  echo "[SAFE-PODKOP-GUARD][ERROR] Podkop subnet lists are not downloadable now."
  echo "[SAFE-PODKOP-GUARD][ERROR] Skip RemnaWave outbound update to protect live routing."
  "$GUARD_BIN" --apply || true
  ensure_guard_cron
  exit 30
fi

echo "[SAFE-PODKOP-GUARD] Lists OK. Running real RemnaWave updater..."
set +e
"$REAL_UPDATER"
rc="$?"
set -e

echo "[SAFE-PODKOP-GUARD] Re-applying cached subnet lists after updater..."
"$GUARD_BIN" --apply || true
ensure_guard_cron

echo "[SAFE-PODKOP-GUARD] Done. Real updater RC=$rc"
exit "$rc"
