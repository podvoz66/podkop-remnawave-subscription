## Language / Язык

- [English](#english)
- [Русский](#русский)

# English

## Podkop Remnawave Subscription Updater

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

### One-command OpenWrt bootstrap

Use this option for one-command OpenWrt router setup on a new router or an existing OpenWrt router.

Bootstrap:

- detects OpenWrt version and router state;
- installs/checks required packages;
- configures Tailscale remote access;
- configures LuCI access through Tailscale;
- installs/checks Podkop;
- installs Remnawave subscription updater;
- imports or reuses saved Remnawave subscription;
- creates backups;
- does not open WAN ports.

```sh
wget -O /tmp/bootstrap.sh \
  https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main/scripts/bootstrap-openwrt-router.sh && \
chmod +x /tmp/bootstrap.sh && \
ROUTER_NAME='my-router' \
/tmp/bootstrap.sh
```

The script asks exactly two startup questions:

```text
Tailscale auth key / ключ удалённого доступа Tailscale
Press Enter to keep existing authorization or use browser login if needed.
Нажмите Enter, чтобы оставить текущую авторизацию или использовать вход через браузер при необходимости.
Enter Tailscale auth key / Введите Tailscale auth key:

Remnawave subscription URL / ссылка на подписку Remnawave
Press Enter to keep existing subscription or skip if none.
Нажмите Enter, чтобы оставить старую подписку или пропустить, если её ещё нет.
Enter subscription URL / Введите ссылку на подписку:
```

Leave the Tailscale auth key empty to keep the current Tailscale authorization if it already exists; otherwise Tailscale will use browser login. Leave the subscription URL empty to reuse the saved `/etc/podkop-remnawave/subscription.conf` URL if present; otherwise subscription import is skipped.

For fully non-interactive setup, pass values through the environment and set `INTERACTIVE=0`. Do not commit a real auth key or subscription URL:

```sh
INTERACTIVE=0 \
TAILSCALE_AUTHKEY='TS_AUTH_KEY_PLACEHOLDER' \
ROUTER_NAME='openwrt-router' \
SUB_URL='https://sub.adeptpro.online/ROUTER_SUBSCRIPTION_TOKEN' \
  /tmp/bootstrap-openwrt-router.sh
```

You can also run non-interactively without either value:

```sh
INTERACTIVE=0 \
ROUTER_NAME='openwrt-router' \
  /tmp/bootstrap-openwrt-router.sh
```

With `INTERACTIVE=0` and no `SUB_URL`, bootstrap reuses the saved subscription URL if one exists. With no `TAILSCALE_AUTHKEY`, it keeps existing Tailscale state or falls back to browser login.

Useful toggles:

```sh
INTERACTIVE=0             # do not ask startup questions
INSTALL_RU_LOCALE=0       # skip Russian LuCI locale packages
INSTALL_TTYD=0            # skip ttyd/luci-app-ttyd
INSTALL_PODKOP=0          # do not install Podkop if missing
ENABLE_LUCI_TAILSCALE=0   # do not change uhttpd rfc1918_filter
DRY_RUN=1                 # print intended actions
```

If `SUB_URL` is omitted and no saved subscription exists, bootstrap still configures the router and Tailscale, then skips subscription import with a warning.

Recovery for offline Tailscale:

```sh
pgrep -af sing-box || echo "NO sing-box process"
killall sing-box
/etc/init.d/tailscale restart
tailscale status
tailscale netcheck
```

Recovery for orphan sing-box before restarting Podkop:

```sh
/etc/init.d/podkop stop
killall sing-box
/etc/init.d/podkop start
```

Recovery for LuCI `Forbidden` over Tailscale:

```sh
uci set uhttpd.main.rfc1918_filter='0'
uci commit uhttpd
/etc/init.d/uhttpd restart
```

The bootstrap script never opens WAN ports. SSH and LuCI access are expected through the Tailscale IPv4 address.

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

## Remote access via Tailscale on OpenWrt

Install remote access without opening SSH, LuCI, or any other WAN ports:

```sh
wget -O /tmp/install-remote-access-tailscale.sh \
  https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main/scripts/install-remote-access-tailscale.sh

chmod +x /tmp/install-remote-access-tailscale.sh

TAILSCALE_HOSTNAME='openwrt-router' \
  /tmp/install-remote-access-tailscale.sh
```

For unattended setup, pass an auth key through the environment. Do not commit or paste a real key into GitHub:

```sh
TAILSCALE_AUTHKEY='TS_AUTH_KEY_PLACEHOLDER' \
TAILSCALE_HOSTNAME='openwrt-router' \
  /tmp/install-remote-access-tailscale.sh
```

If the router appears offline in Tailscale, check for an orphan sing-box process:

```sh
pgrep -af sing-box || echo "NO sing-box process"
```

Recovery:

```sh
killall sing-box
/etc/init.d/tailscale restart
tailscale status
tailscale ip -4
```

If LuCI over `http://100.x.x.x/` returns `Forbidden` with an RFC1918/public-address warning:

```sh
uci set uhttpd.main.rfc1918_filter='0'
uci commit uhttpd
/etc/init.d/uhttpd restart
```

The installer does not open WAN ports. Access is expected only through the Tailscale IPv4 address.

## Security note

Do not commit real subscription tokens, UUIDs, private keys, or full proxy links to GitHub. Use `subscription.conf.example` as a template and keep `/etc/podkop-remnawave/subscription.conf` only on the router.

## Changelog

Updater now preserves and imports Trojan and Hysteria2 links from Remnawave/converter subscriptions.

# Русский

## Podkop Remnawave Subscription Updater

Помощник для OpenWrt, который настраивает роутер для Podkop, Remnawave subscription и удалённого доступа через Tailscale.

### Быстрая установка OpenWrt router bootstrap

Используйте этот вариант для нового роутера или уже настроенного OpenWrt-роутера.

Bootstrap:

- определяет версию OpenWrt и состояние роутера;
- устанавливает/проверяет нужные пакеты;
- настраивает удалённый доступ через Tailscale;
- настраивает доступ к LuCI через Tailscale;
- устанавливает/проверяет Podkop;
- устанавливает Remnawave subscription updater;
- импортирует или переиспользует сохранённую Remnawave-подписку;
- создаёт backup;
- не открывает WAN-порты.

```sh
wget -O /tmp/bootstrap.sh \
  https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main/scripts/bootstrap-openwrt-router.sh && \
chmod +x /tmp/bootstrap.sh && \
ROUTER_NAME='my-router' \
/tmp/bootstrap.sh
```

Скрипт задаёт два вопроса:

```text
Tailscale auth key / ключ удалённого доступа Tailscale
Press Enter to keep existing authorization or use browser login if needed.
Нажмите Enter, чтобы оставить текущую авторизацию или использовать вход через браузер при необходимости.
Enter Tailscale auth key / Введите Tailscale auth key:

Remnawave subscription URL / ссылка на подписку Remnawave
Press Enter to keep existing subscription or skip if none.
Нажмите Enter, чтобы оставить старую подписку или пропустить, если её ещё нет.
Enter subscription URL / Введите ссылку на подписку:
```

Если нажать Enter на вопросе про Tailscale auth key, скрипт сохранит текущую авторизацию Tailscale, если она уже есть, или покажет browser login. Если нажать Enter на вопросе про subscription URL, скрипт использует сохранённую ссылку из `/etc/podkop-remnawave/subscription.conf`, если она есть, или пропустит импорт.

Полностью non-interactive запуск:

```sh
INTERACTIVE=0 \
TAILSCALE_AUTHKEY='TS_AUTH_KEY_PLACEHOLDER' \
ROUTER_NAME='my-router' \
SUB_URL='https://sub.adeptpro.online/ROUTER_SUBSCRIPTION_TOKEN' \
/tmp/bootstrap.sh
```

Безопасность:

- не добавляйте реальные subscription tokens, auth keys, UUID, private keys и полные proxy-ссылки в GitHub;
- не открывайте SSH или LuCI в WAN;
- используйте доступ к роутеру через Tailscale IPv4.
