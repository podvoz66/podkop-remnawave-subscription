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

Что делает скрипт

Скрипт:

устанавливает пакет tailscale;
включает автозапуск Tailscale;
запускает tailscaled;
отдельно спрашивает Tailscale auth key;
отдельно спрашивает имя роутера;
выполняет tailscale up;
показывает Tailscale IPv4;
не открывает SSH/LuCI в WAN.

После настройки можно заходить на роутер удалённо:

ssh root@TAILSCALE_IP
http://TAILSCALE_IP/
http://TAILSCALE_IP:9090/

Где:

22    — SSH
80    — LuCI
9090  — YACD / sing-box API, если включён в Podkop
Важные настройки Tailscale auth key

В Tailscale Admin Console создать auth key:

Settings → Keys → Generate auth key

Рекомендуемые параметры:

Description: OpenWrt routers
Reusable: ON
Expiration: 90 days
Ephemeral: OFF
Tags: OFF

После генерации Tailscale покажет ключ вида:

tskey-auth-xxxxxxxxxxxxxxxx

Важно:

не добавлять tskey-auth-... в GitHub;
не отправлять ключ в публичные чаты;
после настройки всех роутеров можно удалить или отключить auth key в Tailscale Admin Console.
Установка на роутере

Подключиться к роутеру по SSH под root.

Скачать скрипт:

wget -O /tmp/remote.sh \
  https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main/scripts/install-remote-access-tailscale.sh

Сделать исполняемым:

chmod +x /tmp/remote.sh

Запустить:

sh /tmp/remote.sh

Скрипт спросит:

Tailscale auth key:
Tailscale router name:

В поле Tailscale auth key вставить ключ вида:

tskey-auth-xxxxxxxxxxxxxxxx

В поле Tailscale router name ввести понятное имя роутера, например:

nanopi-r3s-home
xiaomi-ax300t-flat
openwrt-office

Имя будет автоматически приведено к безопасному виду:

только a-z, 0-9 и дефисы
Запуск без вопросов через переменные

Можно передать auth key и имя роутера сразу:

TAILSCALE_AUTHKEY='tskey-auth-XXXX' \
TAILSCALE_HOSTNAME='nanopi-r3s-home' \
sh /tmp/remote.sh

Полный вариант одной командой:

TAILSCALE_AUTHKEY='tskey-auth-XXXX' \
TAILSCALE_HOSTNAME='nanopi-r3s-home' \
sh -c '
wget -O /tmp/remote.sh https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main/scripts/install-remote-access-tailscale.sh &&
chmod +x /tmp/remote.sh &&
TAILSCALE_AUTHKEY="$TAILSCALE_AUTHKEY" TAILSCALE_HOSTNAME="$TAILSCALE_HOSTNAME" sh /tmp/remote.sh
'
Вариант без auth key

Можно оставить поле auth key пустым.

Тогда скрипт выполнит:

tailscale up --hostname=ИМЯ_РОУТЕРА --accept-dns=false

И Tailscale покажет ссылку авторизации.

Открыть ссылку в браузере, войти в Tailscale и подтвердить подключение роутера.

Проверка после установки

На роутере:

tailscale status
tailscale ip -4
pgrep -af tailscaled

Ожидаемо:

tailscaled запущен
tailscale ip -4 показывает адрес вида 100.x.y.z
Как подключаться к роутеру после настройки

С ноутбука или другого устройства, которое тоже подключено к тому же Tailscale-аккаунту:

ssh root@TAILSCALE_IP

LuCI:

http://TAILSCALE_IP/

YACD / sing-box API, если включён Podkop:

http://TAILSCALE_IP:9090/

Пример:

ssh root@100.75.185.50
http://100.75.185.50/
Дополнительные параметры Tailscale

Можно передать дополнительные параметры через TAILSCALE_EXTRA_ARGS.

Например, чтобы роутер рекламировал подсеть LAN:

TAILSCALE_EXTRA_ARGS='--advertise-routes=192.168.31.0/24' sh /tmp/remote.sh

Это нужно только если требуется доступ не только к самому роутеру, но и к устройствам за ним.

Обычный удалённый доступ к самому роутеру этого не требует.

Безопасность

Не открывать SSH/LuCI в WAN.

Не делать port forwarding на роутер.

Использовать доступ только через Tailscale IP.

Обязательно задать пароль root:

passwd

Проверить, что SSH доступен через Tailscale:

ssh root@TAILSCALE_IP
Удаление Tailscale

Остановить:

/etc/init.d/tailscale stop
/etc/init.d/tailscale disable

Удалить пакет:

opkg remove tailscale

Проверить:

pgrep -af tailscaled || echo "tailscaled stopped"
Быстрая команда-шпаргалка
wget -O /tmp/remote.sh \
  https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main/scripts/install-remote-access-tailscale.sh

chmod +x /tmp/remote.sh

sh /tmp/remote.sh
Быстрая команда с auth key и именем роутера
TAILSCALE_AUTHKEY='tskey-auth-XXXX' \
TAILSCALE_HOSTNAME='nanopi-r3s-home' \
sh -c '
wget -O /tmp/remote.sh https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main/scripts/install-remote-access-tailscale.sh &&
chmod +x /tmp/remote.sh &&
TAILSCALE_AUTHKEY="$TAILSCALE_AUTHKEY" TAILSCALE_HOSTNAME="$TAILSCALE_HOSTNAME" sh /tmp/remote.sh
'

---

## 3. Что добавить в `README.ru.md`

Текущий `README.ru.md` устарел: там указано, что скрипт извлекает только `vless://`, хотя фактически уже нужны `vless://` и `ss://`, а также отдельный Tailscale-раздел. :contentReference[oaicite:1]{index=1}

Добавь в конец `README.ru.md` вот этот блок:

```md
## Удалённый доступ к OpenWrt через Tailscale

Для удалённого доступа к роутеру без открытия WAN-портов используется Tailscale.

Скрипт:

```text
scripts/install-remote-access-tailscale.sh

Документация:

docs/openwrt-remote-access-tailscale.ru.md

Быстрый запуск:

wget -O /tmp/remote.sh \
  https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main/scripts/install-remote-access-tailscale.sh

chmod +x /tmp/remote.sh

sh /tmp/remote.sh

Скрипт отдельно спросит:

Tailscale auth key
Tailscale router name

Рекомендуемые параметры auth key в Tailscale:

Reusable: ON
Ephemeral: OFF
Tags: OFF
Expiration: 90 days

После настройки:

tailscale status
tailscale ip -4

Подключение:

ssh root@TAILSCALE_IP

LuCI:

http://TAILSCALE_IP/

---

## Команды для сохранения на GitHub с Windows

```powershell
cd C:\Users\Podvoz\Downloads\podkop-remnawave-subscription\podkop-remnawave-subscription

notepad .\scripts\install-remote-access-tailscale.sh
notepad .\docs\openwrt-remote-access-tailscale.ru.md
notepad .\README.ru.md

После замены:

$files = @(
  ".\scripts\install-remote-access-tailscale.sh",
  ".\docs\openwrt-remote-access-tailscale.ru.md",
  ".\README.ru.md"
)

foreach ($f in $files) {
  $s = Get-Content $f -Raw -Encoding UTF8
  $s = $s -replace "`r`n", "`n"
  $s = $s.TrimStart([char]0xFEFF)
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText((Resolve-Path $f), $s, $utf8NoBom)
}

git status
git add .\scripts\install-remote-access-tailscale.sh .\docs\openwrt-remote-access-tailscale.ru.md .\README.ru.md
git commit -m "Document and improve Tailscale remote access"
git pull --rebase origin main
git push

После push проверь на роутере:

wget -O /tmp/remote.sh \
  https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main/scripts/install-remote-access-tailscale.sh

wc -l /tmp/remote.sh
head -n 20 /tmp/remote.sh

Ожидаемо: много строк, начало с #!/bin/sh, затем set -eu, а не одна длинная строка.
