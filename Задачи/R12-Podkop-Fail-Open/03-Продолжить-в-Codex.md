## Checkpoint выполненного задания — 24.11 native updater / LAB deadline

[Результат и GO/STOP](../../docs/native-updater-lab-20261124.ru.md).
По отдельному текущему запросу владельца выполнена только LAB-разработка updater
(native0, manual preservation, previous-good, reject empty USA, atomic rollback).
Required negative/concurrent/rollback и финальные client HTTP/TLS/DNS PASS; см.
[доказательства](../../docs/evidence/native-updater-lab-20261124.json).
Найден nested EXIT cleanup leak; явный cleanup + lifecycle regression + no orphan PASS.
Temporary PVE user timer203: detached/SSH loss/guest SSH STOP recovery PASS;
**не** root-owned controller и **не** независимый от guest kernel/procd rescue.
Full host recovery остаётся BLOCKER, capability не установлен. VM202 не меняли;
не развёртывать updater/guard/cron и не выполнять fault injection без отдельного GO.
Passive URLTest 50/50 за24.5min: main fresh, USA stale, download64KiB UNOBSERVED.
Следующий шаг: принять exact production backup/rollback + independent host recovery,
а не повторять LAB1–6 или автоматически переносить Draft PR7. Предыдущий P0 план
ниже сохранён; готовность production не заявляется.

---

# R12 — приоритетная точка входа Codex (решение владельца 24.11.2026)

**ВЫПОЛНЯТЬ СНАЧАЛА P0: INDEPENDENT RECOVERY + FAIL-SAFE.**
Только после закрытия P0 перейти к **P1: REALITY timeouts / URLTest switching**. Updater/USA — **P2**, текущие ручные USA-ключи сохраняются после четырёхчасовых циклов; не исправлять или запускать PR7 сейчас.

## Ближайшая задача Codex

1. Восстановить контекст GitHub R12, последние read-only checkpoint и текущую production версию (OpenWrt25.12.4, Podkop0.7.24, engine-full1.14.4-r28, native failsafe active); `AGENTS.md`, [план](01-Задача-и-план.md), [отчёт RO](../../docs/vm202-vpn-readonly-20261124.ru.md), [первоначальный rollout](../../docs/vm202-production-rollout-20261124.ru.md), LAB203/204 docs.
2. Предложить архитектуру **действительно независимого** bounded PVE recovery: контроллер/root helper на PVE, который выполняет фиксированные действия без активной SSH/Codex-сессии и не полагается исключительно на сеть VM202, guest SSH/procd или guest watchdog. Учесть: хост default route через VM202; не создавать второго активного шлюза; разные пути для process failure vs guest kernel/boot/disk failure; отказ самого PVE/физического WAN вне охвата. Определить какие права/capabilities нужно согласовать (сейчас `codexops` не имеет root-owned timer на VM202).
3. Протестировать controller **сначала на изолированном LAB203/204**, включая arm/fire/disarm, timeout, controller lost, guest SSH fail, восстановление прямого DNS/LAN HTTPS и логирование/RTO. Не заменять полноценное восстановление VM202 её гостевым watchdog.
4. Спланировать три нативных fail-safe сценария: **single SIGKILL** (procd respawn обычно через ~5 с), **terminal crash loop** (порядка шести падений в 600 с → Podkop STOP→DIRECT), **DNS hang** (liveness каждые 20с/3 пропуска, приблизительно 49–72с; возможны условия арминга и grace). Проверять реальный клиентский трафик, а не только PID и `nslookup` самого маршрутизатора. Terminal native failsafe сам Podkop обратно не запускает; восстановление VPN требует отдельного условного механизма.
5. До любых fault injections на production показать **план GO/STOP**, фиксированную автоматическую границу восстановления и rollback, измерения лаборатории, независимый доступ PVE, свежий backup; отдельно согласовать потенциальный guest kernel/disk fencing. Все действия на VM202 пока read-only.
6. Документировать лабораторные PASS/FAIL/UNVERIFIED, коммиты в отдельную ветку, без merge. Затем получить согласование пользователя на ограниченный production-тест.
7. **После P0**: переход к P1 — корреляция периодических REALITY/VLESS deadline exceeded с per-node URLTest/download-check (64 KiB), историей selector, сервером/транспортом; не трогать on1x (недоступен из РФ, тикет) и Oslo (не оплачен), не удалять ключи.

Сейчас **не запускать** предложенный ранее короткий 18-секундный guest-only watchdog: независимый host-side механизм ещё не подготовлен и не принят. Не устанавливать второй конфликтующий guard, не менять `dont_touch_dhcp=0`.

**Первый ответ Codex:** краткая схема PVE→LAB recovery, существующие capabilities/блокеры, точный порядок испытаний с критериями PASS и предложение следующего безопасного read-only шага. Никаких изменений production без нового GO.

---

## Read-only checkpoint 24.11, 01:41–01:48 +05

[первый RO-анализ VM202](../../docs/vm202-vpn-readonly-20261124.ru.md). Ветка `codex/r12-vm202-prod-diagnostics-20261124`, исходный HEADad501a52.
AUT main-1/main-2/USA-1 идентичны кромеtag и сейчас WORKING205/212/233ms; пять
контролей также прошли HTTPS delay. on1x/Oslo — известные внешние причины владельца,
не трогать. Историческая причина AUTN/A НЕ доказана, серверный Xray не прочитан.
В свежих логах GermanyREALITY15–16s timeout и сменаURLTest; download_check1 сохранён.
main автоURLTest; USA вручнуюUSA-2; DIRECT fallback в группах отсутствует.
Updater hashes равны старому дефектному коду USA0; PR7 напрямую не ставить:
его activation требует guard/DNS ownership(dont_touch_dhcp1), productionnative0.
Failsafe hash совпадает с закреплённым upstream; root PVE recovery timer202 не
подготовлен/не проверен. Fault injections STOP до recovery-gate и отдельного GO.
Production не изменялась **этой диагностикой**; ручная установка владельца ранее — факт.
Следующее: пассивная корреляция64KiB/выборов и серверные logs/version при существующем
разрешённом доступе; проект независимого timed recovery сначала проверить наLAB.

---

# Актуальная точка продолжения для VS Code / Codex — 24.11.2026

**Задача:** расследовать причины временного `N/A` и 15-секундных тайм-аутов URLTest на VM202, не смешивая их с доказанным инцидентом подписочного `USA=0`; спроектировать и затем по согласованию испытать штатный fail-safe `podkop-engine-full`.

**Фактическое состояние:** OpenWrt25.12.4/Podkop0.7.24 + engine-full1.14.4-r28 на production VM202, sing-box running, `podkop-engine` failsafe running, `liveness=1`. 24.11 штатный STOP→DIRECT DNS→START, `sing-box check`, HTTP200 PASS. `N/A` для части main/USA; ошибки `main-6-out`, `main-1-out`, `main-2-out`; `urltest_download_check=1`. В 01:13 `podkop reload` объясняет PID смену, более поздний PID330 требует проверки uptime. Не было подтверждённого исполнения предлагаемого 18s watchdog/SIGKILL-теста. Подробный checkpoint: [документ](../../docs/vm202-production-rollout-20261124.ru.md).

**Обязательные шаги Codex:**
1. Прочитать `AGENTS.md`, `01-Задача-и-план.md`, `02-Ход-работы.md`, [новый checkpoint](../../docs/vm202-production-rollout-20261124.ru.md), [инцидент USA0](../../docs/incident-20261123-0800.ru.md). Отличать существующий Draft PR7 от вручную установленного пакета.
2. Предложить компактный план проверки с gates, до новых production-действий запросить конкретное одобрение. Сначала **read-only** SSH/Proxmox: uptime/btime, procd PIDs/events, API URLTest, последние ошибки; сравнить с текущим состоянием пользователя.
3. Исследовать две независимые гипотезы: (a) updater перезаписывает USA пустой подпиской, нужны атомарность/валидация/сохранение manual links; (b) URLTest `N/A`/timeout: DNS, end-to-end WAN, конкретные endpoints, TLS/REALITY/XHTTP/Hysteria2, необязательный `urltest_download_check`. Не менять секреты и не выводить UUID/токены/полные URL.
4. Составить план безопасного fault-injection с реально действующим автоматическим recovery; **18 s не гарантируют terminal fail-open** (`procd respawn 600 5 5`; liveness 20s x3). Отдельно проверить single crash vs crash-loop vs DNS-hang, без reboot и без опасного host fencing без явного разрешения.
5. Подготовить diff/доказательства/rollback и в конце короткий отчёт PASS/FAIL/UNVERIFIED. Не merge, не менять VM202, Podkop cron, DNS, fw4, Remnawave API и подписки без согласования. Работа в собственной GitHub-ветке.

**Запрос к Codex:** начни с чтения checkpoint и read-only диагностики, покажи точную матрицу двух независимых дефектов и план теста fail-safe. Никаких изменений production до подтверждённого GO.

---

## Актуально: реальные испытания podkop-engine, 2026-11-23

[Полный LAB-отчёт, доказательства и ограничения](../../docs/lab-podkop-engine-results.ru.md).
**ПОДХОДИТ ЧАСТИЧНО; VM202 PRODUCTION NO-GO; PR7 Draft.**
Установлены Podkop0.7.24 + engine1.14.4-r28; доказаны VPN→DIRECT→VPN (10 s),
штатный STOP, crash-loop DIRECT, liveness-kill и клиентский транзит.
Полный guest rollback199→182 и Stage6 transit PASS; затем та же пара переустановлена.
T9 reboot/autostart + полный VPN client probe PASS. Итог198 пакетов, test flock удалён.
T7 HTTPS/dry-run validation PASS, activation-транзакция НЕ сертифицирована.
DNS provider fallback BLOCKED текущей no-default топологией; REALITY/IPv6 не испытаны.
Terminal failsafe сам Podkop не возвращает. Host disk recovery НЕ ПРОВЕРЕН:
новый root bootstrap не установлен, без соответствующих прав full-VM failure не запускать.
Последнее разрешение владельца допускает guest-only package tests с проверенным rollback;
старый безусловный запрет до host snapshot ниже — исторический, заменён этим разрешением.
Сначала читать текущий отчёт и точное состояние LAB; Stage1–6 не повторять.

---

# Продолжить R12

**PRODUCTION NO-GO.** До отдельного разрешения никаких установок/перезапусков/изменений VM202 или PVE.
Новый приоритет: [независимый rollback, Stage1/Stage2](../../docs/independent-rollback.ru.md).
Предыдущий rollback через новый guard недостаточен. Нужен изолированный OpenWrt-стенд,
проверенный LAN SSH PVE→VM и решение сценария SSH+guest scheduler unavailable.

1. Читать [план](01-Задача-и-план.md), [результаты](02-Ход-работы.md),
   [ограничения и rollback](../../docs/fail-open.ru.md), актуальный diff ветки.
2. Не повторять поиск доступа/MCP: SSH alias openwrt-202 уже работает из Codespace,
   Tailscale использует нестандартный userspace socket, CT107→Proxmox→OpenWrt.
3. Не восстанавливать USA вслепую: последняя проверка main7/USA1, оба outbounds
   проходили реальные HTTP probes. Новое состояние проверять только по необходимости.
4. Production внедрение НЕ разрешено. Нельзя запускать новый guard/updater на
   VM202, менять cron/autostart/DNS/nft/routes или проводить аварийные тесты.
5. Сначала review и согласование точного окна/этапа внедрения; доступна Console VM202.
6. После согласованного внедрения проверить LAN DNS/HTTP/HTTPS, SSH/LuCI, ZeroTier,
   rollback и только затем отдельно согласованную перезагрузку OpenWrt.

## Последняя RO-сверка Proxmox

Читать [факты и архитектуру B](../../docs/proxmox-lab-architecture.ru.md).
proxmox-cloud → codexops: inventory доступен; VM config/QGA/root sockets закрыты.
Не использовать guestctl apply/start/reboot. PVE SSH→VM202 остановился на unknown
host key; auth не проверен. Стенд — только clean203/204 кандидаты и Unix sockets,
без host bridges/NAT. B offline disk recovery пока только архитектура; A не лечит
полный отказ guest kernel. Никаких production изменений/новых механизмов до RO gate.

## Актуально после Stage6
Предыдущие STOP/исторические статусы выше заменены новым этапом:
[Stage6 live PASS и rollback](../../docs/lab-stage6.ru.md),
[Stage7 план, ещё не выполнен](../../docs/lab-stage7-plan.ru.md).
LAB203/204 running, restricted wrapper установлен. В203 Stage5 адреса, firewall/DNS
не менялись; в204 работают fixture и узкий host-route. Stage6 rollback в204 автономен.
Нет установленных Podkop/sing-box/curl203; требуется офлайн подготовка. Full guest
host disk recovery ещё BLOCKER. Production NO-GO, wrapper202 запрещён sudo.

## Stage7: точка остановки на дополнительном root capability
[Офлайн-readiness и recovery bootstrap](../../docs/lab-stage7-recovery.ru.md).
Root bootstrap нового203 recovery staged, но НЕ установлен и ещё НЕ разрешён.
Установка Podkop/sing-box не выполнялась; APK signatures/transitive closure и bulk
transport ещё gate. Stage6 состояние не откатывалось. Не повторять инвентаризацию:
сначала owner approval нового root capability, затем live capture/restore acceptance.
