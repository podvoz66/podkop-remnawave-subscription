# Удалённый доступ к OpenWrt-роутеру через Tailscale

Версия документа: tailscale-remote-access-v3.

Инструкция для удалённого доступа к OpenWrt-роутеру без открытия портов в WAN.

Подходит для:

- OpenWrt 24.10.x;
- Xiaomi AX300T;
- NanoPi R3S;
- роутеров за NAT;
- роутеров без белого IP;
- роутеров с установленным Podkop;
- роутеров, где нужно удалённо обслуживать Podkop и Remnawave-подписку.

Репозиторий проекта:

```text
https://github.com/podvoz66/podkop-remnawave-subscription
```

---

## One-command bootstrap для всего роутера

Если нужно одной командой подготовить OpenWrt для Tailscale, LuCI remote access, Podkop и Remnawave router subscription, используйте bootstrap-скрипт:

```sh
wget -O /tmp/bootstrap-openwrt-router.sh \
  https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main/scripts/bootstrap-openwrt-router.sh

chmod +x /tmp/bootstrap-openwrt-router.sh

ROUTER_NAME='openwrt-router' \
SUB_URL='https://sub.adeptpro.online/ROUTER_SUBSCRIPTION_TOKEN' \
  /tmp/bootstrap-openwrt-router.sh
```

С auth key Tailscale:

```sh
TAILSCALE_AUTHKEY='TS_AUTH_KEY_PLACEHOLDER' \
ROUTER_NAME='openwrt-router' \
SUB_URL='https://sub.adeptpro.online/ROUTER_SUBSCRIPTION_TOKEN' \
  /tmp/bootstrap-openwrt-router.sh
```

Скрипт делает preflight, backup в `/root/podkop-bootstrap-backups/YYYYmmdd-HHMMSS/`, не открывает WAN-порты и выводит финальные команды `ssh root@TAILSCALE_IP` и `http://TAILSCALE_IP/`.

Переменные:

```sh
INSTALL_RU_LOCALE=1
INSTALL_TTYD=1
INSTALL_PODKOP=auto
ENABLE_LUCI_TAILSCALE=1
DRY_RUN=0
```

Если `SUB_URL` не задан, подписка не импортируется, но Tailscale/LuCI setup всё равно выполняется.

---

## Что делает скрипт

Скрипт:

1. устанавливает пакеты `tailscale`, `kmod-tun`, `iptables-nft`, `ip6tables-nft`, `ca-bundle`, `ca-certificates`;
2. включает автозапуск Tailscale;
3. запускает `tailscaled`;
4. отдельно спрашивает `Tailscale auth key`;
5. отдельно спрашивает имя роутера;
6. останавливает orphan `sing-box`, если он мешает Tailscale;
7. выполняет `tailscale up --accept-dns=false --ssh=false --hostname=...`;
8. показывает Tailscale IPv4;
9. не открывает SSH/LuCI в WAN.

После настройки можно заходить на роутер удалённо:

```text
ssh root@TAILSCALE_IP
http://TAILSCALE_IP/
http://TAILSCALE_IP:9090/
```

Где:

```text
22    — SSH
80    — LuCI
9090  — YACD / sing-box API, если включён в Podkop
```

---

## Важные настройки Tailscale auth key

В Tailscale Admin Console создать auth key:

```text
Settings → Keys → Generate auth key
```

Рекомендуемые параметры:

```text
Description: OpenWrt routers
Reusable: ON
Expiration: 90 days
Ephemeral: OFF
Tags: OFF
```

После генерации Tailscale покажет ключ вида:

```text
TS_AUTH_KEY_PLACEHOLDER
```

Важно:

- не добавлять реальный auth key в GitHub;
- не отправлять ключ в публичные чаты;
- после настройки всех роутеров можно удалить или отключить auth key в Tailscale Admin Console.

---

## Установка на роутере

Подключиться к роутеру по SSH под `root`.

Скачать скрипт:

```sh
wget -O /tmp/remote.sh \
  https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main/scripts/install-remote-access-tailscale.sh
```

Сделать исполняемым:

```sh
chmod +x /tmp/remote.sh
```

Запустить:

```sh
sh /tmp/remote.sh
```

Скрипт спросит:

```text
Tailscale auth key:
Tailscale router name:
```

В поле `Tailscale auth key` вставить ключ вида:

```text
TS_AUTH_KEY_PLACEHOLDER
```

В поле `Tailscale router name` ввести понятное имя роутера, например:

```text
nanopi-r3s-home
xiaomi-ax300t-flat
openwrt-office
```

Имя будет автоматически приведено к безопасному виду:

```text
только a-z, 0-9 и дефисы
```

---

## Запуск без вопросов через переменные

Можно передать auth key и имя роутера сразу:

```sh
TAILSCALE_AUTHKEY='TS_AUTH_KEY_PLACEHOLDER' \
TAILSCALE_HOSTNAME='nanopi-r3s-home' \
sh /tmp/remote.sh
```

Полный вариант одной командой:

```sh
TAILSCALE_AUTHKEY='TS_AUTH_KEY_PLACEHOLDER' \
TAILSCALE_HOSTNAME='nanopi-r3s-home' \
sh -c '
wget -O /tmp/remote.sh https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main/scripts/install-remote-access-tailscale.sh &&
chmod +x /tmp/remote.sh &&
TAILSCALE_AUTHKEY="$TAILSCALE_AUTHKEY" TAILSCALE_HOSTNAME="$TAILSCALE_HOSTNAME" sh /tmp/remote.sh
'
```

---

## Вариант без auth key

Можно оставить поле auth key пустым.

Тогда скрипт выполнит:

```sh
tailscale up --accept-dns=false --ssh=false --hostname=ИМЯ_РОУТЕРА
```

И Tailscale покажет ссылку авторизации.

Открыть ссылку в браузере, войти в Tailscale и подтвердить подключение роутера.

---

## Проверка после установки

На роутере:

```sh
tailscale status
tailscale ip -4
pgrep -af tailscaled
```

Ожидаемо:

```text
tailscaled запущен
tailscale ip -4 показывает адрес вида 100.x.y.z
```

---

## Если роутер offline в Tailscale

На OpenWrt 24.10.x Tailscale должен работать через nftables compatibility пакеты:

```sh
opkg update
opkg install kmod-tun iptables-nft ip6tables-nft ca-bundle ca-certificates tailscale
```

Если в tailnet роутер offline, проверьте orphan `sing-box`:

```sh
pgrep -af sing-box || echo "NO sing-box process"
```

Восстановление:

```sh
killall sing-box
/etc/init.d/tailscale restart
tailscale status
tailscale netcheck
tailscale ip -4
```

Если `tailscale status` или `logread` показывает ошибки coordination server, не запускайте Podkop обратно до проверки routing exclusions:

```sh
logread | grep -i tailscale | tail -n 120
/etc/init.d/podkop status
pgrep -af sing-box || echo "NO sing-box process"
```

---

## Если LuCI показывает Forbidden через Tailscale

Если `http://100.x.x.x/` возвращает:

```text
Forbidden
Rejected request from RFC1918 IP to public server address
```

Отключите только uhttpd RFC1918 filter. WAN-порты при этом не открываются:

```sh
cp /etc/config/uhttpd /etc/config/uhttpd.backup-tailscale-$(date +%Y%m%d-%H%M%S)
uci set uhttpd.main.rfc1918_filter='0'
uci commit uhttpd
/etc/init.d/uhttpd restart
```

---

## Как подключаться к роутеру после настройки

С ноутбука или другого устройства, которое тоже подключено к тому же Tailscale-аккаунту:

```sh
ssh root@TAILSCALE_IP
```

LuCI:

```text
http://TAILSCALE_IP/
```

YACD / sing-box API, если включён Podkop:

```text
http://TAILSCALE_IP:9090/
```

Пример:

```sh
ssh root@100.75.185.50
```

```text
http://100.75.185.50/
```

---

## Дополнительные параметры Tailscale

Можно передать дополнительные параметры через `TAILSCALE_EXTRA_ARGS`.

Например, чтобы роутер рекламировал подсеть LAN:

```sh
TAILSCALE_EXTRA_ARGS='--advertise-routes=192.168.31.0/24' sh /tmp/remote.sh
```

Это нужно только если требуется доступ не только к самому роутеру, но и к устройствам за ним.

Обычный удалённый доступ к самому роутеру этого не требует.

---

## Безопасность

Не открывать SSH/LuCI в WAN.

Не делать port forwarding на роутер.

Использовать доступ только через Tailscale IP.

Обязательно задать пароль root:

```sh
passwd
```

Проверить, что SSH доступен через Tailscale:

```sh
ssh root@TAILSCALE_IP
```

---

## Удаление Tailscale

Остановить:

```sh
/etc/init.d/tailscale stop
/etc/init.d/tailscale disable
```

Удалить пакет:

```sh
opkg remove tailscale
```

Проверить:

```sh
pgrep -af tailscaled || echo "tailscaled stopped"
```

---

## Быстрая команда-шпаргалка

```sh
wget -O /tmp/remote.sh \
  https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main/scripts/install-remote-access-tailscale.sh

chmod +x /tmp/remote.sh

sh /tmp/remote.sh
```

---

## Быстрая команда с auth key и именем роутера

```sh
TAILSCALE_AUTHKEY='TS_AUTH_KEY_PLACEHOLDER' \
TAILSCALE_HOSTNAME='nanopi-r3s-home' \
sh -c '
wget -O /tmp/remote.sh https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main/scripts/install-remote-access-tailscale.sh &&
chmod +x /tmp/remote.sh &&
TAILSCALE_AUTHKEY="$TAILSCALE_AUTHKEY" TAILSCALE_HOSTNAME="$TAILSCALE_HOSTNAME" sh /tmp/remote.sh
'
```
