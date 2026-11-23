#!/bin/sh
# Offline guest-only installer. Dependencies must first be delivered from LAB204.
set -eu
S=/root/r12-engine-baseline
P=/tmp/r12-offline
[ "$(id -u)" = 0 ]
[ "$(cat /sys/class/net/eth0/address)" = 02:52:12:02:03:01 ]
[ "$(cat /sys/class/net/eth1/address)" = 02:52:12:02:03:02 ]
[ -z "$(ip -4 route show default)" ]
[ "$(apk --print-arch)" = x86_64 ]
sha256sum -c "$S/SHA256SUMS" >/dev/null
apk info -v 2>/dev/null | sort > "$S/packages.pre-install"
cmp "$S/packages.before" "$S/packages.pre-install"
[ "$(df -k / | awk 'NR==2 {print $4}')" -gt 50000 ]
printf '%s  %s\n' \
 c72c91a0567a6243c55bef20b4990a521461f9740c5219d2a35b51f6cc2cbb2a "$P/engine.apk" \
 a444a784a7dc22b2ba17336b773f75b27861daf3fb358fea21b31935a975318e "$P/podkop.apk" | sha256sum -c -
(cd "$P" && sha256sum -c SHA256SUMS.txt >/dev/null)
dependencies='libatomic1 libnghttp2-14 libopenssl3 liburcu libuv1 bind-libs bind-dig coreutils coreutils-base64 libcurl4 curl jq kmod-nf-tproxy kmod-nft-tproxy'
# OpenWrt signs repository ADB indexes, not each dependency APK. Native fetch
# authenticates the exact package against that trusted index; wrong valid APK was
# tested and rejected with ADB integrity error. Never allow-untrusted for deps.
for index in base packages target kmods; do apk verify --no-network "$P/$index.adb"; done
mkdir -p "$P/verified"
apk --no-network --repositories-file "$P/repositories" fetch --output "$P/verified" $dependencies > "$S/dependency-auth.log" 2>&1
for package in $dependencies; do
    set -- "$P/$package-"*.apk
    [ "$#" = 1 ] && [ -f "$1" ]
    cmp "$1" "$P/verified/${1##*/}"
done
set -- "$P"/*.apk
[ "$#" = 16 ]
apk --no-network --repositories-file "$P/repositories" add --simulate $dependencies > "$S/install-plan.log" 2>&1
if grep -Eq 'Upgrading|Downgrading|Replacing|Reinstalling|Purging' "$S/install-plan.log"; then
    echo STOP_UNEXPECTED_BASELINE_PACKAGE_CHANGE; exit 1
fi
printf '%s\n' podkop podkop-engine $dependencies > "$S/transaction-new.names"
sh "$S/rollback.sh" check
if ! apk --no-network --repositories-file "$P/repositories" add $dependencies > "$S/install.log" 2>&1; then
    echo INSTALL_FAILED_ATTEMPTING_GUEST_ROLLBACK
    sh "$S/rollback.sh" apply
    exit 1
fi
if ! apk --no-network --repositories-file /dev/null add --allow-untrusted "$P/engine.apk" "$P/podkop.apk" >> "$S/install.log" 2>&1; then
    echo RELEASE_INSTALL_FAILED_ATTEMPTING_GUEST_ROLLBACK
    sh "$S/rollback.sh" apply
    exit 1
fi
sing-box version
apk info -v 2>/dev/null | sort > "$S/packages.installed"
echo PACKAGES_INSTALLED_RUNTIME_NOT_YET_ACCEPTED
