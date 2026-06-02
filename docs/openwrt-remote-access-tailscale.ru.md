# Удалённый доступ к OpenWrt-роутеру через Tailscale

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

## Что делает скрипт

Скрипт:

1. устанавливает пакет `tailscale`;
2. включает автозапуск Tailscale;
3. запускает `tailscaled`;
4. отдельно спрашивает `Tailscale auth key`;
5. отдельно спрашивает имя роутера;
6. выполняет `tailscale up`;
7. показывает Tailscale IPv4;
8. не открывает SSH/LuCI в WAN.

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
tskey-auth-xxxxxxxxxxxxxxxx
```

Важно:

- не добавлять `tskey-auth-...` в GitHub;
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
tskey-auth-xxxxxxxxxxxxxxxx
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
TAILSCALE_AUTHKEY='tskey-auth-XXXX' \
TAILSCALE_HOSTNAME='nanopi-r3s-home' \
sh /tmp/remote.sh
```

Полный вариант одной командой:

```sh
TAILSCALE_AUTHKEY='tskey-auth-XXXX' \
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
tailscale up --hostname=ИМЯ_РОУТЕРА --accept-dns=false
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
TAILSCALE_AUTHKEY='tskey-auth-XXXX' \
TAILSCALE_HOSTNAME='nanopi-r3s-home' \
sh -c '
wget -O /tmp/remote.sh https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main/scripts/install-remote-access-tailscale.sh &&
chmod +x /tmp/remote.sh &&
TAILSCALE_AUTHKEY="$TAILSCALE_AUTHKEY" TAILSCALE_HOSTNAME="$TAILSCALE_HOSTNAME" sh /tmp/remote.sh
'
```
