#!/bin/sh
# Shared transaction/health primitives. No actions at source time.
guard_setup() {
    umask 077
    R=${PODKOP_ROOT:-}
    DATA="$R/etc/podkop-failover"
    RUN="$R/tmp/podkop-failover"
    CFG="$R/etc/config"
    API=${API:-http://192.168.0.1:9090}
    REQUIRED_SECTIONS=${REQUIRED_SECTIONS:-'main USA'}
    PROBE_URLS=${PROBE_URLS:-'https://www.gstatic.com/generate_204 https://cp.cloudflare.com/generate_204'}
    DIRECT_DNS=${DIRECT_DNS:-'1.1.1.1 9.9.9.9'}
    WAN_DEVICE=${WAN_DEVICE:-eth1}
    PROBE_SECONDS=${PROBE_SECONDS:-4}
    PROBE_MARK=${PROBE_MARK:-2097152}
    COOLDOWN=${COOLDOWN:-300}
    INTERVAL=${INTERVAL:-30}
    mkdir -p "$RUN" "$R/var/lock"
    chmod 700 "$RUN"
    if [ "${DRY_RUN:-0}" != 1 ]; then mkdir -p "$DATA"; chmod 700 "$DATA"; fi
}
lock_control() {
    exec 9>"$R/var/lock/podkop-control.lock"
    flock -n 9
}
event() (
    exec 6>"$R/var/lock/podkop-events.lock"
    flock 6 || exit 1
    # Callers supply only fixed messages, never command errors or proxy data.
    if [ -f "$DATA/events.log" ] && [ "$(wc -c < "$DATA/events.log")" -ge 65536 ]; then
        mv -f "$DATA/events.log" "$DATA/events.log.1"
    fi
    printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" >> "$DATA/events.log"
    logger -t podkop-failover "$1" 2>/dev/null || true
)
atomic_copy() {
    # Same-directory rename. Never place credentials in a world-readable /tmp.
    ac_src=$1 ac_dst=$2
    ac_tmp=$(mktemp "${ac_dst}.XXXXXX") || return 1
    if cp -p "$ac_src" "$ac_tmp" && chmod 600 "$ac_tmp" && mv -f "$ac_tmp" "$ac_dst"; then
        return 0
    fi
    rm -f "$ac_tmp"
    return 1
}
uget() { uci -c "$1" -t "$1/.uci" -q get "$2"; }
validate_sections() {
    vs_dir=$1
    for vs_sec in $REQUIRED_SECTIONS; do
        # Fail closed for unsupported configuration styles; never rewrite them.
        [ "$(uget "$vs_dir" "podkop.$vs_sec.connection_type")" = proxy ] || return 1
        [ "$(uget "$vs_dir" "podkop.$vs_sec.proxy_config_type")" = urltest ] || return 1
        vs_links=$(uget "$vs_dir" "podkop.$vs_sec.urltest_proxy_links") || return 1
        [ -n "$vs_links" ] || return 1
        vs_count=0
        for vs_link in $vs_links; do
            vs_count=$((vs_count+1))
            [ "$vs_count" -le 128 ] && [ "${#vs_link}" -le 4096 ] || return 1
            printf '%s\n' "$vs_link" | grep -Eq '^(vless|ss|trojan|hysteria2|hy2)://[^[:space:]]+$' || return 1
            # Reject UCI quoting/control injection and placeholders.
            case "$vs_link" in *"'"*|*'"'*|*'\\'*|*'@0.0.0.0:1'*|*'00000000-0000-0000-0000-000000000000'*) return 1;; esac
        done
    done
}
make_probe_config() (
    # Only pure facade/manager functions, never source /usr/bin/podkop.
    # OpenWrt /lib/functions.sh and Podkop's facade legitimately read unset
    # optional variables (e.g. IPKG_INSTROOT). Confine their shell semantics
    # to this subshell; keep the updater's nounset protection in its caller.
    set +u
    mp_dir=$1 mp_out=$2
    . "${PODKOP_FUNCTIONS:-/lib/functions.sh}"
    . "${PODKOP_CONSTANTS:-/usr/lib/podkop/constants.sh}"
    . "${PODKOP_FACADE:-/usr/lib/podkop/sing_box_config_facade.sh}"
    log() { :; } # Parser errors must not disclose credentials.
    config='{"log":{"disabled":true},"dns":{"servers":[{"type":"udp","tag":"guard-dns","server":"1.1.1.1","detour":"direct-out"}],"final":"guard-dns"},"outbounds":[{"type":"direct","tag":"direct-out"}],"route":{"default_domain_resolver":"guard-dns","rules":[]},"inbounds":[{"type":"mixed","tag":"guard-direct","listen":"127.0.0.1","listen_port":17890}]}'
    config=$(printf '%s' "$config" | jq --argjson mark "$PROBE_MARK" '.route.default_mark=$mark | .outbounds[0].routing_mark=$mark | del(.dns.servers[0].detour) | .dns.servers[0].routing_mark=$mark') || exit 1
    config=$(printf '%s' "$config" | jq '.route.rules += [{inbound:["guard-direct"],action:"route",outbound:"direct-out"}]') || exit 1
    mp_port=17890
    for mp_sec in $REQUIRED_SECTIONS; do
        mp_tags='' mp_i=0
        mp_links=$(uget "$mp_dir" "podkop.$mp_sec.urltest_proxy_links") || exit 1
        for mp_link in $mp_links; do
            mp_i=$((mp_i+1))
            config=$(sing_box_cf_add_proxy_outbound "$config" "$mp_sec-$mp_i" "$mp_link" 0) || exit 1
            mp_tags="$mp_tags $mp_sec-$mp_i-out"
        done
        mp_port=$((mp_port+1))
        mp_url=${PROBE_URLS%% *}
        config=$(printf '%s' "$config" | jq --arg url "$mp_url" --arg sec "$mp_sec" --arg tags "$mp_tags" --argjson port "$mp_port" '
          .outbounds += [{type:"urltest",tag:($sec+"-probe"),outbounds:($tags|split(" ")|map(select(length>0))),url:$url,interval:"1m"}] |
          .inbounds += [{type:"mixed",tag:($sec+"-in"),listen:"127.0.0.1",listen_port:$port}] |
          .route.rules += [{inbound:[($sec+"-in")],action:"route",outbound:($sec+"-probe")}]') || exit 1
    done
    printf '%s\n' "$config" > "$mp_out"
    sing-box check -c "$mp_out" >/dev/null 2>&1
)
# OpenWrt's installed BusyBox has no timeout applet. Bound a direct child
# without packages; reap it and its watchdog, including interruption of probes.
bounded_run() (
    br_seconds=$1; shift
    "$@" &
    br_pid=$!
    (
        br_sleep=''
        trap '[ -z "$br_sleep" ] || kill "$br_sleep" 2>/dev/null; exit 0' TERM INT
        sleep "$br_seconds" & br_sleep=$!
        wait "$br_sleep" || exit 0
        kill -TERM "$br_pid" 2>/dev/null || exit 0
        sleep 1 & br_sleep=$!
        wait "$br_sleep" || exit 0
        kill -KILL "$br_pid" 2>/dev/null || true
    ) </dev/null >/dev/null 2>&1 9>&- 8>&- 7>&- 6>&- &
    br_timer=$! br_done=0
    trap '[ "$br_done" = 1 ] || kill -KILL "$br_pid" 2>/dev/null || :; kill "$br_timer" 2>/dev/null || :; wait "$br_pid" 2>/dev/null || :; wait "$br_timer" 2>/dev/null || :' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    wait "$br_pid"
    br_result=$? br_done=1
    exit "$br_result"
)
http_via() {
    hv_port=$1
    for hv_url in $PROBE_URLS; do
        hv_code=$(curl -s --noproxy '' --proxy "socks5h://127.0.0.1:$hv_port" --connect-timeout "$PROBE_SECONDS" --max-time "$PROBE_SECONDS" -o /dev/null -w '%{http_code}' "$hv_url" 2>/dev/null) || continue
        case "$hv_code" in 200|204) return 0;; esac
    done
    return 1
}
shadow_health() (
    exec 7>"$R/var/lock/podkop-probe.lock"
    flock -n 7 || exit 1
    sh_dir=$1
    validate_sections "$sh_dir" || exit 1
    sh_work=$(mktemp -d "$RUN/probe.XXXXXX") || exit 1
    sh_pid=''
    trap '[ -z "$sh_pid" ] || { kill "$sh_pid" 2>/dev/null || :; kill -KILL "$sh_pid" 2>/dev/null || :; wait "$sh_pid" 2>/dev/null || :; }; rm -rf "$sh_work"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    make_probe_config "$sh_dir" "$sh_work/config.json" >/dev/null 2>&1 || exit 1
    # HTTP probes have curl deadlines; own the real sing-box PID for cleanup.
    sing-box run -c "$sh_work/config.json" -D "$sh_work" >/dev/null 2>&1 9>&- &
    sh_pid=$!
    sleep 1
    kill -0 "$sh_pid" 2>/dev/null || exit 1
    if ! http_via 17890; then printf 'UNREACHABLE\n' > "$RUN/wan"; exit 1; fi
    printf 'OK\n' > "$RUN/wan"
    sh_port=17890
    for sh_sec in $REQUIRED_SECTIONS; do
        sh_port=$((sh_port+1))
        http_via "$sh_port" || exit 1
    done
)
api_health() {
    ah_tag=$1
    for ah_url in $PROBE_URLS; do
        ah_response=$(curl -s --get --connect-timeout 2 --max-time "$PROBE_SECONDS" \
          --data-urlencode "timeout=$((PROBE_SECONDS*1000-500))" --data-urlencode "url=$ah_url" \
          "$API/proxies/$ah_tag/delay" 2>/dev/null) || continue
        printf '%s' "$ah_response" | jq -e '.delay | type == "number" and . >= 0' >/dev/null 2>&1 && return 0
    done
    return 1
}
dns_health() {
    # Independent DNS and FakeIP path; no unbounded nslookup.
    bounded_run "$PROBE_SECONDS" nslookup example.com 127.0.0.1 >/dev/null 2>&1 || return 1
    bounded_run "$PROBE_SECONDS" nslookup youtube.com 127.0.0.42 2>/dev/null |
      grep -Eq '198\.(18|19)\.'
}
normal_health() {
    validate_sections "$CFG" || return 1
    pgrep -x sing-box >/dev/null || return 1
    nft list table inet PodkopTable 2>/dev/null | grep -q tproxy || return 1
    ip -4 rule show | grep -Eq '^105:.*fwmark 0x100000/0x100000 lookup podkop( |$)' || return 1
    sing-box check -c "$R/etc/sing-box/config.json" >/dev/null 2>&1 || return 1
    dns_health || return 1
    for nh_sec in $REQUIRED_SECTIONS; do api_health "$nh_sec-out" || return 1; done
}
wan_health() {
    # direct-out is explicit; do not infer WAN health from a default curl/ping.
    api_health direct-out
}
direct_wan_health() {
    # Only after interception is removed: independent of sing-box and VPN keys.
    for dw_url in $PROBE_URLS; do
        dw_code=$(curl -s --noproxy '*' --interface "$WAN_DEVICE" --connect-timeout "$PROBE_SECONDS" --max-time "$PROBE_SECONDS" -o /dev/null -w '%{http_code}' "$dw_url" 2>/dev/null) || continue
        case "$dw_code" in 200|204) return 0;; esac
    done
    return 1
}
snapshot_dns() {
    [ -f "$DATA/normal-dns/dhcp" ] && return 0
    mkdir -p "$DATA/normal-dns/.uci"
    atomic_copy "$CFG/dhcp" "$DATA/normal-dns/dhcp"
}
dns_mode() (
    dm_mode=$1
    dm_work=$(mktemp -d "$CFG/.guard-dns.XXXXXX") || exit 1
    trap 'rm -rf "$dm_work"' EXIT
    mkdir "$dm_work/.uci"
    cp -p "$CFG/dhcp" "$dm_work/dhcp" || exit 1
    for dm_key in server noresolv resolvfile cachesize; do
        uci -c "$dm_work" -t "$dm_work/.uci" -q delete "dhcp.@dnsmasq[0].$dm_key" 2>/dev/null || true
    done
    if [ "$dm_mode" = direct ]; then
        for dm_ip in $DIRECT_DNS; do
            printf '%s' "$dm_ip" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || exit 1
            uci -c "$dm_work" -t "$dm_work/.uci" add_list "dhcp.@dnsmasq[0].server=$dm_ip" || exit 1
        done
        uci -c "$dm_work" -t "$dm_work/.uci" set 'dhcp.@dnsmasq[0].noresolv=1' || exit 1
        uci -c "$dm_work" -t "$dm_work/.uci" set 'dhcp.@dnsmasq[0].cachesize=150' || exit 1
    else
        [ -f "$DATA/normal-dns/dhcp" ] || exit 1
        for dm_key in server noresolv resolvfile cachesize; do
            dm_value=$(uget "$DATA/normal-dns" "dhcp.@dnsmasq[0].$dm_key" 2>/dev/null) || continue
            if [ "$dm_key" = server ]; then
                for dm_server in $dm_value; do
                    uci -c "$dm_work" -t "$dm_work/.uci" add_list "dhcp.@dnsmasq[0].server=$dm_server" || exit 1
                done
            else
                uci -c "$dm_work" -t "$dm_work/.uci" set "dhcp.@dnsmasq[0].$dm_key=$dm_value" || exit 1
            fi
        done
    fi
    uci -c "$dm_work" -t "$dm_work/.uci" commit dhcp || exit 1
    cp -p "$CFG/dhcp" "$dm_work/previous" || exit 1
    if ! cmp -s "$dm_work/dhcp" "$CFG/dhcp" || [ -f "$DATA/dns-pending" ]; then
        dm_retry=$(cat "$RUN/dns-retry-at" 2>/dev/null || echo 0)
        [ "$(cut -d . -f 1 /proc/uptime)" -ge "$dm_retry" ] || exit 1
        # Journal the disk/runtime boundary so SIGKILL cannot suppress a retry.
        : > "$DATA/dns-pending" || exit 1
        atomic_copy "$dm_work/dhcp" "$CFG/dhcp" || exit 1
        if ! "$R/etc/init.d/dnsmasq" restart >/dev/null 2>&1; then
            # A failed reload must not make the next tick mistake disk for runtime.
            atomic_copy "$dm_work/previous" "$CFG/dhcp" || exit 1
            "$R/etc/init.d/dnsmasq" restart >/dev/null 2>&1 || true
            printf '%s\n' "$(($(cut -d . -f 1 /proc/uptime)+COOLDOWN))" > "$RUN/dns-retry-at"
            exit 1
        fi
        rm -f "$DATA/dns-pending" "$RUN/dns-retry-at"
    fi
)
block_fakeip() {
    nft list table inet podkop_failopen >/dev/null 2>&1 && return 0
    nft -f - <<'NFT'
table inet podkop_failopen {
 chain forward { type filter hook forward priority -5; policy accept; ip daddr 198.18.0.0/15 reject; }
 chain output { type filter hook output priority -5; policy accept; ip daddr 198.18.0.0/15 reject; }
}
NFT
}
remove_podkop_routes() {
    if nft list table inet PodkopTable >/dev/null 2>&1; then nft delete table inet PodkopTable || return 1; fi
    rr_i=0
    while ip -4 rule show | grep -Eq '^105:.*fwmark 0x100000/0x100000 lookup podkop( |$)'; do
        [ "$rr_i" -lt 16 ] || return 1
        ip -4 rule del priority 105 fwmark 0x100000/0x100000 table podkop || return 1
        rr_i=$((rr_i+1))
    done
    if ip -4 route show table podkop 2>/dev/null | grep -q '^local default dev lo'; then
        ip -4 route del local default dev lo table podkop || return 1
    fi
}
fail_open() {
    block_fakeip || return 1
    # Remove interception first, but retain sing-box until DIRECT DNS is installed.
    # Never stop the only DNS upstream after a failed dnsmasq transaction.
    remove_podkop_routes || return 1
    dns_mode direct || return 1
    bounded_run "$PROBE_SECONDS" nslookup example.com 127.0.0.1 >/dev/null 2>&1 || return 1
    if [ "$(uget "$CFG" podkop.settings.dont_touch_dhcp 2>/dev/null)" = 1 ]; then
        "$R/etc/init.d/podkop" stop >/dev/null 2>&1 || true
    else
        "$R/etc/init.d/sing-box" stop >/dev/null 2>&1 || true
    fi
    remove_podkop_routes || return 1
    printf 'FAIL_OPEN\n' > "$RUN/mode.new" && mv "$RUN/mode.new" "$RUN/mode" || return 1
    printf '0\n' > "$RUN/failures"
    printf '0\n' > "$RUN/successes"
    printf '%s\n' "$(cut -d . -f 1 /proc/uptime)" > "$RUN/last-transition"
    event 'FAIL_OPEN: traffic uses ISP address; cached FakeIP rejected'
}
activate_normal() {
    # Native start/stop must leave the guard in charge of DNS.
    [ "$(uget "$CFG" podkop.settings.dont_touch_dhcp 2>/dev/null)" = 1 ] || return 1
    # Called only after shadow_health; no blind attempts with broken keys.
    "$R/etc/init.d/podkop" start >/dev/null 2>&1 || return 1
    sleep 2
    normal_health || return 1
    dns_mode normal || return 1
    dns_health || return 1
    if nft list table inet podkop_failopen >/dev/null 2>&1; then nft delete table inet podkop_failopen || return 1; fi
    printf 'NORMAL\n' > "$RUN/mode.new" && mv "$RUN/mode.new" "$RUN/mode" || return 1
    printf '0\n' > "$RUN/failures"
    printf '0\n' > "$RUN/successes"
    printf '%s\n' "$(cut -d . -f 1 /proc/uptime)" > "$RUN/last-transition"
    event 'NORMAL: required VPN routes and DNS healthy'
}
guard_tick() {
    if [ -f "$DATA/transaction/pending" ]; then recover_transaction || return 1; fi
    gt_mode=$(cat "$RUN/mode" 2>/dev/null || echo UNKNOWN)
    if [ "$gt_mode" = UNKNOWN ]; then fail_open || return 1; gt_mode=FAIL_OPEN; fi
    if [ "$gt_mode" = NORMAL ]; then
        if wan_health; then printf 'OK\n' > "$RUN/wan"; else printf 'UNKNOWN\n' > "$RUN/wan"; fi
        if normal_health; then printf '0\n' > "$RUN/failures"; return 0; fi
        gt_n=$(cat "$RUN/failures" 2>/dev/null || echo 0); gt_n=$((gt_n+1))
        printf '%s\n' "$gt_n" > "$RUN/failures"
        if [ "$gt_n" -ge 3 ]; then fail_open || return 1; fi
        return 0
    fi
    # Reassert bypass in case an unrelated cron/start recreated interception.
    remove_podkop_routes || return 1
    dns_mode direct || return 1
    if ! bounded_run "$PROBE_SECONDS" nslookup example.com 127.0.0.1 >/dev/null 2>&1; then
        printf '0\n' > "$RUN/successes"
        if [ ! -f "$RUN/direct-dns-failed" ]; then event 'DIRECT DNS unavailable: inspect dnsmasq/WAN; no restart loop'; : > "$RUN/direct-dns-failed"; fi
        return 0
    fi
    rm -f "$RUN/direct-dns-failed"
    if direct_wan_health; then printf 'OK\n' > "$RUN/wan"; else
        printf 'UNREACHABLE\n' > "$RUN/wan"
        printf '0\n' > "$RUN/successes"
        return 0
    fi
    [ ! -f "$DATA/manual-direct" ] || return 0
    gt_last=$(cat "$RUN/last-transition" 2>/dev/null || echo 0)
    if [ -f "$RUN/last-transition" ]; then
        [ "$(($(cut -d . -f 1 /proc/uptime)-gt_last))" -ge "$COOLDOWN" ] || return 0
    fi
    if shadow_health "$CFG"; then
        gt_n=$(cat "$RUN/successes" 2>/dev/null || echo 0); gt_n=$((gt_n+1))
        printf '%s\n' "$gt_n" > "$RUN/successes"
        if [ "$gt_n" -ge 3 ]; then
            if ! activate_normal; then fail_open || return 1; fi
            printf '0\n' > "$RUN/successes"
        fi
    else
        printf '0\n' > "$RUN/successes"
    fi
}
backup_transaction() (
    bt_tmp=$(mktemp -d "$DATA/.transaction.XXXXXX") || return 1
    trap 'rm -rf "$bt_tmp"' EXIT
    cp -p "$CFG/podkop" "$bt_tmp/podkop" || return 1
    cp -p "$CFG/dhcp" "$bt_tmp/dhcp" || return 1
    cp -p "$R/etc/sing-box/config.json" "$bt_tmp/sing-box.json" || return 1
    : > "$bt_tmp/pending"
    if [ -d "$DATA/transaction" ]; then
        rm -rf "$DATA/previous-transaction"
        mv "$DATA/transaction" "$DATA/previous-transaction" || return 1
    fi
    mv "$bt_tmp" "$DATA/transaction" || return 1
    sync
)
recover_transaction() {
    [ -f "$DATA/transaction/pending" ] || return 0
    atomic_copy "$DATA/transaction/podkop" "$CFG/podkop" || return 1
    atomic_copy "$DATA/transaction/sing-box.json" "$R/etc/sing-box/config.json" || return 1
    fail_open || return 1
    rm -f "$DATA/transaction/pending"
    event 'Transaction rollback complete: previous config restored, DIRECT active'
}
