# Podkop Remnawave Subscription Updater

OpenWrt helper for importing a Remnawave router subscription into Podkop URLTest sections.

It downloads a Remnawave subscription, extracts supported proxy links, normalizes VLESS REALITY links for Podkop/sing-box by adding `spx=%2F` when missing, and writes links into separate Podkop sections.

Supported schemes:

```text
vless://
ss://
trojan://
hysteria2://
hy2://
```

- `main`: all non-US supported proxy links
- `USA`: only US supported proxy links

The script then restarts Podkop so sing-box regenerates its config.

## What problem it solves

Podkop can work with individual proxy links in `urltest_proxy_links`, but Remnawave provides a subscription. This script bridges the gap:

```text
Remnawave subscription
→ update-podkop-from-remnawave.sh
→ podkop.main.urltest_proxy_links = AUT/Oslo/PL
→ podkop.USA.urltest_proxy_links = US
→ Podkop restart
→ sing-box running
```

It also handles a practical compatibility issue where Remnawave VLESS REALITY links may omit `spx=%2F`, while AutoXray-style links include it.
Only VLESS REALITY links are normalized; Shadowsocks, Trojan, Hysteria2, and HY2 links are left unchanged.

## Files

```text
scripts/update-podkop-from-remnawave.sh   Main OpenWrt script
examples/subscription.conf.example        Example config file
```

## Quick Start

### 1. New OpenWrt Router

Use this option when Podkop is not installed yet or the router is being configured from scratch.

```sh
wget -O /tmp/install.sh \
  https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main/install.sh

chmod +x /tmp/install.sh

SUB_URL='https://sub.adeptpro.online/ROUTER_SUBSCRIPTION_TOKEN' \
  /tmp/install.sh
```

### 2. Existing OpenWrt Router

Use this option when Podkop is already installed and you only need to install or update the Remnawave updater and subscription URL.

```sh
wget -O /tmp/install-subscription-on-existing-podkop.sh \
  https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main/scripts/install-subscription-on-existing-podkop.sh

chmod +x /tmp/install-subscription-on-existing-podkop.sh

SUB_URL='https://sub.adeptpro.online/ROUTER_SUBSCRIPTION_TOKEN' \
  /tmp/install-subscription-on-existing-podkop.sh
```

Replace `ROUTER_SUBSCRIPTION_TOKEN` with the token for a dedicated Remnawave router user. Do not use a mobile subscription here and do not publish a real token to GitHub.

## Manual Installation on OpenWrt

```sh
mkdir -p /etc/podkop-remnawave
cp examples/subscription.conf.example /etc/podkop-remnawave/subscription.conf
chmod 600 /etc/podkop-remnawave/subscription.conf
```

Edit `/etc/podkop-remnawave/subscription.conf` and set your real Remnawave subscription URL:

```sh
SUB_URL='https://sub.example.com/YOUR_TOKEN'
```

Install the script:

```sh
cp scripts/update-podkop-from-remnawave.sh /usr/bin/update-podkop-from-remnawave.sh
chmod +x /usr/bin/update-podkop-from-remnawave.sh
```

Run once:

```sh
/usr/bin/update-podkop-from-remnawave.sh
```

Check result:

```sh
uci show podkop.main | grep 'urltest_proxy_links'
uci show podkop.USA | grep 'urltest_proxy_links'
pgrep -af sing-box
netstat -lntup 2>/dev/null | grep -E '1602|9090|sing|podkop' || true
```

## Cron auto-update

Every 4 hours:

```sh
grep -q 'update-podkop-from-remnawave.sh' /etc/crontabs/root || \
echo '0 */4 * * * /usr/bin/update-podkop-from-remnawave.sh >/tmp/podkop-sub-update.log 2>&1' >> /etc/crontabs/root

/etc/init.d/cron restart
```

Check log:

```sh
cat /tmp/podkop-sub-update.log
```

## Split-DNS for local Remnawave subscription frontends

If `sub.example.com` points to the router's own public WAN IP, the router itself may resolve the domain to its own `lo` address and receive 404 instead of reaching the LAN reverse proxy. In that case add a dnsmasq override:

```sh
uci add dhcp domain
uci set dhcp.@domain[-1].name='sub.example.com'
uci set dhcp.@domain[-1].ip='192.168.0.172'
uci commit dhcp
/etc/init.d/dnsmasq restart
```

Verify:

```sh
nslookup sub.example.com
```

## Security note

Do not commit real subscription tokens, UUIDs, private keys, or full proxy links to GitHub. Use `subscription.conf.example` as a template and keep `/etc/podkop-remnawave/subscription.conf` only on the router.

## Changelog

Updater now preserves and imports Trojan and Hysteria2 links from Remnawave/converter subscriptions.
