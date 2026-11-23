# R12 — podkop-engine: реальные LAB-испытания

2026-11-23, ветка `codex/podkop-fail-open-review`, Draft PR #7. **VM202 PRODUCTION NO-GO.**
Вердикт: **ПОДХОДИТ ЧАСТИЧНО**. Путь VPN → DIRECT → VPN доказан для отказа
синтетического endpoint. Это не полное автономное восстановление маршрутизатора.

## Версии, доставка и доверие

OpenWrt 25.12.4 r32933-4ccb782af7, x86_64, kernel 6.12.87, apk 3.0.5.
Podkop 0.7.24-r1 + podkop-engine 1.14.4-r28; runtime sing-box **1.14.4-pdk-r28**.
Закреплённый engine commit `a9926c37fe5fbf57241aaea583ffc1ae717f835f`.
[Манифест APK/SHA256](evidence/r12-engine-offline-manifest.json).
14 новых зависимостей аутентифицированы native `apk fetch --no-network` по четырём
подписанным OpenWrt ADB indexes; неверный, но структурно валидный APK отвергнут
с `ADB integrity error`. У OpenWrt индивидуальные APK не обязаны иметь свою подпись.
Только два фиксированных upstream release APK установлены с scoped `allow-untrusted`.
Ни один исходный пакет не обновлялся. Для updater-теста отдельно добавлялся flock.

Реальная доставка через restricted serial-wrapper: бинарные ACK-кадры 32 KiB,
возобновление по SHA-именованному файлу, проверка SHA256 в Debian; многомегабайтный
engine доставлен с проверенным возобновлением. Из Debian пакеты шли по изолированному
WAN HTTP. Никаких host TAP/bridges/NAT/default route не добавлялось.

## Методика

Клиент — namespace r12-lan LAB204 → LAB203 → r12-wan LAB204.
DNS UDP/TCP запрашивается у dnsmasq маршрутизатора, а не только у fixture напрямую.
Уникальные HTTP request ID, HTTPS с CA и проверкой имени; журнал WAN-сервера
независимо подтверждает peer: **10.253.203.1 = VLESS egress**, **10.253.203.2 = DIRECT/NAT**.
FakeIP 198.18.0.0/15 имеет только узкий лабораторный маршрут через LAB203.
Endpoint — синтетический **VLESS/TLS**, не REALITY/Xray; production-секреты не читались.
Внешнего WAN/default нет. Все воздействия — только внутри LAB203/204.

## Матрица фактических результатов

| Тест | Результат | Доказательство / предел |
|---|---|---|
| T1 NORMAL | PASS | [DNS UDP/TCP + HTTP + валидированный HTTPS через VPN](evidence/r12-engine-T1-dynamic.txt) |
| T2 штатный STOP | PASS | [Убраны Podkop nft/ip rule/proxy DNS](evidence/r12-engine-T2-stop203.txt), [полный DIRECT](evidence/r12-engine-T2-direct204.txt); затем native start |
| T3 CRASH | PASS для DIRECT; recovery вручную | [6 точных guest PID kills, native failsafe.last](evidence/r12-engine-T3-crash203.txt), [полный DIRECT](evidence/r12-engine-T3-direct204.txt). Автозапуска после terminal failsafe нет |
| T4 HANG | PASS для liveness/restart | [Штатный log: 49 s silence, kill PID14916, procd respawn](evidence/r12-engine-T4-logs203.txt); [последующий полный VPN probe](evidence/r12-engine-T4-client204.txt). Первый runner преждевременно завершился в 5 s respawn-gap; исправлено ожидание отсутствующего PID. Это не бесконечное восстановление повторных зависаний |
| T5 VPN DOWN | PASS | [Выключение только synthetic endpoint, полный DIRECT](evidence/r12-engine-T5-T6.txt); [неверный synthetic UUID — также DIRECT](evidence/r12-engine-T5-wrong-key-client204.txt) |
| T6 VPN RECOVERY | PASS автоматически | Тот же [T5/T6 журнал](evidence/r12-engine-T5-T6.txt): первая проверка через 5 s ещё DIRECT, через 10 s VPN; Podkop не перезапускался |
| T7 SUBSCRIPTION | PARTIAL | [Реальные HTTPS valid/empty/malformed/500/timeout/unavailable, native UCI/check dry-run](evidence/r12-engine-T7-updater-fixed203.txt), оба config hash неизменны. Это не тест атомарной activation-транзакции. [Native пустая USA fatal](evidence/r12-engine-T7-empty-USA-error203.txt); [после native restart DIRECT сохранился](evidence/r12-engine-T7-empty-USA-client204.txt), старые ключи сам engine не восстанавливает |
| T8 DNS FAILURE | BLOCKED при этой топологии; initial probes FAIL | [Private IP намеренно исключён](evidence/r12-engine-dns-fallback-conditions203.txt). После FQDN [нет подходящего uplink DNS](evidence/r12-engine-T4-preflight203.txt): LAB без default route. [DNS timeout](evidence/r12-engine-T8-fqdn.txt). Provider fallback в поддерживаемой WAN-топологии НЕ доказан |
| T9 REBOOT | PASS | [Новый boot, native autostart/rules/FakeIP](evidence/r12-engine-T9-postboot-ready203.txt), [полный клиентский VPN HTTP/HTTPS/DNS](evidence/r12-engine-T9-client204.txt). Первый serial nonce попал до shell-ready, повторён только read-only сбор после видимого root prompt. Не является disk recovery |

### Ошибки собственных fixture/config и исправления

- Стоковый dnsmasq RFC6761 блокирует `.test`: добавлено только для LAB
  `server=/r12.test/#` + `rebind-domain-ok=/r12.test/`, глобальная защита не отключалась.
- DNS fixture первоначально не принимал EDNS OPT/AAAA: добавлены корректные ответы,
  malformed OPT отрицательный тест. [Реальный Stage6 после исправления](evidence/r12-engine-edns-fixture-fix204.txt).
- Недопустимый Podkop `user_subnet_list_type=static` давал пустой nft set и обход VPN
  HTTPS. Исправлен на документированный `dynamic`; успешный T1 требует оба WAN receipts.
- Native OpenWrt `/lib/functions.sh` читает необязательный `IPKG_INSTROOT`, несовместимый
  с `set -u` updater. В собственном R12 `make_probe_config` отключён nounset только внутри
  parser subshell; вызывающий updater остаётся строгим. [Regression](../tests/test-r12-probe-nounset.sh)
  и реальный повтор T7 PASS. Сторонний engine не патчился.
- На чистом OpenWrt нет `nohup`: detached runner использует POSIX ignored HUP и
  ограниченное ожидание, SIGCONT только того же PID/starttime/executable.
- Native Podkop fatal пишется в syslog, init restart может вернуть 0; исправлен сбор
  fatal после уникального syslog marker, нельзя принимать shell RC0 за здоровье.
- Полный nft diff учитывает только переменные counter packet/byte значения; имена,
  правила и остальные поля должны совпадать. Stage6 probe запускается лишь после
  удаления собственной Stage7 FakeIP route, иначе его isolation guard правильно STOP.

## Проверенный guest rollback, не host recovery

Локальный root-only `/root/r12-engine-baseline`: SHA archive `/etc`, original world,
182-package inventory, routes/rules/nft. APK DB сохранена только для forensic, не
копируется обратно как способ отката. Все установленные пакеты новые; достаточно
удалить точный new-package allowlist и восстановить оригинальный `/etc` без интернета.
APK cache и original configuration backups остаются локально, private keys в Git не попадают.

1. `sh /root/r12-engine-baseline/rollback.sh check`, затем `apply` — только LAB203.
2. В LAB204 `bash /root/r12-engine-offline/r12-engine-services204.sh rollback`:
   остановить только свои процессы и убрать ровно свой FakeIP route.
3. `sh /root/r12-stage6/probe.sh` — HTTP200/TLS verify0/DNS UDP+TCP/receipt/NAT/no-external-route.
4. Сопоставить baseline nft, игнорируя только traffic counters.

[199 → 182 packages, world/routes/rules restored](evidence/r12-engine-full-rollback203.txt).
Первый raw nft diff ожидаемо отличался счётчиками; [semantic diff PASS](evidence/r12-engine-full-rollback-nft-final203.txt).
[Полный транзит после собственного Stage7 cleanup PASS](evidence/r12-engine-full-rollback-final204.txt).
[Откат EDNS fixture к исходному Stage6 и повторное применение также с реальным транзитом](evidence/r12-engine-fixture-rollback-fixed204.txt).
Это доказательство guest rollback при работающем ядре/serial/procd, **не** восстановления
при одновременном отказе SSH/procd/QGA или повреждении диска.

Ограниченный wrapper не разрешает snapshot/fence/disk restore. Новый root recovery
bootstrap НЕ устанавливался. Полное host-side recovery: **НЕ ПРОВЕРЕН / BLOCKER**.
Не имитировали full VM failure без независимого проверенного восстановления.

## Пригодность для VM202

- Сложность: средняя; требуется совместимая пара и явный `fallbacks:["direct-out"]`.
  Наличие engine не добавляет DIRECT к любому существующему URLTest автоматически.
- Наблюдаемая стабильность: ограниченная длительностью LAB, не длительная эксплуатация.
  Совместимость данной пары на OpenWrt25.12.4 доказана установкой и реальным VLESS/TLS.
- Поддержка REALITY по коду/формату не равна проверенному handshake: REALITY НЕ испытан.
- После crash-loop DNS/DIRECT восстановлены, но возврат Podkop требует вручную start/reboot.
  Автоматический URLTest recovery работает только когда движок продолжает работать.
- Transactional updater остаётся отдельным компонентом; engine не защищает USA от очистки.
- DNS fallback в требуемой WAN-топологии, IPv6, независимый host recovery — открытые gates.
- Собственный код ещё нужен для безопасного updater/activation rollback и восстановления
  после terminal failsafe/полного отказа guest. Дополнительный watchdog в LAB не добавлялся.
- Риск для VM202 остаётся высоким из-за единственного шлюза и удалённого владельца.
  **Не внедрять PR7/engine в production до закрытия этих gates.**

## Оставленное состояние

LAB203 после полного rollback/reinstall и reboot: та же закреплённая пара, 198 пакетов
(тестовый flock удалён), Podkop/engine работают с синтетическим VLESS/TLS и явным DIRECT fallback.
Original baseline остаётся `/root/r12-engine-baseline`; private протоколы предыдущих
тестов — `/root/r12-engine-runtime-tested`, новая рабочая конфигурация — `/root/r12-engine-runtime`.
LAB204: Stage6 fixture плюс временные offline/VLESS/primary-DNS процессы, каждый ограничен
7200 секундами от последнего apply; это не постоянные host-сервисы. Для новой сессии
сначала проверить точные PID/netns/состояние markers, не перезапускать вслепую.
[Финальный inspect изоляции](evidence/r12-engine-final-inspect.txt),
[независимые VLESS-server receipts](evidence/r12-engine-final-server-receipts204.txt),
[финальный inventory](evidence/r12-engine-final-inventory203.txt).
DNS upstream в этом сценарии прямой лабораторный; приватность DNS через VPN не сертифицирована.
VM201/202 и сетевые настройки Proxmox не изменялись. PR7 остаётся Draft; merge/deploy не выполнялись.

### Не сертифицировано этими probe

Все HTTP-пробы открывают новые соединения. Поведение уже открытых TCP/QUIC соединений
при смене VPN/DIRECT и клиентских DNS-кешей со старым FakeIP после полного stop не
измерялось. Независимая изоляция отказа USA при живом отдельном main endpoint также не
испытана: обе синтетические секции используют один тестовый VLESS outbound. Эти
ограничения не позволяют переносить LAB PASS на все домашние клиентские устройства.
После reboot APK staging в `/tmp/r12-offline` исчезает; постоянная проверенная копия
пакетов находится только в изолированной LAB204. Для rollback новых пакетов к182
сеть/загрузка APK не нужны; для последующей переустановки staging надо доставить заново.
