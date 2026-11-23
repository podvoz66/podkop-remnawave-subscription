#!/bin/sh
# Optional fixture acquisition: read binaries/libraries only, no remote writes.
set -eu
out=${1:?Usage: prepare-openwrt-runtime.sh LOCAL_DIRECTORY [SSH_ALIAS]}
alias=${2:-openwrt-202}
umask 077
mkdir -p "$out/bin"
out=$(cd "$out" && pwd)
for p in /usr/bin/sing-box /sbin/uci /bin/busybox /lib/ld-musl-x86_64.so.1 /lib/libgcc_s.so.1; do
    ssh -o BatchMode=yes "$alias" "cat $p" > "$out/$(basename "$p")"
done
for kind in libuci libubox; do
    p=$(ssh -o BatchMode=yes "$alias" "ls /lib/$kind.so.*" | head -n 1)
    case "$p" in /lib/libuci.so.[0-9]*|/lib/libubox.so.[0-9]*) ;; *) exit 1;; esac
    ssh -o BatchMode=yes "$alias" "cat $p" > "$out/$(basename "$p")"
done
for f in constants.sh helpers.sh sing_box_config_facade.sh sing_box_config_manager.sh; do
    ssh -o BatchMode=yes "$alias" "cat /usr/lib/podkop/$f" > "$out/$f"
done
ln -sf ld-musl-x86_64.so.1 "$out/libc.so"
chmod 700 "$out/ld-musl-x86_64.so.1"
for tool in uci sing-box; do
    printf '#!/bin/sh\nexec "%s/ld-musl-x86_64.so.1" --library-path "%s" "%s/%s" "$@"\n' "$out" "$out" "$out" "$tool" > "$out/bin/$tool"
    chmod 700 "$out/bin/$tool"
done
printf '#!/bin/sh\nexec "%s/ld-musl-x86_64.so.1" --library-path "%s" "%s/busybox" ash "$@"\n' "$out" "$out" "$out" > "$out/bin/ash"
chmod 700 "$out/bin/ash"
: > "$out/functions.sh"
sed "s#PODKOP_LIB=\"/usr/lib/podkop\"#PODKOP_LIB=\"$out\"#" "$out/sing_box_config_facade.sh" > "$out/facade-local.sh"
"$out/bin/sing-box" version | head -n 1 | grep -qx 'sing-box version 1.13.21'
grep -q '^PODKOP_VERSION="0.7.24"' "$out/constants.sh"
echo 'Local runtime prepared; remote configuration unchanged.'
