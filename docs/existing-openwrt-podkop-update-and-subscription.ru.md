\# Обновление существующего OpenWrt-роутера с уже установленным Podkop



Инструкция для роутеров OpenWrt 24.10.x, на которых Podkop уже установлен и настроен.



Цель: обновить Podkop и добавить автообновление ключей из Remnawave-подписки, не стирая ручные ключи пользователя.



Репозиторий проекта:



```text

https://github.com/podvoz66/podkop-remnawave-subscription

```



\---



\## Когда использовать эту инструкцию



Использовать для роутеров, где уже есть Podkop:



```sh

test -f /etc/config/podkop \&\& echo "Podkop config exists"

```



Для полностью чистого роутера использовать другую инструкцию:



```text

docs/openwrt-router-install.ru.md

```



\---



\## Что нужно заранее



1\. Роутер с OpenWrt 24.10.x.

2\. Уже установленный Podkop.

3\. SSH-доступ к роутеру под `root`.

4\. Отдельный пользователь в Remnawave для этого роутера.

5\. Subscription URL этого пользователя.



Рекомендуемая подписка для роутера:



\* VLESS TCP REALITY;

\* direct/router nodes;

\* без mobile/XHTTP/SS, если они не нужны этому роутеру.



\---



\## Основная команда



На роутере выполнить:



```sh

wget -O - https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main/scripts/install-subscription-on-existing-podkop.sh | sh

```



Скрипт спросит:



```text

Paste Remnawave subscription URL:

```



Вставить ссылку подписки пользователя из Remnawave:



```text

https://sub.adeptpro.online/НОВЫЙ\_TOKEN

```



\---



\## Вариант одной строкой



```sh

SUB\_URL='https://sub.adeptpro.online/НОВЫЙ\_TOKEN' wget -O - https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main/scripts/install-subscription-on-existing-podkop.sh | sh

```



Безопаснее использовать основной вариант, чтобы token не попадал в историю shell.



\---



\## Если роутер находится в домашней сети с Nginx Proxy Manager



Если `sub.adeptpro.online` внутри LAN должен открываться через NPM на `192.168.0.172`, использовать:



```sh

SUB\_HOST\_IP='192.168.0.172' wget -O - https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main/scripts/install-subscription-on-existing-podkop.sh | sh

```



Или вместе с подпиской:



```sh

SUB\_URL='https://sub.adeptpro.online/НОВЫЙ\_TOKEN' SUB\_HOST\_IP='192.168.0.172' wget -O - https://raw.githubusercontent.com/podvoz66/podkop-remnawave-subscription/main/scripts/install-subscription-on-existing-podkop.sh | sh

```



\---



\## Что делает скрипт



Скрипт:



\* проверяет, что это OpenWrt;

\* проверяет наличие `/etc/config/podkop`;

\* делает backup текущего Podkop-конфига;

\* обновляет списки пакетов;

\* ставит базовые утилиты;

\* запускает официальный installer/update Podkop;

\* устанавливает Remnawave updater;

\* сохраняет subscription URL в `/etc/podkop-remnawave/subscription.conf`;

\* добавляет cron каждые 4 часа;

\* делает первый запуск обновления;

\* перезапускает Podkop/sing-box;

\* показывает проверку состояния.



\---



\## Логика обновления ключей



Remnawave updater:



\* скачивает актуальную Remnawave-подписку;

\* извлекает VLESS-ссылки;

\* добавляет `spx=%2F` для Reality-ссылок, если его нет;

\* помечает свои ссылки суффиксом `-rwsub`;

\* при следующем обновлении удаляет только старые `-rwsub` ссылки;

\* ручные ключи без `-rwsub` не трогает;

\* если секция `USA` уже существует, US-ссылки идут в `USA`;

\* если секции `USA` нет, все Remnawave-ссылки идут в `main`.



\---



\## Проверка после установки



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

cron update-podkop-from-remnawave.sh есть

main содержит Remnawave-ссылки с -rwsub

ручные ссылки без -rwsub сохранены

```



\---



\## Где хранится subscription URL



```sh

/etc/podkop-remnawave/subscription.conf

```



Проверить:



```sh

cat /etc/podkop-remnawave/subscription.conf

```



Права:



```sh

chmod 600 /etc/podkop-remnawave/subscription.conf

```



\---



\## Ручной запуск обновления



```sh

/usr/bin/update-podkop-from-remnawave.sh

```



Лог:



```sh

cat /tmp/podkop-sub-update.log

```



\---



\## Backup



Backup-и находятся здесь:



```sh

/etc/podkop-remnawave/backups/

```



Также updater создаёт backup Podkop-конфига:



```sh

/etc/config/podkop.backup.\*

```



\---



\## Если что-то пошло не так



Проверить Podkop/sing-box:



```sh

pgrep -af sing-box



sing-box check -c /etc/sing-box/config.json



logread | grep -iE 'podkop|sing-box|singbox|error|failed|fatal|panic|invalid' | tail -n 160

```



Перезапустить:



```sh

/etc/init.d/podkop restart

sleep 10

pgrep -af sing-box

```



\---



\## Важно по безопасности



Не добавлять реальные subscription URL, token, UUID, VLESS-ссылки и приватные ключи в GitHub.



В GitHub должны быть только:



\* скрипты;

\* инструкции;

\* примеры без секретов.



Реальные данные хранятся только на роутере.



