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

## Важно по безопасности

Не коммить реальные subscription token, UUID, приватные ключи и полные proxy-ссылки в GitHub. В репозитории должен быть только `subscription.conf.example`, а реальный `/etc/podkop-remnawave/subscription.conf` хранится только на роутере.

## Changelog

Updater now preserves and imports Trojan and Hysteria2 links from Remnawave/converter subscriptions.
