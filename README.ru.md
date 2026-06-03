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

## Быстрый запуск

### One-command OpenWrt bootstrap

Рекомендуемый вариант для нового или уже используемого OpenWrt-роутера: один скрипт определяет текущее состояние, ставит недостающие компоненты, настраивает Tailscale remote access, включает LuCI через Tailscale, устанавливает или сохраняет Podkop и импортирует router-подписку Remnawave.

```sh
wget -O /tmp/bootstrap-openwrt-router.sh \
  https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main/scripts/bootstrap-openwrt-router.sh

chmod +x /tmp/bootstrap-openwrt-router.sh

ROUTER_NAME='openwrt-router' \
SUB_URL='https://sub.adeptpro.online/ROUTER_SUBSCRIPTION_TOKEN' \
  /tmp/bootstrap-openwrt-router.sh
```

Для установки Tailscale без browser login передайте auth key через переменную окружения. Не коммитьте реальный ключ:

```sh
TAILSCALE_AUTHKEY='TS_AUTH_KEY_PLACEHOLDER' \
ROUTER_NAME='openwrt-router' \
SUB_URL='https://sub.adeptpro.online/ROUTER_SUBSCRIPTION_TOKEN' \
  /tmp/bootstrap-openwrt-router.sh
```

Полезные переключатели:

```sh
INSTALL_RU_LOCALE=0       # не ставить русскую локализацию LuCI
INSTALL_TTYD=0            # не ставить ttyd/luci-app-ttyd
INSTALL_PODKOP=0          # не ставить Podkop, если он отсутствует
ENABLE_LUCI_TAILSCALE=0   # не менять uhttpd rfc1918_filter
DRY_RUN=1                 # показать действия без применения
```

Если `SUB_URL` не задан, bootstrap не падает: он настраивает роутер и Tailscale, а импорт подписки пропускает с предупреждением.

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

## Важно по безопасности

Не коммить реальные subscription token, UUID, приватные ключи и полные proxy-ссылки в GitHub. В репозитории должен быть только `subscription.conf.example`, а реальный `/etc/podkop-remnawave/subscription.conf` хранится только на роутере.

## Changelog

Updater now preserves and imports Trojan and Hysteria2 links from Remnawave/converter subscriptions.
