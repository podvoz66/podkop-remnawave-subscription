# Podkop Remnawave Subscription Updater

Скрипт для OpenWrt, который берёт router-подписку Remnawave и автоматически подставляет поддерживаемые proxy-ссылки в секции Podkop URLTest.

Что делает:

- скачивает Remnawave subscription;
- декодирует base64, если подписка отдана в base64;
- извлекает `vless://`, `ss://`, `trojan://`, `hysteria2://`, `hy2://` ссылки;
- добавляет `spx=%2F` только в VLESS REALITY-ссылки, если Remnawave его не добавил;
- не меняет `ss://`, `trojan://`, `hysteria2://`, `hy2://` ссылки;
- раскладывает ссылки по секциям Podkop:
  - `main` = все ссылки, кроме US;
  - `USA` = только `us-direct-reality`;
- перезапускает Podkop/sing-box.

Итоговая схема:

```text
Remnawave subscription
→ /usr/bin/update-podkop-from-remnawave.sh
→ podkop.main.urltest_proxy_links = AUT + Oslo + PL
→ podkop.USA.urltest_proxy_links = US
→ Podkop restart
→ sing-box running
```

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

После Stage 7 вручную добавлять token в converter allowlist и отдельный nginx location больше не требуется. Router-side updater должен поддерживать:

```text
vless://
ss://
trojan://
hysteria2://
hy2://
```

Контрольная проверка выполняется не по panel preview, а по публичной subscription-ссылке:

```sh
SUB_URL='https://sub.adeptpro.online/ROUTER_SUBSCRIPTION_TOKEN'

curl -fsSL "$SUB_URL" -o /tmp/router-sub.b64

base64 -d /tmp/router-sub.b64 2>/dev/null \
  | grep -Eo '^(vless|ss|trojan|hysteria2|hy2)://' \
  | sort | uniq -c
```

## Быстрый запуск

### One-command OpenWrt bootstrap

Рекомендуемый вариант для нового или уже используемого OpenWrt-роутера: один скрипт определяет текущее состояние, ставит недостающие компоненты, настраивает Tailscale remote access, включает LuCI через Tailscale, устанавливает или сохраняет Podkop и импортирует router-подписку Remnawave.

### Интерактивный запуск

Используйте этот вариант, если хотите, чтобы скрипт сам спросил имя роутера, Tailscale auth key и ссылку Remnawave subscription.

```sh
wget -O /tmp/bootstrap-openwrt-router.sh \
  https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main/scripts/bootstrap-openwrt-router.sh

chmod +x /tmp/bootstrap-openwrt-router.sh

/tmp/bootstrap-openwrt-router.sh
```

В этом варианте появится вопрос:

```text
Enter Router/device name / Введите имя роутера:
```

### Запуск с заранее заданным именем роутера

Используйте этот вариант, если имя роутера нужно передать заранее. В этом случае вопрос `Enter Router/device name` не появится.

```sh
wget -O /tmp/bootstrap-openwrt-router.sh \
  https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main/scripts/bootstrap-openwrt-router.sh

chmod +x /tmp/bootstrap-openwrt-router.sh

ROUTER_NAME='openwrt-router' \
  /tmp/bootstrap-openwrt-router.sh
```

Скрипт задаёт три вопроса при старте, если значения не переданы через переменные окружения:

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

Tailscale auth key можно оставить пустым: если роутер уже авторизован в Tailscale, текущая авторизация сохранится; иначе Tailscale покажет browser login. Subscription URL можно оставить пустым: если в `/etc/podkop-remnawave/subscription.conf` уже есть сохранённая ссылка, она будет использована; иначе импорт подписки будет пропущен.

Для полностью non-interactive запуска передайте значения через переменные окружения и задайте `INTERACTIVE=0`. Не коммитьте реальный auth key или subscription URL:

```sh
INTERACTIVE=0 \
TAILSCALE_AUTHKEY='TS_AUTH_KEY_PLACEHOLDER' \
ROUTER_NAME='openwrt-router' \
SUB_URL='https://sub.adeptpro.online/ROUTER_SUBSCRIPTION_TOKEN' \
  /tmp/bootstrap-openwrt-router.sh
```

Можно также запустить non-interactive без этих значений:

```sh
INTERACTIVE=0 \
ROUTER_NAME='openwrt-router' \
  /tmp/bootstrap-openwrt-router.sh
```

При `INTERACTIVE=0` без `SUB_URL` bootstrap использует сохранённую подписку, если она есть. Без `TAILSCALE_AUTHKEY` он сохраняет существующее состояние Tailscale или переходит к browser login.

Полезные переключатели:

```sh
INTERACTIVE=0             # не задавать вопросы при старте
INSTALL_RU_LOCALE=0       # не ставить русскую локализацию LuCI
INSTALL_TTYD=0            # не ставить ttyd/luci-app-ttyd
INSTALL_PODKOP=0          # не ставить Podkop, если он отсутствует
UPDATE_PODKOP=0           # не обновлять уже установленный Podkop
ENABLE_LUCI_TAILSCALE=0   # не менять uhttpd rfc1918_filter
DRY_RUN=1                 # показать действия без применения
```

Если `SUB_URL` не задан и сохранённой подписки нет, bootstrap не падает: он настраивает роутер и Tailscale, а импорт подписки пропускает с предупреждением.

## Финальный статус и логи

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
REBOOT_AFTER=0 ROUTER_NAME='my-router' /tmp/bootstrap-openwrt-router.sh
```

После этого перезагрузите вручную:

```sh
sync && reboot
```

Если bootstrap завершился с ошибкой, автоматическая перезагрузка не выполняется. Скрипт выводит `[ERROR] Bootstrap failed.`, backup directory, путь к логу и последние 80 строк лога.

Если запускаете bootstrap из LuCI Terminal / ttyd, используйте:

```sh
INSTALL_TTYD=0 ROUTER_NAME='my-router' /tmp/bootstrap-openwrt-router.sh
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

### 1. Новый роутер OpenWrt

Используйте этот вариант, если Podkop ещё не установлен или роутер настраивается с нуля.

```sh
wget -O /tmp/install.sh \
  https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main/install.sh

chmod +x /tmp/install.sh

SUB_URL='https://sub.adeptpro.online/ROUTER_SUBSCRIPTION_TOKEN' \
  /tmp/install.sh
```

### 2. Уже настроенный роутер OpenWrt

Используйте этот вариант, если Podkop уже установлен, а нужно только установить или обновить Remnawave updater и subscription URL.

```sh
wget -O /tmp/install-subscription-on-existing-podkop.sh \
  https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main/scripts/install-subscription-on-existing-podkop.sh

chmod +x /tmp/install-subscription-on-existing-podkop.sh

SUB_URL='https://sub.adeptpro.online/ROUTER_SUBSCRIPTION_TOKEN' \
  /tmp/install-subscription-on-existing-podkop.sh
```

`ROUTER_SUBSCRIPTION_TOKEN` замените на token отдельного router-пользователя Remnawave. Не используйте здесь mobile-подписку и не публикуйте реальный token в GitHub.

## Ручная установка на OpenWrt

Создать конфиг:

```sh
mkdir -p /etc/podkop-remnawave
cat >/etc/podkop-remnawave/subscription.conf <<'EOF_CONF'
SUB_URL='https://sub.example.com/YOUR_TOKEN'
EOF_CONF
chmod 600 /etc/podkop-remnawave/subscription.conf
```

Установить скрипт:

```sh
cp scripts/update-podkop-from-remnawave.sh /usr/bin/update-podkop-from-remnawave.sh
chmod +x /usr/bin/update-podkop-from-remnawave.sh
```

Запустить вручную:

```sh
/usr/bin/update-podkop-from-remnawave.sh
```

Ожидаемый вывод:

```text
[INFO] Found subscription links total: 8
[INFO] Remnawave links for main: 7
[INFO] Remnawave links for USA: 1
[OK] sing-box is running.
[OK] Podkop updated from Remnawave subscription.
```

Поддерживаемые схемы:

```text
vless://
ss://
trojan://
hysteria2://
hy2://
```

Проверить секции:

```sh
uci show podkop.main | grep 'urltest_proxy_links'
uci show podkop.USA | grep 'urltest_proxy_links'
pgrep -af sing-box
netstat -lntup 2>/dev/null | grep -E '1602|9090|sing|podkop' || true
```

## Автообновление через cron

```sh
grep -q 'update-podkop-from-remnawave.sh' /etc/crontabs/root || \
echo '0 */4 * * * /usr/bin/update-podkop-from-remnawave.sh >/tmp/podkop-sub-update.log 2>&1' >> /etc/crontabs/root

/etc/init.d/cron restart
```

Проверка:

```sh
cat /tmp/podkop-sub-update.log
```

## Split-DNS, если подписка открывается с ПК, но роутер получает 404

Если домен подписки указывает на публичный WAN IP самого роутера, LAN-клиенты могут попадать через NAT reflection на NPM/backend, а сам роутер — в локальный fallback и получать 404.

Пример фикса:

```sh
uci add dhcp domain
uci set dhcp.@domain[-1].name='sub.example.com'
uci set dhcp.@domain[-1].ip='192.168.0.172'
uci commit dhcp
/etc/init.d/dnsmasq restart
```

Проверка:

```sh
nslookup sub.example.com
```

Должно вернуть LAN IP reverse proxy / NPM.

## Удалённый доступ через Tailscale на OpenWrt

Установка удалённого доступа без открытия SSH, LuCI или других WAN-портов:

```sh
wget -O /tmp/install-remote-access-tailscale.sh \
  https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main/scripts/install-remote-access-tailscale.sh

chmod +x /tmp/install-remote-access-tailscale.sh

TAILSCALE_HOSTNAME='openwrt-router' \
  /tmp/install-remote-access-tailscale.sh
```

Для установки без browser login можно передать auth key через переменную окружения. Не коммитьте реальный ключ в GitHub:

```sh
TAILSCALE_AUTHKEY='TS_AUTH_KEY_PLACEHOLDER' \
TAILSCALE_HOSTNAME='openwrt-router' \
  /tmp/install-remote-access-tailscale.sh
```

Если роутер отображается в Tailscale как offline, проверьте orphan `sing-box`:

```sh
pgrep -af sing-box || echo "NO sing-box process"
```

Восстановление:

```sh
killall sing-box
/etc/init.d/tailscale restart
tailscale status
tailscale ip -4
```

Если LuCI по `http://100.x.x.x/` показывает `Forbidden` с предупреждением RFC1918/public address:

```sh
uci set uhttpd.main.rfc1918_filter='0'
uci commit uhttpd
/etc/init.d/uhttpd restart
```

Скрипт не открывает WAN-порты. Доступ должен идти только через Tailscale IPv4.

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
ENABLE_LUCI_TAILSCALE=0 ROUTER_NAME='my-router' /tmp/bootstrap-openwrt-router.sh
```

Проверка с ноутбука после bootstrap и перезагрузки:

```powershell
& "C:\Program Files\Tailscale\tailscale.exe" ping ROUTER_TAILSCALE_IP
curl.exe -I http://ROUTER_TAILSCALE_IP
ssh root@ROUTER_TAILSCALE_IP
```

Сразу после перезагрузки `tailscale ping` может несколько секунд отвечать timeout, пока `tailscaled` поднимается. После появления `pong` LuCI и SSH должны отвечать напрямую через Tailscale IP.

## Важно по безопасности

Не коммить реальные subscription token, UUID, приватные ключи и полные proxy-ссылки в GitHub. В репозитории должен быть только `subscription.conf.example`, а реальный `/etc/podkop-remnawave/subscription.conf` хранится только на роутере.


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
