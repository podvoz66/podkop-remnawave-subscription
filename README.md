## Language / Язык

* [English](#english)
* [Русский](#русский)

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

## Hysteria2 for router users

Router users use the normal public subscription URL:

```text
https://sub.adeptpro.online/ROUTER_SUBSCRIPTION_TOKEN
```

Hysteria2 is not added directly by the default Remnawave base64 generator. It is injected infrastructure-side by the transparent converter on `sub.adeptpro.online`. Therefore, the Remnawave panel or default preview may show fewer links and may not contain `hysteria2://`. This is expected.

A new router user receives one generated Stockholm Hysteria2 link automatically when:

1. the user belongs to `Routers-All-Reality-Prod`;
2. `/<token>/json` contains the `sthm-hysteria2-443` entry;
3. the public `/<token>` subscription is fetched through `sub.adeptpro.online`.

Manual per-token converter allowlist and nginx location edits are no longer required after Stage 7. The router-side updater must support `vless://`, `ss://`, `trojan://`, `hysteria2://`, and `hy2://`.

Validate the public subscription rather than the panel preview:

```sh
SUB_URL='https://sub.adeptpro.online/ROUTER_SUBSCRIPTION_TOKEN'

curl -fsSL "$SUB_URL" -o /tmp/router-sub.b64

base64 -d /tmp/router-sub.b64 2>/dev/null \
  | grep -Eo '^(vless|ss|trojan|hysteria2|hy2)://' \
  | sort | uniq -c
```

* `main`: all non-US supported proxy links
* `USA`: only US supported proxy links

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

* detects OpenWrt version and router state;
* installs/checks required packages;
* configures Tailscale remote access;
* configures LuCI access through Tailscale;
* installs/checks Podkop;
* installs Remnawave subscription updater;
* imports or reuses saved Remnawave subscription;
* creates backups;
* does not open WAN ports.

### Interactive launch

Use this variant if you want the script to ask for router name, Tailscale auth key, and Remnawave subscription URL.

```sh
wget -O /tmp/bootstrap.sh \
  https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main/scripts/bootstrap-openwrt-router.sh && \
chmod +x /tmp/bootstrap.sh && \
/tmp/bootstrap.sh
```

This variant will show:

```text
Enter Router/device name / Введите имя роутера:
```

### Launch with predefined router name

Use this variant if you want to pass the router name in advance. In this case, the `Enter Router/device name` prompt will not appear.

```sh
wget -O /tmp/bootstrap.sh \
  https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main/scripts/bootstrap-openwrt-router.sh && \
chmod +x /tmp/bootstrap.sh && \
ROUTER_NAME='my-router' \
/tmp/bootstrap.sh
```

The script asks three startup questions when values are not provided through environment variables:

```text
============================================================
[INPUT REQUIRED] Router/device name
[ТРЕБУЕТСЯ ВВОД] Имя роутера / устройства
------------------------------------------------------------
Example / пример:
  nanopi-r3s-home
  xiaomi-ax300t-flat
  openwrt-office-1

This name will be used as Tailscale hostname.
Это имя будет использовано как имя устройства в Tailscale.
============================================================
Enter Router/device name / Введите имя роутера:

Tailscale auth key / ключ удалённого доступа Tailscale
============================================================
[INPUT REQUIRED] Tailscale auth key
[ТРЕБУЕТСЯ ВВОД] Ключ авторизации Tailscale
------------------------------------------------------------
Example / пример:
  tskey-auth-xxxxxxxxxxxxxxxx

Leave empty to use browser login if auth key is not available.
Оставьте пустым, чтобы использовать вход через браузер, если ключа нет.

The key will not be printed in logs.
Ключ не будет выводиться в логах.
============================================================
Enter Tailscale auth key / Введите Tailscale auth key:

============================================================
Remnawave subscription URL / ссылка на подписку Remnawave
[INPUT REQUIRED] Remnawave subscription URL
[ТРЕБУЕТСЯ ВВОД] Ссылка на подписку Remnawave
------------------------------------------------------------
Example / пример:
  https://sub.example.com/token

Leave empty to keep existing subscription if already configured.
Оставьте пустым, чтобы оставить старую подписку, если она уже настроена.
============================================================
Enter Remnawave subscription URL / Введите ссылку на подписку Remnawave:
```

Router/device name is normalized to lowercase Tailscale-safe form, for example `NanoPi R3S Home` becomes `nanopi-r3s-home`. `TAILSCALE_HOSTNAME` can override only the Tailscale hostname. Use `SET_OPENWRT_HOSTNAME=0` if you do not want bootstrap to change the OpenWrt system hostname.

Leave the Tailscale auth key empty to keep the current Tailscale authorization if it already exists; otherwise Tailscale will use browser login. Leave the subscription URL empty to reuse the saved `/etc/podkop-remnawave/subscription.conf` URL if present; otherwise subscription import is skipped.

For fully non-interactive setup, pass values through the environment and set `INTERACTIVE=0`. Do not commit a real auth key or subscription URL:

```sh
INTERACTIVE=0 \
TAILSCALE_AUTHKEY='TS_AUTH_KEY_PLACEHOLDER' \
ROUTER_NAME='openwrt-router' \
SUB_URL='https://sub.adeptpro.online/ROUTER_SUBSCRIPTION_TOKEN' \
  /tmp/bootstrap.sh
```

To avoid changing the OpenWrt system hostname:

```sh
INTERACTIVE=0 \
TAILSCALE_AUTHKEY='TS_AUTH_KEY_PLACEHOLDER' \
ROUTER_NAME='openwrt-router' \
SET_OPENWRT_HOSTNAME=0 \
  /tmp/bootstrap.sh
```

You can also run non-interactively without either value:

```sh
INTERACTIVE=0 \
ROUTER_NAME='openwrt-router' \
  /tmp/bootstrap.sh
```

With `INTERACTIVE=0` and no `SUB_URL`, bootstrap reuses the saved subscription URL if one exists. With no `TAILSCALE_AUTHKEY`, it keeps existing Tailscale state or falls back to browser login.

Useful toggles:

```sh
INTERACTIVE=0             # do not ask startup questions
INSTALL_RU_LOCALE=0       # skip Russian LuCI locale packages
INSTALL_TTYD=0            # skip ttyd/luci-app-ttyd
INSTALL_PODKOP=0          # do not install Podkop if missing
UPDATE_PODKOP=0           # do not update already installed Podkop
ENABLE_LUCI_TAILSCALE=0   # do not configure direct LuCI/SSH access through Tailscale
DRY_RUN=1                 # print intended actions
```

If `SUB_URL` is omitted and no saved subscription exists, bootstrap still configures the router and Tailscale, then skips subscription import with a warning.

### Final Status, Logs, And Reboot

At the end of a successful bootstrap run, the script prints:

```text
[SUCCESS] Bootstrap completed successfully.
Router name:
Tailscale IP:
SSH command:
LuCI URL:
Podkop status:
Subscription import count:
Backup dir:
```

Bootstrap writes important status messages to:

```text
/root/podkop-bootstrap.log
```

A reboot is required after a full bootstrap. By default, `REBOOT_AFTER=1`, so the router reboots automatically after `REBOOT_DELAY` seconds. To disable automatic reboot:

```sh
REBOOT_AFTER=0 ROUTER_NAME='my-router' /tmp/bootstrap.sh
```

Then reboot manually:

```sh
sync && reboot
```

If bootstrap fails, automatic reboot is not performed. The script prints `[ERROR] Bootstrap failed.`, the backup directory, the log path, and the last 80 log lines.

If you run bootstrap from LuCI Terminal / ttyd, use:

```sh
INSTALL_TTYD=0 ROUTER_NAME='my-router' /tmp/bootstrap.sh
```

Installing or updating `ttyd` can interrupt the current web terminal session. With `INSTALL_TTYD=0`, the critical Tailscale, Podkop, and Remnawave steps can finish first.

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

## Direct LuCI and SSH access through Tailscale

Bootstrap and the remote-access installer configure direct access to the router itself from Tailnet:

```text
LuCI: http://ROUTER_TAILSCALE_IP/
SSH:  ssh root@ROUTER_TAILSCALE_IP
```

This is handled by:

```text
scripts/install-tailscale-direct-access.sh
```

It creates backups of `/etc/config/firewall` and `/etc/config/uhttpd`, enables autostart for `tailscale`, `dropbear`, and `uhttpd`, disables `uhttpd.main.rfc1918_filter`, and adds router-local input rules for Tailnet:

```text
Allow-SSH-from-Tailscale:  100.64.0.0/10 -> tcp/22
Allow-LuCI-from-Tailscale: 100.64.0.0/10 -> tcp/80,443
```

WAN ports are not opened. Port forwarding is not created.

To disable this behavior:

```sh
ENABLE_LUCI_TAILSCALE=0 ROUTER_NAME='my-router' /tmp/bootstrap.sh
```

Check from your laptop after bootstrap and reboot:

```powershell
& "C:\Program Files\Tailscale\tailscale.exe" ping ROUTER_TAILSCALE_IP
curl.exe -I http://ROUTER_TAILSCALE_IP
ssh root@ROUTER_TAILSCALE_IP
```

Immediately after reboot, `tailscale ping` may time out for a few seconds while OpenWrt starts the network and `tailscaled`. After `pong`, LuCI and SSH should answer directly through the Tailscale IP.

## Security note

Do not commit real subscription tokens, UUIDs, private keys, or full proxy links to GitHub. Use `subscription.conf.example` as a template and keep `/etc/podkop-remnawave/subscription.conf` only on the router.

## Changelog

Updater now preserves and imports Trojan and Hysteria2 links from Remnawave/converter subscriptions.


## Podkop install/update behavior

Bootstrap uses the official Podkop installer for both fresh install and update:

```sh
wget -O /tmp/podkop-install.sh https://raw.githubusercontent.com/itdoginfo/podkop/main/install.sh
sh /tmp/podkop-install.sh
```

Behavior:

- clean router without Podkop: `INSTALL_PODKOP=auto` or `INSTALL_PODKOP=1` installs Podkop through the official installer;
- router with existing Podkop: `UPDATE_PODKOP=1` updates Podkop through the official installer;
- router with existing Podkop where update is not wanted: `UPDATE_PODKOP=0` keeps the installed Podkop version;
- bootstrap does not run a full `opkg upgrade`.

The installer is executed in non-interactive mode and bootstrap continuously feeds `y` answers to installer prompts, including the Russian localization prompt. This preserves/installs Russian localization when the Podkop installer asks for it.

# Русский

## Podkop Remnawave Subscription Updater

Помощник для OpenWrt, который настраивает роутер для Podkop, Remnawave subscription и удалённого доступа через Tailscale.

## Hysteria2 для router users

Для router users используется обычная публичная subscription-ссылка:

```text
https://sub.adeptpro.online/ROUTER_SUBSCRIPTION_TOKEN
```

Для router users Hysteria2 добавляется не напрямую Remnawave default/base64 generator, а infrastructure-side transparent converter на `sub.adeptpro.online`.

Поэтому в Remnawave panel/default preview может быть видно меньше ссылок и может не быть `hysteria2://`. Это нормально.

Новый router user автоматически получает одну Stockholm Hysteria2-ссылку, если:

1. пользователь состоит в `Routers-All-Reality-Prod`;
2. `/<token>/json` содержит запись `sthm-hysteria2-443`;
3. публичная `/<token>` subscription загружается через `sub.adeptpro.online`.

После Stage 7 вручную добавлять token в converter allowlist и отдельный nginx location больше не требуется. Router-side updater должен поддерживать `vless://`, `ss://`, `trojan://`, `hysteria2://` и `hy2://`.

Контрольная проверка выполняется не по panel preview, а по публичной subscription-ссылке:

```sh
SUB_URL='https://sub.adeptpro.online/ROUTER_SUBSCRIPTION_TOKEN'

curl -fsSL "$SUB_URL" -o /tmp/router-sub.b64

base64 -d /tmp/router-sub.b64 2>/dev/null \
  | grep -Eo '^(vless|ss|trojan|hysteria2|hy2)://' \
  | sort | uniq -c
```

### Быстрая установка OpenWrt router bootstrap

Используйте этот вариант для нового роутера или уже настроенного OpenWrt-роутера.

Bootstrap:

* определяет версию OpenWrt и состояние роутера;
* устанавливает/проверяет нужные пакеты;
* настраивает удалённый доступ через Tailscale;
* настраивает доступ к LuCI через Tailscale;
* устанавливает/проверяет Podkop;
* устанавливает Remnawave subscription updater;
* импортирует или переиспользует сохранённую Remnawave-подписку;
* создаёт backup;
* не открывает WAN-порты.

### Интерактивный запуск

Используйте этот вариант, если хотите, чтобы скрипт сам спросил имя роутера, Tailscale auth key и ссылку Remnawave subscription.

```sh
wget -O /tmp/bootstrap.sh \
  https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main/scripts/bootstrap-openwrt-router.sh && \
chmod +x /tmp/bootstrap.sh && \
/tmp/bootstrap.sh
```

В этом варианте появится вопрос:

```text
Enter Router/device name / Введите имя роутера:
```

### Запуск с заранее заданным именем роутера

Используйте этот вариант, если имя роутера нужно передать заранее. В этом случае вопрос `Enter Router/device name` не появится.

```sh
wget -O /tmp/bootstrap.sh \
  https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main/scripts/bootstrap-openwrt-router.sh && \
chmod +x /tmp/bootstrap.sh && \
ROUTER_NAME='my-router' \
/tmp/bootstrap.sh
```

Скрипт задаёт три вопроса, если значения не переданы через переменные окружения:

```text
============================================================
[INPUT REQUIRED] Router/device name
[ТРЕБУЕТСЯ ВВОД] Имя роутера / устройства
------------------------------------------------------------
Example / пример:
  nanopi-r3s-home
  xiaomi-ax300t-flat
  openwrt-office-1

This name will be used as Tailscale hostname.
Это имя будет использовано как имя устройства в Tailscale.
============================================================
Enter Router/device name / Введите имя роутера:

============================================================
Tailscale auth key / ключ удалённого доступа Tailscale
[INPUT REQUIRED] Tailscale auth key
[ТРЕБУЕТСЯ ВВОД] Ключ авторизации Tailscale
------------------------------------------------------------
Example / пример:
  tskey-auth-xxxxxxxxxxxxxxxx

Leave empty to use browser login if auth key is not available.
Оставьте пустым, чтобы использовать вход через браузер, если ключа нет.

The key will not be printed in logs.
Ключ не будет выводиться в логах.
============================================================
Enter Tailscale auth key / Введите Tailscale auth key:

============================================================
Remnawave subscription URL / ссылка на подписку Remnawave
[INPUT REQUIRED] Remnawave subscription URL
[ТРЕБУЕТСЯ ВВОД] Ссылка на подписку Remnawave
------------------------------------------------------------
Example / пример:
  https://sub.example.com/token

Leave empty to keep existing subscription if already configured.
Оставьте пустым, чтобы оставить старую подписку, если она уже настроена.
============================================================
Enter Remnawave subscription URL / Введите ссылку на подписку Remnawave:
```

Имя роутера нормализуется в безопасный для Tailscale вид: `NanoPi R3S Home` станет `nanopi-r3s-home`. `TAILSCALE_HOSTNAME` может переопределить только имя в Tailscale. Используйте `SET_OPENWRT_HOSTNAME=0`, если не нужно менять hostname самой OpenWrt-системы.

Если нажать Enter на вопросе про Tailscale auth key, скрипт сохранит текущую авторизацию Tailscale, если она уже есть, или покажет browser login. Если нажать Enter на вопросе про subscription URL, скрипт использует сохранённую ссылку из `/etc/podkop-remnawave/subscription.conf`, если она есть, или пропустит импорт.

Полностью non-interactive запуск:

```sh
INTERACTIVE=0 \
TAILSCALE_AUTHKEY='TS_AUTH_KEY_PLACEHOLDER' \
ROUTER_NAME='my-router' \
SUB_URL='https://sub.adeptpro.online/ROUTER_SUBSCRIPTION_TOKEN' \
/tmp/bootstrap.sh
```

Без изменения hostname самой OpenWrt-системы:

```sh
INTERACTIVE=0 \
TAILSCALE_AUTHKEY='TS_AUTH_KEY_PLACEHOLDER' \
ROUTER_NAME='my-router' \
SET_OPENWRT_HOSTNAME=0 \
/tmp/bootstrap.sh
```

Можно также запустить non-interactive без этих значений:

```sh
INTERACTIVE=0 \
ROUTER_NAME='my-router' \
/tmp/bootstrap.sh
```

При `INTERACTIVE=0` без `SUB_URL` bootstrap использует сохранённую подписку, если она есть. Без `TAILSCALE_AUTHKEY` он сохраняет существующее состояние Tailscale или переходит к browser login.

Полезные переключатели:

```sh
INTERACTIVE=0             # не задавать вопросы при старте
INSTALL_RU_LOCALE=0       # не ставить русскую локализацию LuCI
INSTALL_TTYD=0            # не ставить ttyd/luci-app-ttyd
INSTALL_PODKOP=0          # не ставить Podkop, если он отсутствует
UPDATE_PODKOP=0           # не обновлять уже установленный Podkop
ENABLE_LUCI_TAILSCALE=0   # не настраивать прямой доступ LuCI/SSH через Tailscale
DRY_RUN=1                 # показать действия без применения
```

Если `SUB_URL` не задан и сохранённой подписки нет, bootstrap не падает: он настраивает роутер и Tailscale, а импорт подписки пропускает с предупреждением.

Безопасность:

* не добавляйте реальные subscription tokens, auth keys, UUID, private keys и полные proxy-ссылки в GitHub;
* не открывайте SSH или LuCI в WAN;
* используйте доступ к роутеру через Tailscale IPv4.

### Финальный статус и логи

При успешном завершении bootstrap выводит:

```text
[SUCCESS] Bootstrap completed successfully.
Router name:
Tailscale IP:
SSH command:
LuCI URL:
Podkop status:
Subscription import count:
Backup dir:
```

Важные сообщения пишутся в лог:

```text
/root/podkop-bootstrap.log
```

После полной установки требуется перезагрузка роутера. По умолчанию `REBOOT_AFTER=1`, поэтому роутер перезагружается автоматически через `REBOOT_DELAY` секунд. Если автоматическая перезагрузка не нужна:

```sh
REBOOT_AFTER=0 ROUTER_NAME='my-router' /tmp/bootstrap.sh
```

После этого перезагрузите вручную:

```sh
sync && reboot
```

Если bootstrap завершился с ошибкой, автоматическая перезагрузка не выполняется. Скрипт выводит `[ERROR] Bootstrap failed.`, backup directory, путь к логу и последние 80 строк лога.

Если запускаете bootstrap из LuCI Terminal / ttyd, используйте:

```sh
INSTALL_TTYD=0 ROUTER_NAME='my-router' /tmp/bootstrap.sh
```

Установка или обновление `ttyd` может оборвать текущую web-terminal-сессию. С `INSTALL_TTYD=0` критичные шаги Tailscale, Podkop и Remnawave успеют завершиться.

Восстановление, если роутер offline в Tailscale:

```sh
pgrep -af sing-box || echo "NO sing-box process"
killall sing-box
/etc/init.d/tailscale restart
tailscale status
tailscale netcheck
```

Восстановление orphan `sing-box` перед запуском Podkop:

```sh
/etc/init.d/podkop stop
killall sing-box
/etc/init.d/podkop start
```

Если LuCI по Tailscale показывает `Forbidden`:

```sh
uci set uhttpd.main.rfc1918_filter='0'
uci commit uhttpd
/etc/init.d/uhttpd restart
```

Bootstrap не открывает WAN-порты. SSH и LuCI должны быть доступны через Tailscale IPv4.

## Прямой доступ к LuCI через Tailscale

Bootstrap и скрипт удалённого доступа настраивают прямой доступ к самому роутеру из Tailnet:

```text
LuCI: http://ROUTER_TAILSCALE_IP/
SSH:  ssh root@ROUTER_TAILSCALE_IP
```

Для этого используется helper:

```text
scripts/install-tailscale-direct-access.sh
```

Он делает backup `/etc/config/firewall` и `/etc/config/uhttpd`, включает автозапуск `tailscale`, `dropbear` и `uhttpd`, отключает `uhttpd.main.rfc1918_filter`, а затем добавляет только input-правила для Tailnet:

```text
Allow-SSH-from-Tailscale:  100.64.0.0/10 -> tcp/22
Allow-LuCI-from-Tailscale: 100.64.0.0/10 -> tcp/80,443
```

WAN-порты не открываются, port forwarding не создаётся.

Если нужно отключить эту настройку:

```sh
ENABLE_LUCI_TAILSCALE=0 ROUTER_NAME='my-router' /tmp/bootstrap.sh
```

Проверка с ноутбука после bootstrap и перезагрузки:

```powershell
& "C:\Program Files\Tailscale\tailscale.exe" ping ROUTER_TAILSCALE_IP
curl.exe -I http://ROUTER_TAILSCALE_IP
ssh root@ROUTER_TAILSCALE_IP
```

Сразу после перезагрузки `tailscale ping` может несколько секунд отвечать timeout, пока `tailscaled` поднимается. После появления `pong` LuCI и SSH должны отвечать напрямую через Tailscale IP.


## Установка и обновление Podkop через официальный installer

Bootstrap использует официальный installer Podkop и для установки, и для обновления:

```sh
wget -O /tmp/podkop-install.sh https://raw.githubusercontent.com/itdoginfo/podkop/main/install.sh
sh /tmp/podkop-install.sh
```

Поведение:

- чистый роутер без Podkop: `INSTALL_PODKOP=auto` или `INSTALL_PODKOP=1` устанавливает Podkop через официальный installer;
- роутер с уже установленным Podkop: `UPDATE_PODKOP=1` обновляет Podkop через официальный installer;
- роутер с уже установленным Podkop, который не нужно обновлять: `UPDATE_PODKOP=0` оставляет текущую версию Podkop;
- bootstrap не делает общий `opkg upgrade`.

Installer запускается в non-interactive режиме: bootstrap постоянно подаёт ответы `y` на вопросы installer-а, включая вопрос про русскую локализацию. Это нужно, чтобы русская локализация Podkop сохранялась или устанавливалась, когда installer спрашивает об этом.

## Changelog

Updater now preserves and imports Trojan and Hysteria2 links from Remnawave/converter subscriptions.
