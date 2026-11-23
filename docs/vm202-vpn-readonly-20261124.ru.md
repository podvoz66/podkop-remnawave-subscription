# R12 — первый read-only анализ VM202, 24.11.2026

Окно 01:41–01:48 +05 (23.11 20:41–20:48 UTC). Исходный GitHub/local HEAD
`ad501a52`, ветка `codex/r12-vm202-prod-diagnostics-20261124`; PR7 отдельно,
HEAD `7b922be`. [Очищенные доказательства](evidence/vm202-vpn-readonly-20261124.json).
Никаких записей на VM202/PVE, restart, изменения selector, cron, firewall/DNS,
Remnawave или ключей. API delay — диагностические запросы, могут обновить history,
но не являются изменением конфигурации или выбранного выхода.

## Факты и матрица

VM202 Proxmox-Router: uptime21h34+, btime1795388861, sing-box PID330,
1.14.4-pdk-r28, failsafe PID19777 running, liveness=1/download_check=1.
Низкий PID не доказывает новый reboot: uptime соответствует прежней загрузке.
main8/USA3, DNS127.0.0.42 отвечает, прямой WAN HTTPS200 с bound eth1 и фиксированным
IP; rule105 mark0x100000→podkop, local default lo в отдельной таблице, fw4/PodkopTable.
Это router-origin проверки, не сертификация всех LAN клиентов/FakeIP/ZeroTier.

| Узел / tag | Текущее состояние | Доказательство |
|---|---|---|
| AUT manual main-1 | WORKING | HTTPS URLTest delay205ms |
| AUT rwsub main-2 | WORKING | delay212ms |
| AUT alias USA-1 | WORKING | delay233ms, ранее history пустая |
| Germany REALITY main-6 | WORKING сейчас; INVESTIGATE стабильность | delay147ms, ранее реальные15–16s timeouts |
| Germany Hysteria2 main-7 | WORKING | delay138ms |
| vlessXHTTPtls-stream-up main-8 | WORKING | delay140ms |
| USA vlessRAWtlsVision-autoXRAY USA-2 | WORKING | delay146ms |
| USA Hysteria2 USA-3 | WORKING | delay146ms |
| on1x REALITY main-4 | KNOWN_EXTERNAL_FAILURE | владелец: недоступен из РФ, ticket; не тестировали/не меняли |
| on1x Hysteria2 main-5 | KNOWN_EXTERNAL_FAILURE | та же подтверждённая владельцем причина |
| Oslo main-3 | KNOWN_EXTERNAL_FAILURE | владелец: не оплачен; исключён из оценки engine |

WORKING означает успешную текущую HTTPS-пробу через указанный sing-box outbound,
не долгосрочную стабильность и не доказанную загрузку64KiB. Время измерений близкое,
не атомарный срез всех соединений. В отдельном контроле AUT/Germany прямые TCP+TLS
успешны: connect74.5/67.9ms, TLS169/158ms, HTTP200. Это обычный HTTPS fallback,
**не** REALITY handshake; сам REALITY проверен через рабочие native outbounds.
Первая telnet curl-проба отвергнута как невалидная: сборка не поддерживает этот
протокол, RC1 ничего не говорит о сетевой доступности.

## AUT: причина исторического N/A не доказана

Оба AUT main-1/main-2 указывают на один server aut.adeptpro.online:443;
разрешение в этом окне185.211.103.130. Полный generated outbound идентичен кроме
тега; UUID, public key и shortId сравнены только boolean без вывода значений.
USA-1 — ещё один идентичный outbound. TCP/VLESS, Vision, SNIaut.adeptpro.online,
uTLSchrome, REALITYenabled одинаковы. Germany имеет тот же protocol/flow/fingerprint,
но другой server179.254.108.170, SNIger.adeptpro.online.

**Сейчас несовместимость REALITY не воспроизводится.** Версии/журналы серверного
Xray не получены: существующие aliases не включают AUT, не создавали новый доступ.
Нельзя объявлять TLS/REALITY причиной прежнего timeout или назвать версию сервера
по клиентской сборке. Возможны перемежающиеся путь/сервер/проверка загрузкой;
различить их по этим данным нельзя. DNS/PBR общесистемного отказа сейчас не видно,
но специфические LAN/потоковые проблемы этими probe не исключены.

## URLTest и download-check

main-out выбрал main-urltest-out; при снимке группа выбрала Germany Hysteria2.
События: 01:32:42 main-8→main-6; 01:33:03 main-6→main-7;
01:34:02 main-7→main-2; 01:34:26 main-2→main-8;
01:35:47 main-8→main-6; 01:36:31 main-6→main-7.
В01:36:32–46 видны15.6–15.8s ошибки ранее созданных потоков черезmain-6.
Смена выбора не доказывает миграцию уже открытых потоков, поэтому ошибки после
переключения сами по себе не означают, что новый выбор проигнорирован.

Группы interval3m/tolerance50, probe gstatic generate_204; download_check1 сохранён.
Функция по [закреплённой документации engine](https://github.com/podkop-net/podkop-engine/blob/a9926c37fe5fbf57241aaea583ffc1ae717f835f/docs/FEATURES.ru.md)
проверяет64KiB перед переключением. Маленький delay успешен ≠ download-check PASS.
В узком свежем срезе нет нового download-error; исторический01:12 main-2 timeout
не позволяет установить причину. Следующий шаг — короткое пассивное окно по тегам
со временем small-probe/full-download/switch, без выключения проверки.

**Конфигурационные ограничения:** явных `fallbacks:[direct-out]` в обеих группах нет.
USA-out сейчас вручную выбран USA-2, а не USA-urltest-out: автоматический выбор группы
не управляет этой секцией. Engine fail-safe процесса не гарантирует DIRECT при
здоровом sing-box и полностью недоступных remote VPN. Ничего не переключали.

## USA updater: отдельный действующий дефект

SHA256 installed .real a561f878… и wrapper46eaef23… совпали с доказанным
[инцидентом08:00](incident-20261123-0800.ru.md). Старый код всё ещё принимает USA0,
удаляет links, commit/restart без обязательного rollback. Сейчас USA3 — не USA0.
Причина отсутствия US в историческом ответе неизвестна; подписку заново не скачивали.

[Updater PR7](../scripts/update-podkop-from-remnawave.sh) имеет download/temp-file,
nonempty main/USA, сохранение не-rwsub manual links, flock, native parser/shadow HTTP,
atomic rename и transaction recovery. **Нельзя просто скопировать его в production:**
он зависит от guard-lib/prepare и normal-dns snapshot; activate_normal ожидает
`dont_touch_dhcp=1`, тогда как установленный native failsafe используется с0.
Вручную помеченные rwsub links отдельно требуют provenance/managed-snapshot политики.

План исправления: независимый updater без установки второго watchdog; единая блокировка
cron/wrapper/list-guard; скачать во временный0600 файл, проверить HTTP/size/структуру,
составить candidate UCI и main/USA, сохранить previous-good + ручные ссылки по ownership,
native parser/check и реальные probes до активации; same-filesystem rename; post-health
или восстановление прежних файлов/managed snapshot и native STOP→DIRECT. Persistent
bounded journal только counts/status. Сначала LAB с engine-full/dont_touch_dhcp0,
пустой/нетUSA/500/timeout/concurrency и rollback всех фаз; только потом отдельный GO.

## Fail-safe: первый production fault-test пока STOP

Установленный failsafe SHA256976b7ae5… совпал с upstream pinned a9926c37.
Single crash: native respawn5s. Terminal:6 падений в600s, respawn retry5,
затем native stop Podkop; автостарта после terminal stop нет.
Hang: liveness20s/3 failures, примерно49–72s плюс условия arming/grace/list_update.
10–20s — целевое окно одного respawn, не обещание terminal fail-open.

PVE доступен codexops, pve-cluster active; systemd-run/socat установлены. sudo
разрешает LAB203/204 wrapper; root systemd-run не разрешён, VM202 recovery timer не
подготовлен. Другой guestctl root-wrapper существует, исходник недоступен; его
пригодность для202 **не доказана**, проверки обходом/операции не выполнялись.
VMA verify/cmp из checkpoint — проверенный архив, не доказанное восстановление.

Последовательность следующего согласования:
1. Сначала подготовить на LAB фиксированный host controller/timer с локальными assets,
   independent management, audit nonce, lock, timeout и журналом; проверить выполнение
   после разрыва Codespaces и неудачу guest SSH. Не выдавать guest timer за независимый.
2. Для202 отдельно согласовать узкий root-owned restore helper/таймер на PVE, без
   произвольного shell и без прав на другие VM; начать с harmless timer arm/fire/cancel.
   Предварительно read-only подтвердить PVE→guest SSH/serial и используемые fingerprints.
3. Только после доказательства таймера и нового GO: current guest config/init/cron/
   routes/rules/nft baseline0600, hash; arm host deadline; single crash только точного
   sing-box PID+starttime. Через5s ждать procd, через10–20s проверить DNS UDP/TCP,
   LAN HTTPS, SSH/LuCI/ZeroTier, native rules. Два здоровых среза → disarm.
4. Deadline без health-ACK: по доверенному LAN SSH запустить фиксированный native
   `/etc/init.d/podkop stop` → подтвердить DIRECT DNS/rules/HTTP. Затем, только при
   валидной неизменённой конфигурации, `/etc/init.d/podkop start` и новый полный health.
   Для SIGSTOP — перед этим SIGCONT только тому же PID/starttime; не другим процессам.
5. Terminal crash-loop и hang — отдельные более длинные окна, отдельное согласование,
   с тем же проверенным host timer; никаких restart/reboot/fault injection сейчас.

**STOP/ограничение:** при недоступности guest SSH/serial или зависшем guest kernel
такой restore не выполнится. Требуется отдельно испытанное host fencing/offline
restore либо резервный маршрутизатор. Автоматические stop/restore/reboot202 сейчас
не разрешены и не испытаны; гарантировать автономный возврат интернета нельзя.

## Изменения и rollback этого анализа

Изменены только документация/evidence в Git-ветке; production baseline не менялся,
поэтому сетевой rollback сейчас не требуется. Точные файлы будущего rollback надо
брать из **нового pre-test snapshot**, а не вслепую копировать старый
`podkop-before-failsafe`: он мог вернуть dont_touch_dhcp1 и нарушить native DNS restore.
Package rollback на старый sing-box отдельный: сохранённый binary не заменяет APK;
VMA restore требует отдельного GO и обычно остановки VM, вне первого короткого теста.
