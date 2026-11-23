#!/bin/sh
# Transactional replacement for installed .real.sh. Never edits cron.
set -u
DRY_RUN=0
case "${1:-}" in '') ;; --dry-run) DRY_RUN=1;; *) echo 'Usage: update-podkop-from-remnawave.sh [--dry-run]'; exit 2;; esac
[ -r "${GUARD_LIB:-/usr/lib/podkop-failover.sh}" ] || {
    echo 'Updater unavailable: shared health library missing; existing keys unchanged' >&2
    exit 78
}
. "${GUARD_LIB:-/usr/lib/podkop-failover.sh}"
guard_setup
mode=${UPDATER_MODE:-auto}
if [ "$mode" = auto ]; then
    if [ "$(uget "$CFG" podkop.settings.dont_touch_dhcp 2>/dev/null)" = 0 ]; then mode=native; else mode=guard; fi
fi
case "$mode" in
native)
    . "${NATIVE_LIB:-/usr/lib/podkop-native-update.sh}"
    native_setup
    ;;
guard) ;;
*) echo 'Update rejected: unsupported ownership mode' >&2; exit 1;;
esac
exec 8>"$R/var/lock/podkop-subscription.lock"
flock -n 8 || exit 75
if [ "$mode" = native ] && [ -f "$NDATA/pending" ]; then
    [ "$DRY_RUN" != 1 ] || { echo 'Dry-run rejected: native recovery pending' >&2; exit 1; }
    lock_control || exit 75
    native_restore || exit 1
    # A recovered interrupted transaction is a complete operation, never fetch
    # and activate another subscription in the same run.
    exit 0
fi
work=$(mktemp -d "$CFG/.subscription.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$work/.uci"
die() {
    [ "$DRY_RUN" = 1 ] || event "$1"
    printf '%s\n' "$1" >&2
    exit 1
}
if [ -f "$DATA/transaction/pending" ]; then
    die 'Update blocked: unfinished transaction; guard recovery required'
fi
conf=${CONF:-$R/etc/podkop-remnawave/subscription.conf}
# Read a literal assignment, never execute subscription.conf.
sub_url=$(sed -n "s/^[[:space:]]*SUB_URL='\([^']*\)'[[:space:]]*$/\1/p" "$conf" 2>/dev/null)
[ -n "$sub_url" ] || die 'Update rejected: missing literal subscription URL'
case "$sub_url" in https://*) ;; *) die 'Update rejected: HTTPS subscription required';; esac
case "$sub_url" in *'"'*|*'\'*|*'
'*) die 'Update rejected: invalid subscription URL';; esac
printf 'url = "%s"\n' "$sub_url" > "$work/curl.conf"
if ! curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 8 --max-time 25 \
    --max-filesize 1048576 --config "$work/curl.conf" -o "$work/body" 2>/dev/null; then
    die 'Update rejected: subscription download failed'
fi
[ -s "$work/body" ] || die 'Update rejected: empty subscription'
if grep -Eq '^(vless|ss|trojan|hysteria2|hy2)://' "$work/body"; then
    cp "$work/body" "$work/decoded"
elif ! base64 -d "$work/body" > "$work/decoded" 2>/dev/null; then
    die 'Update rejected: invalid subscription encoding'
fi
tr -d '\r' < "$work/decoded" | sed '/^[[:space:]]*$/d' > "$work/links"
[ -s "$work/links" ] || die 'Update rejected: no supported links'
[ "$(wc -l < "$work/links")" -le 128 ] || die 'Update rejected: too many links'
if ! awk 'length($0)>4096 {exit 1}' "$work/links"; then die 'Update rejected: oversized link'; fi
if grep -Ev '^(vless|ss|trojan|hysteria2|hy2)://[^[:space:]]+$' "$work/links" >/dev/null; then
    die 'Update rejected: unexpected subscription structure'
fi
if [ -n "$(uci -c "$CFG" -q changes podkop 2>/dev/null)" ] ||
   [ -n "$(uci -c "$CFG" -q changes dhcp 2>/dev/null)" ]; then
    die 'Update rejected: pending UCI changes'
fi
cp -p "$CFG/podkop" "$work/podkop" || die 'Update rejected: cannot stage config'
original_hash=$(sha256sum "$work/podkop" | awk '{print $1}')
for section in $REQUIRED_SECTIONS; do
    case "$section" in main|USA) ;; *) die 'Update rejected: unsupported section mapping';; esac
    : > "$work/$section.new"
done
while IFS= read -r link; do
    section=main
    if printf '%s\n' "$link" | grep -Eiq '@us\.adeptpro\.online:443([/?#]|$)|#(us|usa)([-_%]|$)|#us-direct-reality'; then section=USA; fi
    case "$link" in
        vless://*security=reality*)
            case "$link" in *'spx='*) ;; *'#'*) link=$(printf '%s' "$link" | sed 's/#/\&spx=%2F#/');; esac ;;
    esac
    case "$link" in *-rwsub|*'#rwsub') ;; *'#'*) link="$link-rwsub";; *) link="$link#rwsub";; esac
    printf '%s\n' "$link" >> "$work/$section.new"
done < "$work/links"
for section in $REQUIRED_SECTIONS; do
    [ -s "$work/$section.new" ] || die 'Update rejected: required subscription section empty'
    cp "$work/$section.new" "$work/$section.managed" || die 'Update rejected: ownership staging failed'
    uci -c "$work" -t "$work/.uci" -q show "podkop.$section" >/dev/null 2>&1 || die 'Update rejected: required section missing'
    old=$(uget "$work" "podkop.$section.urltest_proxy_links" 2>/dev/null || true)
    if [ "$mode" = native ]; then
        # An identical pre-existing manual link must never be claimed as managed.
        printf '%s\n' "$old" | tr ' ' '\n' > "$work/$section.old"
        native_stage_ownership "$work/$section.new" "$work/$section.old" "$NDATA/managed/$section" "$work/$section.managed" || die 'Update rejected: ownership staging failed'
    fi
    printf '%s\n' "$old" | tr ' ' '\n' | while IFS= read -r link; do
        [ -n "$link" ] || continue
        if [ "$mode" = native ]; then
            # On first use preserve ALL existing links, including manually
            # labelled rwsub. Only this updater's exact previous snapshot owns links.
            if [ -f "$NDATA/managed/$section" ] && grep -Fxq -- "$link" "$NDATA/managed/$section"; then continue; fi
        else
            case "$link" in *-rwsub|*'#rwsub') continue;; esac
        fi
        printf '%s\n' "$link"
    done >> "$work/$section.new"
    awk '!seen[$0]++' "$work/$section.new" > "$work/$section.final"
    uci -c "$work" -t "$work/.uci" -q delete "podkop.$section.urltest_proxy_links" || true
    while IFS= read -r link; do
        case "$link" in *"'"*|*'"'*|*'\'*) die 'Update rejected: unsafe link encoding';; esac
        uci -c "$work" -t "$work/.uci" add_list "podkop.$section.urltest_proxy_links=$link" >/dev/null 2>&1 || die 'Update rejected: candidate UCI error'
    done < "$work/$section.final"
done
uci -c "$work" -t "$work/.uci" commit podkop >/dev/null 2>&1 || die 'Update rejected: candidate commit failed'
validate_sections "$work" || die 'Update rejected: invalid section configuration'
if [ "$DRY_RUN" = 1 ]; then
    make_probe_config "$work" "$work/probe.json" >/dev/null 2>&1 || die 'Dry-run rejected: sing-box config invalid'
    echo 'Dry-run OK: nonempty sections, manual links preserved, sing-box check passed'
    exit 0
fi
shadow_health "$work" || die 'Update rejected: candidate WAN or required VPN HTTP probes failed'
uci -c "$CFG" -q show podkop > "$work/current.state"
uci -c "$work" -t "$work/.uci" -q show podkop > "$work/candidate.state"
if cmp -s "$work/current.state" "$work/candidate.state"; then
    event 'Subscription unchanged: runtime untouched'
    exit 0
fi
if [ "$mode" = native ]; then
    native_apply || die 'Native update rejected or rolled back; check pending state'
    exit 0
fi
[ -f "$DATA/normal-dns/dhcp" ] || die 'Update rejected: run approved guard prepare first'
lock_control || exit 75
[ "$original_hash" = "$(sha256sum "$CFG/podkop" | awk '{print $1}')" ] || die 'Update rejected: configuration changed concurrently'
[ -z "$(uci -c "$CFG" -q changes podkop 2>/dev/null)" ] &&
[ -z "$(uci -c "$CFG" -q changes dhcp 2>/dev/null)" ] || die 'Update rejected: pending UCI changes after preflight'
backup_transaction || die 'Update rejected: backup failed'
if ! fail_open; then
    recover_transaction || true
    die 'Update aborted: could not establish DIRECT safely'
fi
if ! atomic_copy "$work/podkop" "$CFG/podkop"; then
    recover_transaction || true
    die 'Update aborted: atomic config replacement failed'
fi
if [ -f "$DATA/manual-direct" ]; then
    rm -f "$DATA/transaction/pending"
    event 'Subscription committed: manual DIRECT preserved; candidate HTTP probes passed'
    exit 0
fi
if activate_normal; then
    rm -f "$DATA/transaction/pending"
    event 'Subscription committed: main and USA HTTP probes passed'
    exit 0
fi
recover_transaction || die 'CRITICAL: rollback incomplete; manual console required'
die 'Update rolled back: previous keys retained; DIRECT until verified recovery'
