# PR #7: технический аудит 23.11.2026

> **PRODUCTION NO-GO:** прежний план внедрения/rollback недостаточен для удалённого владельца.
> Сначала [независимое восстановление и Stage1](independent-rollback.ru.md).
> Команды ниже — исторический проект; не выполнять до новой приёмки и разрешения.

Production не изменён. Это повторный технический разбор отдельным проходом;
внешнего независимого рецензента или подтверждения production-ready пока нет.

## BLOCKER — исправлены в ветке

| Дефект | Исправление и regression |
|---|---|
| На VM202 нет timeout, включая BusyBox applet | Встроенный bounded_run с TERM/KILL, cleanup child/watchdog, без установки пакетов; regression со stalled child |
| Stop sing-box до DIRECT DNS оставлял upstream 127.0.0.42 без процесса | Library: barrier → remove interception → DIRECT DNS + успешный DNS-запрос → stop. Ошибки DNS/удаления не останавливают upstream |
| Ошибка restart dnsmasq оставляла изменённый файл; следующий tick считал его применённым | Возврат предыдущего файла, одна компенсация restart, persistent dns-pending до успешного применения. Тест прерванной границы disk/runtime |
| Всегда 300 секунд DIRECT после reboot | Boot пропускает cooldown, но сохраняет 3 реальные успешные пробы. Cooldown после неудачного recovery остаётся |
| Изменение dont_touch_dhcp могло дать штатному stop переписать DIRECT DNS | Recovery запрещён без dont_touch_dhcp=1; fail-open использует только stop sing-box при изменённом профиле |
| Pending UCI мог появиться во время HTTP preflight | Hash привязан к staged copy (исключает гонку copy/hash); повторная проверка podkop/dhcp под control lock перед journal |
| Ошибка boot не запускала watchdog; ошибки tick скрывались | Daemon запускается даже после временной ошибки boot; ошибки возвращаются и журналируются один раз до успеха; pending journal остаётся до полного rollback |
| Ручной rollback менял DNS без компенсации и возвращал старый updater до проверок | EXIT trap → DIRECT, locks, 3 preflight, activate_normal, затем восстановление executable/autostart |

Изменённые файлы: [library](../scripts/podkop-failover-lib.sh),
[guard](../scripts/podkop-failover-guard.sh), [updater](../scripts/update-podkop-from-remnawave.sh),
[regression](../tests/test-failover.mjs), [rollback](fail-open.ru.md).

## PASS — read-only VM202

23.11.2026 05:52–05:55 +05: SSH alias openwrt-202, hostname Proxmox-Router.
WAN eth1, gateway 188.226.97.1; LAN br-lan. Podkop interface set содержит br-lan.
Правило IPv4 priority105 fwmark0x100000/0x100000 → podkop, единственный маршрут
в этой таблице local default dev lo. Output bypass mark0x200000 подтверждён.
ZeroTier ztc25gwuwx, маршрут 192.168.1.0/24 через 172.28.28.1 сохранён.
IPv6: только link-local br-lan/ZeroTier, default отсутствует; отдельного Podkop ip6 rule нет.
В fw4 не найдено ссылок 127.0.0.42/1602 или DNS dport53 redirect/dnat по проверенному фильтру.
main=7, USA=1; DNS server127.0.0.42, noresolv1, dont_touch_dhcp1.
DNS слушает LAN, loopback и ZeroTier; API192.168.0.1:9090.
S19dnsmasq/S99podkop включены; sing-box отдельно выключен, ZeroTier включён.
Порты17890–17892 не обнаружены среди TCP listeners. timeout и BusyBox timeout
applet отсутствуют; остальные command dependencies доступны. HTTP delay direct/main/USA
237/137/142ms, запросы dnsmasq и FakeIP успешны.

## PASS — локальная проверка

29 integration tests: реальные OpenWrt ash/UCI, Podkop0.7.24 parser, sing-box1.13.21,
loopback VLESS, HTTP/HTTPS с TLS verification. Проверены пустая USA, неверная подписка,
HTTP503/скачивание, неверные credentials, manual keys, параллельный updater,
3 неудачи/3 успеха, boot journal, sticky DIRECT, bounded logs, DNS restart failure,
nft barrier/removal/unblock failures, failed recovery, interrupted DNS transaction,
частичный rollback с повтором, смена ownership DNS и rate limit DNS restart.
Существующие bootstrap static/IPK/runtime-state checks и shell/JS syntax проходят.

## WARNING / запреты внедрения

- nft/ip, dnsmasq/init, runtime API моделируются. Живой kernel/procd и LAN приёмка
  не выполнены; это BLOCKER для объявления production-ready, а не для Draft PR.
- Нельзя гарантировать интернет при отказе самого WAN, dnsmasq, диска или kernel.
  Если DIRECT DNS нельзя применить, sing-box сохраняется, переключение возвращает
  ошибку; нужен Console. Не выдавать такую ошибку за успешный FAIL_OPEN.
- SIGKILL/отключение питания между произвольными системными вызовами не покрыты
  исчерпывающим crash harness; journal покрывает замену конфигурации и DNS boundary.
- Guard управляет первым dnsmasq и текущим IPv4 профилем. Появление WAN IPv6,
  новых instances, чужих правил в podkop или перенаправлений DNS означает STOP.
- Нельзя менять LuCI/UCI одновременно: LuCI не использует наш flock.
- Штатный stop Podkop flush своей route table допустим только после подтверждения
  её исключительной принадлежности. Глобальных flush ruleset/rules нет.
- Обнаружены повторяющиеся штатные nft rules от прежних запусков; не исправлялись.
- Частичная потеря USA вызывает общий DIRECT: безопасный отдельный fallback
  установленной конфигурацией не подтверждён. DIRECT раскрывает IP провайдера.
- ShellCheck отсутствует. Проверка boot локально моделирует потерю /tmp, не reboot VM.
- Generic installer не устанавливает guard: нельзя выкатывать ветку через общий mirror.

## Матрица приёмки — только после отдельного разрешения

Для КАЖДОЙ строки: LAN DNS + HTTP + HTTPS, SSH текущей/новой сессией, LuCI,
ZeroTier reachability и сравнение его маршрутов. Ping/PID недостаточны.

| Контрольная точка | Критерий GO | STOP/ROLLBACK |
|---|---|---|
| A. Console + backup + inventory | Backup читается, topology/DNS/marks совпадают, сторонних rules нет | STOP без изменения служб |
| B. Файлы + prepare, сервис ещё выключен | Native check и shadow main/USA/WAN успешны; DNS baseline сохранён | STOP; не заменять updater/автозапуск |
| C. Окно без cron updater, locks | Нет старого updater/list-update, locks получены | STOP; старый updater locks не соблюдает |
| D. Guard boot → DIRECT | DNS реальные ответы, WAN HTTP/HTTPS, cached FakeIP отвергается; SSH/LuCI/ZeroTier целы | Сохранить Console; не останавливать sing-box вручную при DNS error; rollback по инструкции |
| E. Recovery | 3 последовательные успешные пробы на интервале30s, затем runtime DNS/main/USA; NORMAL | После ошибки DIRECT + cooldown; повторные start вручную запрещены |
| F. Empty USA / bad response / HTTP503 | Updater отклоняет без изменения ключей/runtime, нет секретов в log | STOP updater, вернуть backup при изменении файлов |
| G. Dead VPN / stopped process / DNS proxy | После3 отказов DIRECT; DNS не зависит от остановленного процесса | Немедленный rollback при потере WAN/SSH/DNS |
| H. Отказ на каждой границе recovery | При отказах start/health/DNS/unblock компенсация DIRECT, journal сохраняется до завершения | Console; проверить DNS до любого stop; rollback с locks |
| I. Возврат VPN | 300s cooldown после отказа +3 успеха, NORMAL; без колебаний | Оставить sticky DIRECT, расследовать |
| J. Reboot, отдельно согласованный | DIRECT с начала, без S99 race; 3 успеха без лишних300s; SSH/ZeroTier | Console и rollback; до reboot сохранять рабочую сессию и backup |

Ни одна аварийная строка G–J на VM202 в этом аудите не выполнялась.
Команды backup/внедрения/компенсируемого rollback — в [основной инструкции](fail-open.ru.md).
