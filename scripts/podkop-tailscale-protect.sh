#!/bin/sh
set -eu

NFT_TABLE="tailscale_force443"
NFT_CHAIN="output"
NFT_COMMENT="temporary-force-tailscale-controlplane-443"

log() {
  echo "[podkop-tailscale-protect] $*"
}

default_route="$(ip route 2>/dev/null | awk '/^default / { print; exit }')"
WAN_GW="$(printf '%s\n' "$default_route" | awk '{ for (i=1; i<=NF; i++) if ($i == "via") { print $(i+1); exit } }')"
WAN_DEV="$(printf '%s\n' "$default_route" | awk '{ for (i=1; i<=NF; i++) if ($i == "dev") { print $(i+1); exit } }')"

add_route_via_wan() {
  dst="$1"

  if [ -z "$WAN_GW" ] || [ -z "$WAN_DEV" ]; then
    log "default route gateway/device not found; cannot add route for $dst."
    return 0
  fi

  ip -4 route replace "$dst" via "$WAN_GW" dev "$WAN_DEV" onlink table podkop 2>/dev/null || true
}

add_route_dev() {
  dst="$1"
  dev="$2"

  if ! ip link show "$dev" >/dev/null 2>&1; then
    log "$dev not found; skipping route $dst."
    return 0
  fi

  ip -4 route replace "$dst" dev "$dev" table podkop 2>/dev/null || true
}

add_resolved_host_routes() {
  host="$1"

  if ! command -v nslookup >/dev/null 2>&1; then
    return 0
  fi

  nslookup "$host" 2>/dev/null \
    | awk '/^Address[[:space:]]+[0-9]+:/ { print $3 } /^Address:[[:space:]]*[0-9]+\./ { print $2 }' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
    | while IFS= read -r ipaddr; do
        add_route_via_wan "$ipaddr/32"
      done
}

configure_nft_force443() {
  if ! command -v nft >/dev/null 2>&1; then
    log "nft command not found; skipping force443 rule."
    return 0
  fi

  nft add table inet "$NFT_TABLE" 2>/dev/null || true
  nft "add chain inet $NFT_TABLE $NFT_CHAIN { type filter hook output priority -40; policy accept; }" 2>/dev/null || true

  if nft list table inet "$NFT_TABLE" 2>/dev/null | grep -Fq "$NFT_COMMENT"; then
    log "force443 nft rule already present."
    return 0
  fi

  nft add rule inet "$NFT_TABLE" "$NFT_CHAIN" ip daddr 192.200.0.0/24 tcp dport 80 counter reject with tcp reset comment "$NFT_COMMENT" 2>/dev/null || \
    log "failed to add force443 nft rule."
}

if ! command -v ip >/dev/null 2>&1; then
  log "ip command not found; skipping route protection."
else
  if [ -n "$WAN_GW" ] && [ -n "$WAN_DEV" ]; then
    ip -4 route replace 192.200.0.0/24 via "$WAN_GW" dev "$WAN_DEV" onlink table podkop 2>/dev/null || true
    ip -4 route replace 192.73.242.28/32 via "$WAN_GW" dev "$WAN_DEV" onlink table podkop 2>/dev/null || true
  else
    log "default route gateway/device not found; cannot add Tailscale controlplane WAN routes."
  fi
  add_resolved_host_routes "controlplane.tailscale.com"
  add_resolved_host_routes "login.tailscale.com"
  if ip link show tailscale0 >/dev/null 2>&1; then
    ip -4 route replace 100.100.100.100/32 dev tailscale0 table podkop 2>/dev/null || true
    ip -4 route replace 100.64.0.0/10 dev tailscale0 table podkop 2>/dev/null || true
  else
    log "tailscale0 not found; skipping Tailnet routes."
  fi
fi

configure_nft_force443
log "protection applied."
exit 0
