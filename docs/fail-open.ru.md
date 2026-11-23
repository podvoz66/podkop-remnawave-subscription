# Podkop Fail-Open: проект внедрения VM 202

**Не установлен на production. Все команды внедрения ниже требуют отдельного согласования.**
Цель — доступ через WAN при отказе Podkop/VPN. DIRECT раскрывает IP провайдера,
отключает VPN для выбранных ранее сайтов и может сделать заблокированные сайты
недоступными. Это осознанная политика доступности, не сохранение VPN-приватности.

## Основания и совместимость

Подтверждённая система: OpenWrt 25.12.4 x86_64, Podkop 0.7.24, sing-box 1.13.21.
В 04:07–04:19 23.11.2026 сборка падала на пустой USA. В 04:23 — успешный запуск.
Текущая USA равна USA из backup перед обновлением 04:00. Установленный `.real.sh`
безусловно удаляет/перезаписывает USA и проверяет только наличие процесса.
GitHub main на момент сравнения (627cd90, blob updater 08872aa2) уже оставляет
пустую USA без изменений, но откладывает runtime reload и не имеет этого guard.
Ответ подписки за 04:00 утра утрачен вместе с `/tmp`-журналом; точная историческая
цепочка удаления и причина reboot пока не доказаны. Watchcat ping_reboot=6h активен.

Данная ветка предназначена для согласованной миграции существующей VM202.
Не применять её старые bootstrap/install entrypoints для массового развёртывания:
они ещё не устанавливают новую библиотеку/сервис. Новый updater без библиотеки
завершается с кодом 78 до изменения ключей. Production mirror/пинованные релизы
этой веткой не обновляются. Конфигурации сервера Remnawave не меняются.

## Архитектура

- [Updater](../scripts/update-podkop-from-remnawave.sh): HTTPS download во временный
  файл, URI/base64 only, ограничение 1 MiB, проверка main/USA и сохранение всех
  ручных ссылок. Пустая свежая обязательная секция отклоняет ВСЮ подписку.
  Нераспознанные протоколы/JSON/HTML и небезопасное quoting отклоняются.
- Candidate строится через native UCI в отдельном каталоге. Штатные pure
  facade/manager Podkop переводят ссылки в изолированный sing-box config;
  `/usr/bin/podkop` не запускается для сборки кандидата.
- Временный sing-box слушает только 127.0.0.1:17890–17892. Проверяется HTTP(S)
  через direct/main/USA; реальный TLS verification включён. Ни TPROXY, ни DNS
  listener, ни FakeIP, ни Clash API в нём нет. Отдельные probe-ключи не создаются.
  Outbound/DNS mark=0x200000 совпадает с исключением текущего Podkop. На другой
  топологии это значение требует повторной проверки.
- После preflight updater входит в DIRECT, сохраняет journal и заменяет только
  UCI-файл Podkop через same-directory rename. Затем штатный старт и проверки
  runtime main/USA/DNS. При ошибке — предыдущие ключи/config и DIRECT до recovery.
  Нельзя атомарно одной операцией изменить UCI, nft и работающие процессы;
  гарантируется атомарность каждого файла и безопасная последовательность.
- [Guard](../scripts/podkop-failover-guard.sh): NORMAL проверяет UCI, runtime config,
  процесс, TPROXY table/rule, DNS/FakeIP и API delay каждого обязательного outbound.
  API delay выполняет запрос к внешнему HTTP(S) ресурсу, а не только смотрит PID.
  direct-out проверяется отдельно и не считается VPN-пробой.
  Если API недоступен, WAN обозначается UNKNOWN, а не «сломанный». В DIRECT
  отдельный curl привязывается к WAN_DEVICE=eth1 и не использует sing-box;
  при недоступном WAN recovery не запускается.
- Три последовательных отказа включают FAIL_OPEN. Ошибки разных компонентов
  считаются подряд, один полностью успешный проход сбрасывает счётчик.
- FAIL_OPEN: FakeIP barrier, удаление только PodkopTable и точного правила
  priority105/mark0x100000/table podkop, удаление local default dev lo из этой таблицы.
  Затем DIRECT DNS; только после успешного restart dnsmasq и DNS-запроса останавливается sing-box
  через штатный stop Podkop (при dont_touch_dhcp=1). Иначе используется только stop
  sing-box, чтобы штатный Podkop не вернул DNS к остановленному upstream.
  В своей таблице podkop_failopen блокируется 198.18.0.0/15, чтобы cached FakeIP не
  утекал в WAN. Новые DNS-ответы реальные. Старым приложениям может потребоваться
  повторное разрешение имени/переподключение до истечения их DNS-кэша.
- DNS переключает только server/noresolv/resolvfile/cachesize первого dnsmasq,
  сохраняя остальные DHCP-секции. DIRECT DNS: 1.1.1.1, 9.9.9.9 через WAN.
  Исходные четыре поля сохраняются локально и возвращаются после recovery.
  Ошибка restart возвращает предыдущий файл и делает одну попытку восстановления
  dnsmasq. После ошибки повторные restart ограничены cooldown 300s. Persistent dns-pending заставляет повторить применение после прерывания
  между rename и restart. При неудаче DIRECT DNS sing-box не останавливается.
  Аппаратный/устойчивый отказ dnsmasq требует Console; доступность не гарантируется.
- RECOVERY: после отказа cooldown 300 секунд и три подряд успешных shadow preflight.
  На холодной загрузке cooldown пропускается: три проверки с интервалом 30 секунд
  позволяют начать восстановление примерно через 60 секунд плюс длительность probes.
  До подтверждения трафик остаётся DIRECT. Затем штатный старт, runtime/DNS checks,
  восстановление DNS и снятие FakeIP blocker. Неудачная активация снова DIRECT и cooldown.
  `status` показывает phase=RECOVERY при накоплении успешных проверок.
- Изоляция только USA не реализуется через недоказанную смену selector: в текущей
  конфигурации direct-out не входит в selector USA. Отказ любой обязательной
  секции включает общий DIRECT. Исправные VPN временно отключаются ради WAN.
- Runtime счётчики находятся в `/tmp`; после reboot неизвестное состояние означает
  DIRECT, затем подтверждённое recovery. Journal и manual DIRECT сохраняются в /etc.
- Общий flock сериализует только изменения guard/updater; отдельные locks защищают
  download и shadow process. Скачивание не останавливает 30-секундный мониторинг.
  Сроки проб ограничены встроенным bounded_run: установленный BusyBox не имеет
  timeout applet, новые пакеты не требуются; если проход длится дольше 30 секунд, следующий начнётся
  после него, параллельные экземпляры не запускаются. Это не realtime watchdog.
- Постоянный журнал `/etc/podkop-failover/events.log`: фиксированные сообщения,
  не более примерно 64 KiB + один предыдущий файл. Две последние transaction
  backup сохраняются локально с правами 0700/0600, ключи не печатаются.

## Обязательные ограничения внедрения

1. Текущий kernel должен поддерживать nft reject/flock; проверить jq,
   curl, uci, sing-box и библиотеки Podkop. Новых пакетов без согласования не ставить.
2. Порты 17890–17892 должны быть свободны. PodkopTable и таблица podkop/105 должны
   принадлежать только Podkop. Если там сторонние маршруты — STOP: штатный stop
   Podkop очищает всю свою route table. Текущая диагностика видела только local default.
3. Проверить отсутствие сторонних DNS DNAT/redirect к sing-box в fw4 и ip6tables.
   Guard их не удаляет. Не выкатывать, если такие перенаправления мешают DIRECT.
4. На VM202 WAN IPv4. IPv6 TPROXY/другие dnsmasq instances этим кодом не управляются.
5. Штатный автозапуск Podkop/sing-box должен уступить управление guard, иначе boot
   создаст перехват после включения DIRECT. Другие автоматические старты/cron должны
   быть проинвентаризированы. Guard не меняет cron сам.
6. Snapshot normal DNS должен быть сделан в исправном NORMAL. Нельзя заменять его
   снимком уже переключённого DIRECT. При последующих ручных изменениях DNS нужен
   отдельный согласованный refresh baseline. LuCI не использует наш lock: не менять
   настройки одновременно с обновлением. Updater проверяет hash перед применением.
7. Tailscale/ZeroTier не останавливаются, таблицы 52 и zt-маршруты не затрагиваются.
   Однако приложения на роутере, зависимые от DNS, могут кратко переподключаться.
8. Перед активацией обновления будет краткий DIRECT даже при здоровом VPN.
   Новый updater намеренно меняет прежнюю политику deferred reload. Это следует
   согласовать до публикации в общий bootstrap/mirror.
9. Интервал 30 секунд/три отказа означает окно обнаружения примерно 60–90 секунд
   плюс время probes. Нулевая потеря пакетов и доступность при отказе самого WAN,
   dnsmasq, kernel или хранилища не гарантируются. Нужны стендовые/production тесты.

## Локальные тесты

На Linux x86_64: Node.js, jq, curl, openssl, flock и доступный SSH alias VM202 для
однократного чтения НЕСЕКРЕТНЫХ runtime binaries/libraries (можно передать заранее
подготовленный fixture directory). Подготовка не меняет и не запускает код на VM:

```sh
sh tests/prepare-openwrt-runtime.sh /tmp/podkop-test-runtime openwrt-202
OPENWRT_RUNTIME=/tmp/podkop-test-runtime flock /tmp/podkop-suite.lock node --test --test-concurrency=1 tests/test-failover.mjs
```

Тесты запускают реальные ash/libuci, Podkop facade и sing-box 1.13.21 в Codespace.
Временные origin HTTP/HTTPS и VLESS peer находятся на loopback. HTTPS использует
временный сертификат с проверкой доверия; curl не запускается с -k. Native payload
копируется только в /tmp и не коммитится. Все UUID/подписки тестов синтетические.
Для непривилегированного локального процесса mark=0; production mark=0x200000.

Mock boundaries: nft/ip, init services, DNS responses и runtime Clash API. Поэтому
эти тесты проверяют state machine/точные команды и real shadow traffic, но НЕ
подтверждают реальное применение nft/DNS/procd/boot на OpenWrt. Тест reboot —
очистка volatile state и recovery journal, не перезагрузка VM. Проверка клиентов,
LuCI, SSH/ZeroTier и controlled faults остаются этапом после согласования.

Итог локального прогона 23.11.2026: 29/29 integration tests PASS; существующие
bootstrap static, IPK validators и runtime-state tests PASS. ShellCheck отсутствует;
syntax проверен shell-интерпретаторами и Node.js. Новая версия не запускалась на VM202.

## Предлагаемое внедрение — НЕ выполнять до разрешения

Контролируемая матрица приёмки (каждая аварийная операция согласуется отдельно):

| Сценарий | Ожидаемый результат |
|---|---|
| Нормальная работа | main/USA HTTP(S), DNS/FakeIP, direct-out; LAN, SSH/LuCI/ZeroTier работают |
| Пустая USA / повреждённая подписка | updater отвергает candidate; ключи и runtime не меняются |
| HTTP 503 / timeout Remnawave | прежние ключи сохранены, журнал без URL |
| Отказ ключей только USA | после 3 отказов общий DIRECT; причина изоляции описана выше |
| Остановка sing-box | DIRECT DNS и WAN, без утечки cached FakeIP |
| Отказ DNS-прокси | DIRECT; здоровый процесс не маскирует отказ DNS |
| Возврат VPN | cooldown + 3 shadow HTTP(S), затем runtime/DNS и NORMAL |
| Reboot гостя | сначала DIRECT, затем подтверждённый recovery; ручной DIRECT сохраняется |

В каждом сценарии проверить DNS и HTTP/HTTPS с реального LAN-клиента, SSH/LuCI,
ZeroTier и неизменность его маршрутов. Ping и PID не являются критериями приёмки.
Reboot проводится последним, при открытой Console и подготовленном rollback.

Открыть Console VM202 и держать её до завершения. Скопировать четыре проверенных
файла из этой Git-ветки в `/tmp/podkop-failopen-stage/` через существующий SSH alias.
Не скачивать исполняемый код с latest/main в процессе установки.

Сначала read-only проверки ограничений выше. Затем backup (содержит секреты,
остаётся только на роутере; его нельзя прикладывать к GitHub):

```sh
set -eu
umask 077
B="/root/podkop-failopen-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -m 700 "$B"
cp -p /etc/config/podkop /etc/config/dhcp /etc/sing-box/config.json "$B/"
cp -p /usr/bin/update-podkop-from-remnawave.sh "$B/updater-wrapper"
cp -p /usr/bin/update-podkop-from-remnawave.real.sh "$B/updater-real"
cp -p /etc/crontabs/root "$B/root-cron"
if /etc/init.d/podkop enabled; then echo yes; else echo no; fi > "$B/podkop-enabled"
if /etc/init.d/sing-box enabled; then echo yes; else echo no; fi > "$B/singbox-enabled"
echo "BACKUP=$B"
```

Установка файлов и baseline (ещё без включения сервиса):

```sh
test ! -e /usr/lib/podkop-failover.sh
test ! -e /usr/bin/podkop-failover-guard
test ! -e /etc/init.d/podkop-failover-guard
cp /tmp/podkop-failopen-stage/podkop-failover-lib.sh /usr/lib/podkop-failover.sh
cp /tmp/podkop-failopen-stage/podkop-failover-guard.sh /usr/bin/podkop-failover-guard
cp /tmp/podkop-failopen-stage/podkop-failover-guard.init /etc/init.d/podkop-failover-guard
chmod 700 /usr/lib/podkop-failover.sh /usr/bin/podkop-failover-guard /etc/init.d/podkop-failover-guard
/usr/bin/podkop-failover-guard prepare
printf '%s\n' "$B" > /etc/podkop-failover/deployment-backup
```

Отдельно согласовать запуск/краткий DIRECT. Перед заменой updater убедиться, что
старый cron updater не выполняется; в рамках окна обслуживания взять общий lock
и subscription lock. Не изменять cron и не завершать старый процесс принудительно.

```sh
exec 8>/var/lock/podkop-subscription.lock
flock -n 8
exec 9>/var/lock/podkop-control.lock
flock -n 9
cp /tmp/podkop-failopen-stage/update-podkop-from-remnawave.sh /usr/bin/update-podkop-from-remnawave.real.sh.new
chmod 700 /usr/bin/update-podkop-from-remnawave.real.sh.new
mv /usr/bin/update-podkop-from-remnawave.real.sh.new /usr/bin/update-podkop-from-remnawave.real.sh
printf '#!/bin/sh\nexec /usr/bin/update-podkop-from-remnawave.real.sh "$@"\n' > /usr/bin/update-podkop-from-remnawave.sh.new
chmod 700 /usr/bin/update-podkop-from-remnawave.sh.new
mv /usr/bin/update-podkop-from-remnawave.sh.new /usr/bin/update-podkop-from-remnawave.sh
flock -u 9
flock -u 8
/etc/init.d/podkop disable
/etc/init.d/sing-box disable
/etc/init.d/podkop-failover-guard enable
/etc/init.d/podkop-failover-guard start
```

Старый updater не использует новые locks: наличие этих locks НЕ доказывает, что
старый процесс отсутствует. Время обслуживания должно исключить пересечение.
Запуск guard входит в DIRECT, затем три успешных проверки без boot cooldown. Проверить
DNS/HTTP/HTTPS с LAN и роутера, SSH, LuCI, ZeroTier и сохранность маршрутов. Только
после этого согласовывать fault-тесты и последнюю перезагрузку OpenWrt.

## Эксплуатация

```sh
/usr/bin/podkop-failover-guard status
/usr/bin/podkop-failover-guard fail-open   # sticky DIRECT, сохраняется после reboot
/usr/bin/podkop-failover-guard auto        # разрешить проверяемое recovery
/usr/bin/podkop-failover-guard normal      # то же; не принудительный обход проверок
/usr/bin/update-podkop-from-remnawave.sh --dry-run
tail -n 30 /etc/podkop-failover/events.log
```

Не вызывать podkop start/restart вручную в обход guard. Не включать обратно его
штатный автозапуск. Старый subnet guard сохраняется, но не считается Fail-Open.

## Точный rollback после согласованного внедрения

Команды рассчитаны на deployment backup выше и установленный новый guard. Сначала
DIRECT и остановка только guard daemon; новый код не удаляется до успешного отката.

```sh
set -eu
B=$(cat /etc/podkop-failover/deployment-backup)
test -f "$B/podkop"
/usr/bin/podkop-failover-guard fail-open
/etc/init.d/podkop-failover-guard stop
/etc/init.d/podkop-failover-guard disable
. /usr/lib/podkop-failover.sh
guard_setup
exec 8>/var/lock/podkop-subscription.lock
flock -n 8
lock_control
# EXIT compensation uses the library directly: no recursive lock acquisition.
rollback_failed() {
    trap - EXIT INT TERM
    fail_open || echo 'STOP: DIRECT incomplete; keep Console, do not stop sing-box manually'
    echo 'STOP/ROLLBACK: previous services must not be enabled until inspection'
    exit 1
}
trap rollback_failed EXIT INT TERM
atomic_copy "$B/podkop" /etc/config/podkop
atomic_copy "$B/config.json" /etc/sing-box/config.json
atomic_copy "$B/dhcp" "$DATA/normal-dns/dhcp"
# Previous keys must pass real traffic before normal interception returns.
for attempt in 1 2 3; do
    shadow_health "$CFG"
    [ "$attempt" = 3 ] || sleep 30
done
activate_normal
# Restore old executables only after healthy routing/DNS. Cron must be quiescent.
cp -p "$B/updater-wrapper" /usr/bin/update-podkop-from-remnawave.sh
cp -p "$B/updater-real" /usr/bin/update-podkop-from-remnawave.real.sh
if grep -qx yes "$B/podkop-enabled"; then /etc/init.d/podkop enable; else /etc/init.d/podkop disable; fi
if grep -qx yes "$B/singbox-enabled"; then /etc/init.d/sing-box enable; else /etc/init.d/sing-box disable; fi
rm -f "$DATA/manual-direct"
trap - EXIT INT TERM
flock -u 9
flock -u 8
```

После rollback проверить реальные main/USA HTTP probes и LAN. Если старые ключи
уже не работают — выбрать guard fail-open и оставить исправный DIRECT до анализа.
Старый updater после отката снова содержит исходный дефект: это возврат к backup,
не исправление. Никакие SSH-ключи, Tailscale/ZeroTier или firewall fw4 не восстанавливаются
из этого backup и не изменяются. Согласованное удаление четырёх новых файлов и
локального состояния — отдельная уборка после успешных проверок.

## Аудит PR #7 и контрольные точки

См. [матрицу аудита и приёмки](audit-pr7.ru.md). Cron не изменяется новым кодом;
при rollback его backup не перезаписывает параллельные изменения пользователя.
Откат разрешён только в окне без старого updater: старый код не соблюдает locks.
