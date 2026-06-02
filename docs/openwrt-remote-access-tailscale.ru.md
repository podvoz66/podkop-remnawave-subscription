# Удалённый доступ к OpenWrt-роутеру через Tailscale

Инструкция для удалённого доступа к роутеру OpenWrt без открытия портов в WAN.

Подходит для:

* OpenWrt 24.10.x;
* Xiaomi AX300T;
* NanoPi R3S;
* роутеров за NAT;
* роутеров без белого IP;
* роутеров с установленным Podkop.

Репозиторий проекта:

```text
https://github.com/podvoz66/podkop-remnawave-subscription
```

---

## Зачем это нужно

Tailscale позволяет подключаться к роутеру удалённо по приватному Tailscale IP.

После настройки можно заходить:

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

WAN-порты открывать не нужно.

---

## Как запускать на роутере

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

Скрипт покажет ссылку авторизации Tailscale.

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

С ноутбука или другого устройства, которое тоже подключено к твоему Tailscale-аккаунту:

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

---

## Вариант с Tailscale auth key

Если не хочется открывать ссылку авторизации вручную, можно создать auth key в Tailscale Admin Console.

Запуск:

```sh
TAILSCALE_AUTHKEY='tskey-auth-XXXX' sh /tmp/remote.sh
```

Не добавлять auth key в GitHub.

Не отправлять auth key в публичные чаты.

---

## Дополнительные параметры Tailscale

Можно передать дополнительные параметры через `TAILSCALE_EXTRA_ARGS`.

Например:

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

Проверить, что SSH/LuCI доступны через Tailscale:

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
