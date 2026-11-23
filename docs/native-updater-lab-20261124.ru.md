# R12: native updater, пассивный URLTest и отдельный PVE deadline

Ветка `codex/r12-vm202-prod-diagnostics-20261124`; развитие `014e688` с сохранением
добавленного на GitHub checkpoint `47c68f1`. Текущее задание владельца разрешает
разработку updater и LAB, **не production**. Draft PR7 находится на другой ветке;
его head не подменять. В VM202 установлен владельцем native engine; этот факт
не означает установку новых скриптов из данного изменения.

## Изменение updater

[Updater](../scripts/update-podkop-from-remnawave.sh) выбирает native при
`dont_touch_dhcp=0`; [native library](../scripts/podkop-native-update-lib.sh)
использует штатный Podkop STOP/START и не устанавливает guard daemon, не меняет
владение DNS, cron, firewall или маршруты удалённого доступа. Общая
[библиотека](../scripts/podkop-failover-lib.sh) нужна для parser/HTTP-probes,
atomic_copy, bounded execution, lock и ограниченного persistent event log.

HTTPS download: отдельный private temp, HTTP errors/25s timeout/1MiB limit,
разбор plain/base64, supported links, непустой новый main **и** USA до объединения
с manual. Candidate UCI + sing-box check + реальный HTTP через DIRECT и обе
секции до config rename. Native baseline проверяется отдельно.

Manual не определяется суффиксом `rwsub`: удалять разрешено только точное
совпадение из предыдущего **собственного** managed snapshot. При первом переходе
все существующие ссылки сохраняются; совпавшая с новой подпиской существующая
ручная ссылка не присваивается updater. Старые автоматические ссылки поэтому
могут консервативно остаться до отдельно согласованной очистки. Одинаковые
побайтно ссылки, которые ранее уже были managed, невозможно различить как новую
ручную копию без отдельного реестра — не обещать такой provenance.

До применения сохраняется immutable previous-good: Podkop, DHCP, generated JSON,
managed snapshots и SHA256SUMS. `pending` + sync предшествуют atomic rename.
Успех фиксируется только после native readiness (config/PID/положительный DNS A)
и HTTP section probes; затем atomic managed snapshots и снятие pending. При
ошибке/TERM выполняется rollback с проверкой SHA. Если возврат VPN не подтверждён,
штатный STOP запрашивает DIRECT, pending остаётся. Повторный запуск сначала
восстанавливает pending, не скачивая новое обновление. Dry-run pending отвергает.
**SIGKILL, power loss и boot recovery немедленно не покрыты**: до следующего
запуска updater нет нового автономного boot hook.

DHCP backup не копируется слепо поверх DIRECT: в native0 DNS переключает штатный
Podkop. Слепое возвращение `127.0.0.42` при остановленном движке недопустимо.
Persistent log содержит только фиксированные сообщения; ротация 64KiB + один
предыдущий файл, private каталог. Два flock: subscription и control. Дочерние
native init/probe закрывают lock FDs. Внешние старые cron writers обязаны быть
проверены на совместимость отдельно; lock нового updater не блокирует код,
который этот lock не использует.

## LAB и доказательства

LAB203: OpenWrt25.12.4, Podkop0.7.24, engine **slim**1.14.4-r28, sing-box1.14.4-pdk-r28.
Production engine **full**; идентичность пакетов не заявляется. Два изолированных
Unix stream, default route наружу отсутствует. Синтетический VLESS/TLS endpoint
в LAB204; UUID не публикуется. У fixture VPN self-signed TLS разрешён только в
лабораторной ссылке; HTTPS подписки и HTTPS клиента проверяют тестовый CA.

Сценарии: [cases203](../scripts/lab/r12-native-updater-cases203.sh),
[локальные regression](../tests/test-native-update-lib.sh). Baseline и секретные
runtime-файлы остаются private в `/root/r12-native-test` и
`/root/r12-native-updater-assets*`, не Git. [Доказательства](evidence/native-updater-lab-20261124.json).

Обнаруженные и исправляемые тестами ошибки не скрывать:
1. Native init возвращается до готовности config/procd/DNS; immediate check
   оставлял pending и DIRECT. Добавлен bounded readiness; DNS A через dig.
2. `shutdown_correctly` меняется native init. Rollback сравнивает все UCI keys,
   исключая только этот runtime flag; остальные изменения не игнорируются.
3. Собственный shadow probe мог остаться после успешного завершения, занимая
   порт/lock. Добавлены закрытие lock FDs, явное завершение и повторные probes.
   Старые orphan удалялись только после проверки точного PID/своего config path.
   Причина подтверждена минимальным тестом: внутри уже исполняемого outer EXIT
   вложенный EXIT trap не выполняется. Rollback вызывал health именно из outer
   EXIT. Теперь success/error/signal выполняют явный cleanup, trap остаётся страховкой.
   Standalone implicit EXIT исправен; общая неисправность ash не заявляется.
   Приёмка: rollback из outer EXIT, затем два probe и отсутствие orphan.
4. Старый static bootstrap test уже на `014e688` считает пять LAB-only restart
   строк "unguarded"; новый guest recovery helper также имеет намеренные LAB-only
   STOP/START. Этот static suite не объявляется green. Child-process tests сначала были
   заблокированы sandbox EPERM; после разрешённого запуска 11/11 PASS, включая
   bulk SHA/resume, deny recovery202/201/204 и observer fresh/stale regression.

## URLTest: доступность != стабильность

[Observer](../scripts/monitor-urltest-readonly.mjs) запускается в Codespaces:
`node scripts/monitor-urltest-readonly.mjs openwrt-202 50 30 > observer.jsonl`.
Только API read/logread; без delay requests, selector writes и VM файлов.
[Summarizer](../scripts/summarize-urltest-readonly.mjs) отделяет fresh/stale history.
Окно 24.11 **01:56:55–02:21:25 +05** (23.11 20:56:55–21:21:25 UTC):
50/50 API samples, 1469.945s. Main URLTest main8→main7→main8;
main1/2/6/7/8 имеют свежие delay. Main3/4/5 — без успешной history (известные
внешние on1x/Oslo не считать дефектом движка). USA selector pinned USA2;
все USA истории устарели относительно окна — текущий успех **не подтверждён**.

[Итог JSON](evidence/urltest-window-20261124.json) сохраняет redacted events.
Tail250 может пропустить burst; повторные строки дедуплицируются, это не точный
счётчик ошибок. В нём есть pre-window TIMEOUT, их нельзя выдавать за новые.
Редактор не сохранял duration: точные 15s и отдельный результат 64KiB download
**UNOBSERVED**, успешный delay не равен data-transfer PASS. Нельзя сделать вывод
о долгосрочной стабильности либо отключать download_check по этому наблюдению.

## Независимый deadline: доказанный узкий охват

[Host timer](../scripts/lab/r12-pve-user-timer203.py) — временный unprivileged
one-shot codexops, **не root/systemd service** и не новые sudo-права. Fixed VM203,
fixed serial wrapper/helper, monotonic deadline, lock, bounded serial, SHA helper,
nonce response, cancel только ARMED. Detached process пережил закрытие SSH;
LAB/host helper не обращаются к интернету/DNS/GitHub. На PVE находятся собственные
файлы `/home/codexops/r12-native-timer`, guest helper и baseline уже локальные.

[Guest helper](../scripts/lab/r12-native-timer-restore203.sh) восстанавливает
known-good LAB Podkop через native init + запускает guest SSH. Реально испытаны
40s arm, STOP Podkop+Dropbear203, DIRECT HTTP/verifiedHTTPS/DNS UDP/TCP, закрытие
управляющей сессии, autonomous serial restore, затем VPN HTTP/HTTPS/DNS и SSH.
Файлы network/firewall/dropbear не изменились. COMMAND_DONE означает guest RC0,
а приёмка требует независимых client receipts. Harmless probe и cancel проверяются
отдельно. Таймер не принимается как production kernel/disk recovery.

| Отказ | Что покрыто |
|---|---|
| Codespaces/SSH session потеряны | Detached host timer запускается локально, LAB PASS |
| Guest SSH остановлен | Serial helper не использует SSH, LAB восстановление проверяется |
| Guest procd не работает | Host timer сработает, но native init зависит от procd: восстановление НЕ доказано |
| Guest kernel/serial shell завис | Serial невозможен: этот helper не восстановит VM |
| Boot/disk повреждён | Нужен отдельный cold baseline + fence/offline restore; НЕ ПРОВЕРЕН |
| Сам PVE/storage/питание/WAN | Вне гарантии данного механизма |
| Host reboot/user-process killed | Temporary timer не reboot-persistent; не production guarantee |

Существующий [root recovery proposal](../scripts/lab/codexops-r12-recovery) и
[bootstrap](../scripts/lab/install-r12-recovery.sh) ограничены203; **не установлены**.
Для испытания kernel/disk сценария нужны отдельно согласованные права, cold capture,
fencing, restore проверенного образа и клиентская приёмка. Ни restart, ни наличие
VMA без испытанного восстановления не закрывают этот BLOCKER. Controller202 не установлен.

DIRECT использует IP провайдера и не обеспечивает VPN-защиту. При переключении
старые TCP-сессии/FakeIP-кэш клиентов могут потребовать нового соединения/резолвинга;
приведённые probes доказывают новые соединения, не бесшовную миграцию старых.

## Внедрение: PRODUCTION NO-GO до отдельного решения

1. **GO LAB**: все обязательные кейсы и независимые client probes; pending отсутствует,
   locks свободны, no default наружу. Любой незапланированный writer/serial owner — STOP.
2. **GO safety**: отдельно принять независимое PVE recovery и baseline202, включая
   сценарии утраты SSH/procd и явно согласованный kernel/disk путь. До этого никакого
   fault injection или установки updater202.
3. **GO preparation only**: backup действующих `.sh`/`.real.sh`, config Podkop/DHCP,
   generated JSON, cron, guard, текущих managed snapshots, файлов трёх новых компонентов;
   hash manifest, 0700/0600. Не удалять keys, не менять native0/failsafe. Определить
   исходный wrapper/config URL и всех cron writers; не запускать старый и новый updater
   одновременно. Обеспечить общий lock для конфликтующих writers либо STOP.
4. **GO candidate**: private literal subscription config, HTTPS trust, фактический
   section mapping, dry-run с непустыми main/USA, manual preservation, HTTP обоих
   маршрутов. Разница по unexpected key/section, USA0, timeout, pending — STOP.
5. **Отдельный GO установки**: три staged hash-verified файла (updater `.real.sh`,
   shared lib, native lib по default paths), atomic rename, cron schedule не менять;
   новый guard/init daemon не ставить. Arm принятого host recovery **до активации**.
6. Один supervised update; клиентские DNS UDP/TCP + HTTP + CA-valid HTTPS, SSH/LuCI/
   удалённый доступ, nft/rules/native health. Только затем disarm. Любой провал —
   rollback; не повторять рестарты вслепую.

### Точный LAB rollback / cleanup

В свободной serial203: `sh /root/r12-native-test/timer-restore.sh restore` возвращает
известный рабочий URLTest baseline и guest SSH. Это не полный откат к RAW Stage7.
При pending использовать тот же updater с LAB env: он сначала проверит previous-good,
вернёт его и завершится без нового download. Не удалять pending вручную ради PASS.
Оригинальные RAW Podkop/DHCP/generated JSON сохранены в `/root/r12-native-test`;
полный пакетный rollback — прежний `/root/r12-engine-baseline/rollback.sh` с его gate.

Host cleanup: `python3 /home/codexops/r12-native-timer/timer203.py status`; только
ARMED → `cancel`, RUNNING дождаться; сохранить журнал, после конечного состояния
удалить только собственный `/home/codexops/r12-native-timer`. Никакие systemd units,
sudoers или host network настройки в этом тесте не устанавливались.

Production rollback-команда с неизвестным backup path не выдаётся как готовая:
после approved preparation будет фиксированный manifest/каталог и скрипт, который
проверяет hash, выключает только новый updater entrypoint, возвращает старые три
файла/их отсутствие и previous-good Podkop через native STOP/START с проверкой DNS.
До подготовки/испытания этого конкретного набора — STOP, installation не разрешена.
