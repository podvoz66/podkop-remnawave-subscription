# R12: аудит podkop-engine, факты отдельно от испытаний

Состояние подготовки 2026-11-23. Production VM202 **NO-GO**.
[Фактический LAB-отчёт и T1–T9](lab-podkop-engine-results.ru.md): ПОДХОДИТ ЧАСТИЧНО. Чтение исходников отдельно не означает runtime PASS.

## Зафиксированная пара

- [Podkop 0.7.24](https://github.com/itdoginfo/podkop/releases/tag/0.7.24), APK 0.7.24-r1,
  SHA256 `a444a784a7dc22b2ba17336b773f75b27861daf3fb358fea21b31935a975318e`.
- [podkop-engine v1.14.4-r28](https://github.com/podkop-net/podkop-engine/releases/tag/v1.14.4-r28),
  commit `a9926c37fe5fbf57241aaea583ffc1ae717f835f`, x86_64 APK,
  SHA256 `c72c91a0567a6243c55bef20b4990a521461f9740c5219d2a35b51f6cc2cbb2a`.
  Это сторонняя сборка sing-box с патчами, не upstream SagerNet.
- [INSTALL](https://github.com/podkop-net/podkop-engine/blob/a9926c37fe5fbf57241aaea583ffc1ae717f835f/docs/INSTALL.ru.md)
  указывает совместимость Podkop 0.7.24 с r26+. Engine предоставляет пакет sing-box;
  одновременно устанавливать обычный sing-box не требуется.

## Подтверждено исходниками; runtime-статусы — в LAB-отчёте

- [sing-box.init](https://github.com/podkop-net/podkop-engine/blob/a9926c37fe5fbf57241aaea583ffc1ae717f835f/openwrt/podkop-engine/files/sing-box.init):
  procd respawn `600 5 5`, nofile 65536, DNS fallback из netifd/ubus,
  download-check URLTest. Смена WAN может перезапустить сервис.
- [failsafe](https://github.com/podkop-net/podkop-engine/blob/a9926c37fe5fbf57241aaea583ffc1ae717f835f/openwrt/podkop-engine/files/failsafe):
  `instance.fail` → штатный stop Podkop → запись `/etc/sing-box/failsafe.last`.
  Это защита crash-loop. Возобновление Podkop после окончательного stop — вручную
  или при reboot; собственного периодического автоматического recovery здесь нет.
  DNS liveness каждые20с, 3 неответа, только после собственного FakeIP-ответа.
  SERVFAIL/NXDOMAIN также считаются ответом: это НЕ проверка интернет-доступа через VPN.
  При перегрузке/обновлении списков проверка имеет условия исключения и grace.
- [URLTest patch](https://github.com/podkop-net/podkop-engine/blob/a9926c37fe5fbf57241aaea583ffc1ae717f835f/patches/v1.14/0410-urltest-the-group-of-this-fork-in-a-package-of-its-o.patch):
  явный `fallbacks` проверяется вместе с основными; при восстановлении основного
  участника предусмотрен автоматический возврат. Наличие этой функции не доказывает,
  что конкретная конфигурация Podkop включает DIRECT.
- Podkop 0.7.24 поддерживает fallback links, но его parser не принимает `direct://`.
  Для испытания DIRECT применим штатный Outbound JSON с `fallbacks:["direct-out"]`,
  ссылающийся на отдельный лабораторный VLESS outbound. Исходники engine не правятся.
- Podkop 0.7.24 по-прежнему fatal при пустом основном `urltest_proxy_links`.
  Engine не является transactional updater и не предотвращает очистку USA.
- DNS fallback переключает на DNS провайдера, только если такой resolver доступен
  и прочитан netifd. Это не независимое восстановление dnsmasq/ядра/VM.

## Реальная подготовка LAB

Обе VM running; restricted inspect принял точные Unix-stream backend/MAC,
без netN/production bridges. LAB203 25.12.4/apk3.0.5, исходные182пакета,
root free75304KiB до backup. Внешнего default нет. Stage6 fixture204 активен.
Создан локальный root-only baseline203 `/root/r12-engine-baseline`:
архив `/etc`, APK DB, world, перечень пакетов, routes/rules/nft.
SHA и распаковка/побайтное сравнение обычных файлов `/etc` прошли; diff отсутствует,
поэтому используется find+cmp. Полный 199→182 пакетный rollback и HTTP/HTTPS/DNS
проверены в LAB; см. фактический отчёт. Это НЕ host disk recovery.

Нативный apk проверил подписи base/packages/target/kmods ADB: все `OK`.
`apk verify podkop.apk` → `UNTRUSTED signature`; SHA совпал с upstream release.
Владелец отдельно разрешил scoped allow-untrusted для проверенных release APK.
Dry-run зависимостей:14 **новых** пакетов, без изменения исходных; затем отдельный
cmp installed inventory подтвердил, что simulation ничего не установила.
Старые временные APK предыдущей сессии отсутствовали: нужные файлы скачаны заново.

## Ограничения восстановления

Новые host privileges не устанавливались. Existing wrapper не умеет disk snapshot/
restore; полное независимое recovery ядра/диска VM НЕ ПРОВЕРЕНО.
Новая инструкция владельца разрешает guest-only тесты после package rollback gate,
поэтому прежний безусловный запрет установки до host capability заменён этим gate.
Guest archive не заменяет независимую копию диска и не поможет при отказе guest kernel.
Синтетический endpoint — VLESS/TLS; это НЕ проверка REALITY/Xray compatibility.
Внешнего WAN нет; production-ключи не читаются и не нужны для этих испытаний.

## Сохранённое исследование до runtime-приёмки

Ниже сохранены выводы параллельных documentation-коммитов b4d10ec/cc9b5e2.
Их статусы подготовки и требование snapshot до любой установки исторические:
последующее разрешение владельца допускает проверяемый guest-only rollback.
Актуальные результаты, оставшиеся gates и final-state — в LAB-отчёте выше.

## R12 — штатные и готовые механизмы Fail-Open (исследование, 2026-11-23)

**Статус: исследование; production VM202 NO-GO.** Прежде чем устанавливать самописный watchdog, испытать готовые механизмы на LAB203/204. Не путать DIRECT-подключение с доступностью заблокированного провайдером сайта.

### 1. Что уже умеет штатный Podkop

Источник: [itdoginfo/podkop /usr/bin/podkop](https://github.com/itdoginfo/podkop/blob/main/podkop/files/usr/bin/podkop), функции `stop`, `stop_main`, `dnsmasq_restore`.

- При штатном `service podkop stop` сохраняется логика восстановления dnsmasq, удаляется собственная таблица nftables, fwmark/ip rule, очищается специальная таблица маршрутов, останавливается sing-box. При здоровом WAN после этого обычный DIRECT должен работать.
- Это не гарантирует DIRECT при *аварийном* исчезновении процесса sing-box: dnsmasq мог остаться с единственным upstream `127.0.0.42`, а правила TPROXY — активными.
- Штатный `reload()` только выполняет `stop_main; start_main`; это не эквивалент `stop` с восстановлением DNS. При невалидной конфигурации после изменений может пропасть DNS.
- У Podkop [настройка Interface Monitoring](https://podkop.net/docs/badwan/) для перезагрузки при DOWN/UP WAN, но это не мониторинг доступности VPN-сервера.
- [Запрос штатного переключателя «проксировать или открывать напрямую» #392](https://github.com/itdoginfo/podkop/issues/392) закрыт как *not planned*, поэтому считать такую функцию уже реализованной в обычном Podkop нельзя.
- [Документация DNS](https://podkop.net/docs/troubleshooting/): dnsmasq → sing-box 127.0.0.42, FakeIP и TPROXY зависят от работающего sing-box. «Don't Touch My DHCP» требует ручной корректной DNS-настройки, не является готовым fail-open.

### 2. Готовый failsafe — podkop-engine (сторонний форк sing-box)

Источники: [README.ru](https://github.com/podkop-net/podkop-engine/blob/main/README.ru.md), [INSTALL.ru](https://github.com/podkop-net/podkop-engine/blob/main/docs/INSTALL.ru.md), [исходник failsafe](https://github.com/podkop-net/podkop-engine/blob/main/openwrt/podkop-engine/files/failsafe), [FEATURES.ru](https://github.com/podkop-net/podkop-engine/blob/main/docs/FEATURES.ru.md).

- Пакет заменяет штатный sing-box и объявляет `PROVIDES: sing-box`, **не официальный компонент Podkop**.
- Использует `procd` для рестарта sing-box; при повторных падениях с `instance.fail` останавливает Podkop, что восстанавливает DNS и обычный DIRECT через WAN. Записывает причину в `/etc/sing-box/failsafe.last`.
- Проверка живости sing-box DNS каждые 20 секунд выявляет процесс, который существует, но не отвечает. При подтверждённом зависании инициирует перезапуск через procd; окончательная авария переводит Podkop в stop.
- Есть `dns_fallback` к DNS провайдера для отказавшего прямого DNS, восстановление remote rule-set, `urltest.fallbacks`, где можно задать приоритетные VPN и резервные выходы. Функциональность и синтаксис версии проверять по FEATURES.
- Отличие: **fail-safe по падению/зависанию sing-box** не обязательно обнаруживает ситуацию «sing-box здоров, но все удалённые VPN-ноды недоступны». Для неё нужен отдельно подтверждённый `urltest.fallbacks` с DIRECT или штатный независимый health-check. Не считать тест DNS `127.0.0.42` доказательством интернет/VPN-связности.
- В OpenWrt 25.12 используется APK; в инструкции указан `--allow-untrusted`, т.к. пакет не подписан. Требуется pinned asset/sha256, точная совместимость с версией podkop и используемыми outbounds, независимый snapshot/rollback **до установки**. Не ставить на VM202 по этому документу.
- Сборка `podkop-engine` облегчённая: не все outbounds sing-box поддерживаются. `podkop-engine-full` шире, но тоже имеет ограничения. Выбор по реальному config без секретов.

### 3. Остальные решения и границы применимости

| Вариант | Что закрывает | Чего сам по себе не закрывает | Решение R12 |
|---|---|---|---|
| Штатный Podkop stop + OpenWrt procd | Восстанавливает DIRECT при *корректной* остановке, рестартует упавший sing-box | VPN-сервер умер при здоровом sing-box, зависший sing-box, битая DNS-конфигурация | **База, обязательно испытать** |
| podkop-engine failsafe + `urltest.fallbacks` | Готовый механизм crash/hang→restart/stop Podkop; потенциально предпочтение VPN→DIRECT | Полный отказ VM, невалидная UCI-подписка от стороннего updater | **Предпочтительный кандидат в LAB** |
| Малый health-check поверх штатного Podkop | HTTPS/DNS-проверка и вызов штатного `service podkop stop` при подтверждённом отказе | Сам по себе не делает безопасную транзакционную запись UCI и не восстанавливает повреждённую VM | Резерв, если engine непригоден |
| [ProxyRules](https://github.com/m0n5ter/ProxyRules) | Готовый альтернативный стек с direct-on-stop и цепочками failover | Смена стека/конфигов, риск несовместимости подписок | Не мигрировать без отдельного сравнительного LAB |
| OpenWrt `mwan3` / PBR | Переключение между физическими WAN или поднятыми VPN **интерфейсами** | Не лечит зависший sing-box, FakeIP DNS, падение пользовательских outbound VLESS | Для данного Proxy-over-WAN не основной выбор |

Источники дополнительно: [sing-box URLTest](https://sing-box.sagernet.org/configuration/outbound/urltest/), [OpenWrt mwan3](https://openwrt.org/docs/guide-user/network/wan/multiwan/mwan3-nft), [ProxyRules](https://github.com/m0n5ter/ProxyRules). Обычный `URLTest` выбирает по доступности/задержке среди заданных outbounds и **сам по себе не гарантирует приоритет VPN над DIRECT**, нужен явно определённый fallback-порядок и проверка.

### 4. Как использовать результаты в R12

**Не переписывать Podkop и не ставить несколько конкурирующих автоматических recovery-демонов.** Сначала доказать фактическое поведение совместимой готовой реализации. Не удалять ещё рабочие Stage1–6 и ранее созданные резервные скрипты: они пригодятся для сравнительного теста и transaction-safe updater.

Последовательные LAB acceptance gates:

1. Read-only inventory установленного Podkop/версии sing-box, `/etc/init.d/sing-box`, `/etc/config/dhcp`, procd respawn и `urltest`/fallback. Чистая LAB203 пока без этих компонентов; официальный образ был без Podkop.
2. Независимый host-side откат **диска LAB203** до установки нового sing-box-пакета. Не расширять существующий codexops wrapper до произвольных host-команд.
3. Проверить stock `service podkop stop` с восстановлением DNS, правил nft и DIRECT.
4. Испытать podkop-engine в LAB: crash-loop, SIGSTOP/hang, недоступность VPN-сервера, пустая USA, неверный ключ, DNS failure, cooldown и переход обратно. Фактический DIRECT/VPN путь проверять уникальными токенами и журналами LAB204.
5. Для `podkop-engine urltest.fallbacks` отдельно проверить, допускает ли точная используемая версия прямой `direct` как резервный outbound и предпочитает ли VPN при работоспособной ноде, затем протестировать no-Podkop-running и no-WAN. Без этого нельзя обещать VPN→DIRECT→VPN.
6. Transaction-safe subscription updater R12 оставить отдельным критическим пунктом: **пустая USA не должна стирать действующие ссылки**, конфиг проверяется до commit/restart, rollback после неуспеха.
7. Полный отказ VM202 не исправляется кодом OpenWrt. Если нужен этот уровень отказоустойчивости, минимальный независимый host recovery в Proxmox сохраняется обязательным. LAB203/204 удалить после приёмки production VM202.

**Архитектурное предпочтение:** fail-open реализовать штатным stop Podkop и, если подтвердится, готовым podkop-engine; собственный код оставить только для подписок и тех сценариев, которые готовый компонент не покрывает.
