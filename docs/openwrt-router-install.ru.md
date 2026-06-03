# Установка на новый OpenWrt-роутер



Инструкция для чистого роутера OpenWrt 25.x, например Xiaomi AX300T.



Цель: одной командой установить русскую локализацию OpenWrt/LuCI, ttyd, Podkop и скрипт автообновления ключей из Remnawave-подписки.



Репозиторий проекта:



```text

https://github.com/podvoz66/podkop-remnawave-subscription

```



---



## Что нужно заранее



1. Прошить роутер OpenWrt.

2. Подключиться к роутеру по SSH под пользователем `root`.

3. В панели Remnawave создать отдельного пользователя для роутера.

4. Скопировать subscription URL этого пользователя.



Поддерживаемые схемы подписки для роутера:



\* VLESS TCP REALITY;
\* Shadowsocks;
\* Trojan;
\* Hysteria2 / HY2;

\* direct/router nodes;

\* без mobile/XHTTP, если они не нужны именно этому роутеру.



Пример имени пользователя в Remnawave:



```text

Podkop-Router-All-Reality

```



---



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

## Интерактивная установка



На новом роутере выполнить:



```sh

wget -O - https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main/install.sh | sh

```



Скрипт спросит:



```text

Paste Remnawave subscription URL:

```



Вставить ссылку подписки из Remnawave, например:



```text

https://sub.adeptpro.online/НОВЫЙ\_TOKEN

```



Это предпочтительный способ, потому что subscription token не попадает прямо в историю shell-команд.



---



## Вариант одной строкой



Можно передать subscription URL сразу:



```sh

SUB\_URL='https://sub.adeptpro.online/НОВЫЙ\_TOKEN' wget -O - https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main/install.sh | sh

```



Минус: token может остаться в истории команд shell.



---



## Если роутер находится в домашней сети с Nginx Proxy Manager



Если `sub.adeptpro.online` внутри LAN должен открываться через Nginx Proxy Manager на `192.168.0.172`, использовать split-DNS override:



```sh

SUB\_HOST\_IP='192.168.0.172' wget -O - https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main/install.sh | sh

```



Или вместе с subscription URL:



```sh

SUB\_URL='https://sub.adeptpro.online/НОВЫЙ\_TOKEN' SUB\_HOST\_IP='192.168.0.172' wget -O - https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main/install.sh | sh

```



Это нужно в ситуации, когда сам роутер резолвит `sub.adeptpro.online` во внешний WAN/public IP и получает `404`, хотя из браузера в LAN ссылка открывается.



Проверка DNS на роутере:



```sh

nslookup sub.adeptpro.online

```



Для домашней схемы ожидаемо:



```text

Address: 192.168.0.172

```



---



## Что делает install.sh



Скрипт автоматически:



\* проверяет, что запущен на OpenWrt;

\* определяет пакетный менеджер `apk` или `opkg`;

\* обновляет списки пакетов;

\* устанавливает базовые пакеты;

\* устанавливает русскую локализацию LuCI;

\* устанавливает ttyd;

\* устанавливает Podkop;

\* устанавливает updater `/usr/bin/update-podkop-from-remnawave.sh`;

\* сохраняет subscription URL в `/etc/podkop-remnawave/subscription.conf`;

\* добавляет cron-обновление каждые 4 часа;

\* делает первый запуск обновления;

\* перезапускает Podkop/sing-box;

\* создаёт backup перед изменениями.



---



## Где хранится subscription URL



Файл:



```sh

/etc/podkop-remnawave/subscription.conf

```



Внутри:



```sh

SUB\_URL='https://sub.adeptpro.online/НОВЫЙ\_TOKEN'

```



Права должны быть закрыты:



```sh

chmod 600 /etc/podkop-remnawave/subscription.conf

```



---



## Логика обновления ключей



Updater:



\* скачивает Remnawave subscription;

\* извлекает `vless://`, `ss://`, `trojan://`, `hysteria2://`, `hy2://` links;

\* добавляет `spx=%2F` только для VLESS Reality-ссылок, если его нет;

\* не меняет Shadowsocks, Trojan, Hysteria2 и HY2 links;

\* помечает управляемые ссылки суффиксом `-rwsub`;

\* при следующем запуске удаляет только старые `-rwsub` ссылки;

\* ручные ключи без `-rwsub` не трогает;

\* если секция `USA` уже существует, US-ссылки идут в `USA`;

\* если секции `USA` нет, все Remnawave-ссылки идут в `main`.



То есть:



```text

Remnawave добавил сервер  -> новая ссылка появится в Podkop

Remnawave удалил сервер   -> старая -rwsub ссылка исчезнет из Podkop

Remnawave сменил UUID     -> старая -rwsub ссылка исчезнет, новая появится

ручной AutoXray ключ      -> останется без изменений

USA секции нет            -> все Remnawave-ссылки идут в main

USA секция есть           -> US идёт в USA, остальное в main

```



---



## Ручной запуск обновления



```sh

/usr/bin/update-podkop-from-remnawave.sh

```



Лог последнего cron/ручного запуска:



```sh

cat /tmp/podkop-sub-update.log

```



---



## Cron



Автообновление каждые 4 часа:



```sh

0 \*/4 \* \* \* /usr/bin/update-podkop-from-remnawave.sh >/tmp/podkop-sub-update.log 2>\&1

```



Проверка:



```sh

cat /etc/crontabs/root | grep update-podkop

```



---



## Проверка после установки



```sh

cat /tmp/podkop-sub-update.log



pgrep -af sing-box



netstat -lntup 2>/dev/null | grep -E '1602|9090|sing|podkop' || true



uci show podkop.main | grep 'urltest\_proxy\_links'



uci show podkop.USA 2>/dev/null | grep 'urltest\_proxy\_links' || true



cat /etc/crontabs/root | grep update-podkop

```



Ожидаемо:



```text

sing-box running

127.0.0.1:1602 — tproxy inbound

127.0.0.42:53 — sing-box DNS

192.168.0.1:9090 — Clash/YACD API

cron update-podkop-from-remnawave.sh есть

```



---



## Проверка ссылок Podkop



Проверить секцию `main`:



```sh

uci show podkop.main | grep 'urltest\_proxy\_links'

```



Проверить секцию `USA`, если она есть:



```sh

uci show podkop.USA 2>/dev/null | grep 'urltest\_proxy\_links' || true

```



Проверить, что Reality-ссылки получили `spx=%2F`:



```sh

uci show podkop.main | grep 'spx=%2F'

uci show podkop.USA 2>/dev/null | grep 'spx=%2F' || true

```



---



## Если после установки Podkop не работает



Проверить процесс:



```sh

pgrep -af sing-box

```



Проверить listen-порты:



```sh

netstat -lntup 2>/dev/null | grep -E '1602|9090|sing|podkop' || true

```



Проверить конфиг sing-box:



```sh

sing-box check -c /etc/sing-box/config.json

```



Посмотреть ошибки:



```sh

logread | grep -iE 'podkop|sing-box|singbox|error|failed|fatal|panic|invalid' | tail -n 160

```



Перезапустить вручную:



```sh

/etc/init.d/podkop restart

sleep 10

pgrep -af sing-box

```



---



## Если подписка не скачивается



Проверить URL:



```sh

cat /etc/podkop-remnawave/subscription.conf

```



Проверить DNS:



```sh

nslookup sub.adeptpro.online

```



Проверить скачивание:



```sh

curl -k -fsSL 'https://sub.adeptpro.online/НОВЫЙ\_TOKEN' -o /tmp/sub.raw

head -c 120 /tmp/sub.raw; echo

```



Если роутер в LAN получает `404`, а браузер открывает подписку, скорее всего нужен split-DNS override на NPM:



```sh

uci add dhcp domain

uci set dhcp.@domain\[-1].name='sub.adeptpro.online'

uci set dhcp.@domain\[-1].ip='192.168.0.172'

uci commit dhcp

/etc/init.d/dnsmasq restart

```



Проверка:



```sh

nslookup sub.adeptpro.online

```



Ожидаемо:



```text

Address: 192.168.0.172

```



---



## Как заменить subscription URL



Открыть файл:



```sh

vi /etc/podkop-remnawave/subscription.conf

```



И заменить строку:



```sh

SUB\_URL='https://sub.adeptpro.online/НОВЫЙ\_TOKEN'

```



Потом запустить:



```sh

/usr/bin/update-podkop-from-remnawave.sh

```



Проверить:



```sh

cat /tmp/podkop-sub-update.log

pgrep -af sing-box

```



---



## Где backup



Installer и updater делают backup в:



```sh

/etc/podkop-remnawave/backups/

```



Также backup Podkop-конфига может быть рядом:



```sh

/etc/config/podkop.backup.\*

```



---



## Важно по безопасности



Не добавлять реальные subscription URL, tokens, UUID, proxy-ссылки и ключи в GitHub.



В GitHub должны быть только:



\* скрипты;

\* инструкции;

\* примеры без секретов.



Реальный subscription URL должен храниться только на роутере:



```sh

/etc/podkop-remnawave/subscription.conf

```



---



## Команды для обновления GitHub-документации



На Windows в папке проекта:



```powershell

cd C:\\Users\\Podvoz\\Downloads\\podkop-remnawave-subscription\\podkop-remnawave-subscription



git status

git add .\\docs\\openwrt-router-install.ru.md

git commit -m "Document OpenWrt router one-command install"

git pull --rebase origin main

git push

```



Проверить файл на GitHub:



```text

https://github.com/podvoz66/podkop-remnawave-subscription/blob/main/docs/openwrt-router-install.ru.md

```




