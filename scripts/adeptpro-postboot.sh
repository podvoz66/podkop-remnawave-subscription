#!/bin/sh
set -eu

LOG='/root/adeptpro-postboot.log'
MAX_NETWORK_ATTEMPTS="${MAX_NETWORK_ATTEMPTS:-24}"
MAX_PACKAGE_ATTEMPTS="${MAX_PACKAGE_ATTEMPTS:-3}"
PACKAGE_MANAGER=''
OPENWRT_MAJOR_MINOR=''

log() {
  printf '%s %s\n' "$(date -Iseconds 2>/dev/null || date)" "$*" >> "$LOG"
}

network_ready() {
  if command -v ubus >/dev/null 2>&1; then
    ubus call network.interface.wan status 2>/dev/null | grep -q '"up"[[:space:]]*:[[:space:]]*true' && return 0
  fi
  ip route 2>/dev/null | grep -q '^default ' && return 0
  return 1
}

detect_package_manager() {
  release="$(sed -n "s/^DISTRIB_RELEASE=['\"]\([^'\"]*\)['\"]$/\1/p" /etc/openwrt_release 2>/dev/null | head -n 1)"
  OPENWRT_MAJOR_MINOR="$(printf '%s' "$release" | awk -F. 'NF >= 2 {print $1 "." $2}')"
  if command -v apk >/dev/null 2>&1; then
    PACKAGE_MANAGER='apk'
  elif command -v opkg >/dev/null 2>&1; then
    PACKAGE_MANAGER='opkg'
  else
    log 'POSTBOOT_TTYD=FAIL reason=unsupported-package-manager'
    exit 1
  fi
  case "$OPENWRT_MAJOR_MINOR:$PACKAGE_MANAGER" in
    24.10:opkg|25.12:apk) return 0 ;;
    *)
      major="$(printf '%s' "$OPENWRT_MAJOR_MINOR" | cut -d. -f1)"
      minor="$(printf '%s' "$OPENWRT_MAJOR_MINOR" | cut -d. -f2)"
      case "$major" in ''|*[!0-9]*) log 'POSTBOOT_TTYD=FAIL reason=unreadable-release'; exit 1 ;; esac
      case "$minor" in ''|*[!0-9]*) log 'POSTBOOT_TTYD=FAIL reason=unreadable-release'; exit 1 ;; esac
      if [ "$PACKAGE_MANAGER" = 'apk' ] && [ "${major:-0}" -ge 25 ] && \
         { [ "$major" -gt 25 ] || [ "${minor:-0}" -ge 12 ]; }; then
        return 0
      fi
      log "POSTBOOT_TTYD=FAIL reason=package-manager-release-mismatch release=$OPENWRT_MAJOR_MINOR manager=$PACKAGE_MANAGER"
      exit 1
      ;;
  esac
}

pkg_update() {
  if [ "$PACKAGE_MANAGER" = 'apk' ]; then
    apk update
  else
    opkg update
  fi
}

pkg_install() {
  if [ "$PACKAGE_MANAGER" = 'apk' ]; then
    apk add ttyd luci-app-ttyd
  else
    opkg install ttyd luci-app-ttyd
  fi
}

detect_package_manager

attempt=1
while [ "$attempt" -le "$MAX_NETWORK_ATTEMPTS" ]; do
  network_ready && break
  log "POSTBOOT_NETWORK=WAIT attempt=$attempt"
  sleep 5
  attempt=$((attempt + 1))
done

if ! network_ready; then
  log 'POSTBOOT_TTYD=FAIL reason=network-timeout'
  exit 1
fi

attempt=1
while [ "$attempt" -le "$MAX_PACKAGE_ATTEMPTS" ]; do
  if pkg_update >> "$LOG" 2>&1 && pkg_install >> "$LOG" 2>&1; then
    if [ -x /etc/init.d/ttyd ] && \
       /etc/init.d/ttyd enable >> "$LOG" 2>&1 && \
       /etc/init.d/ttyd start >> "$LOG" 2>&1; then
      log 'POSTBOOT_TTYD=PASS'
      /etc/init.d/adeptpro-postboot disable >> "$LOG" 2>&1 || true
      exit 0
    fi
  fi
  log "POSTBOOT_TTYD=RETRY attempt=$attempt"
  attempt=$((attempt + 1))
  sleep 10
done

log 'POSTBOOT_TTYD=FAIL reason=package-install'
exit 1
