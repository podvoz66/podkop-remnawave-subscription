# R12 — штатные и готовые механизмы Fail-Open (исследование, 2026-11-23)

**Статус: исследование; production VM202 NO-GO.** Прежде чем устанавливать самописный watchdog, испытать готовые механизмы на LAB203/204. Не путать DIRECT-подключение с доступностью заблокированного провайдером сайта.

## 1. Что уже умеет штатный Podkop

Источник: [itdoginfo/podkop /usr/bin/podkop](https://github.com/itdoginfo/podkop/blob/main/podkop/files/usr/bin/podkop), функции `stop`, `stop_main`, `dnsmasq_restore`.

- При штатном `service podkop stop` сохраняется логика восстановления dnsmasq, удаляется собственная таблица nftables, fwmark/ip rule, очищается специальная таблица маршрутов, останавливается sing-box. При здоровом WAN после этого обычный DIRECT должен работать.
- Это не гарантирует DIRECT при *аварийном* исчезновении процесса sing-box: dnsmasq мог остаться с единственным upstream `127.0.0.42`, а правила TPROXY — активными.
- Штатный `reload()` только выполняет `stop_main; start_main`; это не эквивалент `stop` с восстановлением DNS. При невалидной конфигурации после изменений может пропасть DNS.
- У Podkop [настройка Interface Monitoring](https://podkop.net/docs/badwan/) для перезагрузки при DOWN/UP WAN, но это не мониторинг доступности VPN-сервера.
- [Запрос штатного переключателя «проксировать или открывать напрямую» #392](https://github.com/itdoginfo/podkop/issues/392) закрыт как *not planned*, поэтому считать такую функцию уже реализованной в обычном Podkop нельзя.
- [Документация DNS](https://podkop.net/docs/troubleshooting/): dnsmasq → sing-box 127.0.0.42, FakeIP и TPROXY зависят от работающего sing-box. «Don't Touch My DHCP» требует ручной корректной DNS-настройки, не является готовым fail-open.

## 2. Готовый failsafe — podkop-engine (сторонний форк sing-box)

Источники: [README.ru](https://github.com/podkop-net/podkop-engine/blob/main/README.ru.md), [INSTALL.ru](https://github.com/podkop-net/podkop-engine/blob/main/docs/INSTALL.ru.md), [исходник failsafe](https://github.com/podkop-net/podkop-engine/blob/main/openwrt/podkop-engine/files/failsafe), [FEATURES.ru](https://github.com/podkop-net/podkop-engine/blob/main/docs/FEATURES.ru.md).

- Пакет заменяет штатный sing-box и объявляет `PROVIDES: sing-box`, **не официальный компонент Podkop**.
- Использует `procd` для рестарта sing-box; при повторных падениях с `instance.fail` останавливает Podkop, что восстанавливает DNS и обычный DIRECT через WAN. Записывает причину в `/etc/sing-box/failsafe.last`.
- Проверка живости sing-box DNS каждые 20 секунд выявляет процесс, который существует, но не отвечает. При подтверждённом зависании инициирует перезапуск через procd; окончательная авария переводит Podkop в stop.
- Есть `dns_fallback` к DNS провайдера для отказавшего прямого DNS, восстановление remote rule-set, `urltest.fallbacks`, где можно задать приоритетные VPN и резервные выходы. Функциональность и синтаксис версии проверять по FEATURES.
- Отличие: **fail-safe по падению/зависанию sing-box** не обязательно обнаруживает ситуацию «sing-box здоров, но все удалённые VPN-ноды недоступны». Для неё нужен отдельно подтверждённый `urltest.fallbacks` с DIRECT или штатный независимый health-check. Не считать тест DNS `127.0.0.42` доказательством интернет/VPN-связности.
- В OpenWrt 25.12 используется APK; в инструкции указан `--allow-untrusted`, т.к. пакет не подписан. Требуется pinned asset/sha256, точная совместимость с версией podkop и используемыми outbounds, независимый snapshot/rollback **до установки**. Не ставить на VM202 по этому документу.
- Сборка `podkop-engine` облегчённая: не все outbounds sing-box поддерживаются. `podkop-engine-full` шире, но тоже имеет ограничения. Выбор по реальному config без секретов.

## 3. Остальные решения и границы применимости

| Вариант | Что закрывает | Чего сам по себе не закрывает | Решение R12 |
|---|---|---|---|
| Штатный Podkop stop + OpenWrt procd | Восстанавливает DIRECT при *корректной* остановке, рестартует упавший sing-box | VPN-сервер умер при здоровом sing-box, зависший sing-box, битая DNS-конфигурация | **База, обязательно испытать** |
| podkop-engine failsafe + `urltest.fallbacks` | Готовый механизм crash/hang→restart/stop Podkop; потенциально предпочтение VPN→DIRECT | Полный отказ VM, невалидная UCI-подписка от стороннего updater | **Предпочтительный кандидат в LAB** |
| Малый health-check поверх штатного Podkop | HTTPS/DNS-проверка и вызов штатного `service podkop stop` при подтверждённом отказе | Сам по себе не делает безопасную транзакционную запись UCI и не восстанавливает повреждённую VM | Резерв, если engine непригоден |
| [ProxyRules](https://github.com/m0n5ter/ProxyRules) | Готовый альтернативный стек с direct-on-stop и цепочками failover | Смена стека/конфигов, риск несовместимости подписок | Не мигрировать без отдельного сравнительного LAB |
| OpenWrt `mwan3` / PBR | Переключение между физическими WAN или поднятыми VPN **интерфейсами** | Не лечит зависший sing-box, FakeIP DNS, падение пользовательских outbound VLESS | Для данного Proxy-over-WAN не основной выбор |

Источники дополнительно: [sing-box URLTest](https://sing-box.sagernet.org/configuration/outbound/urltest/), [OpenWrt mwan3](https://openwrt.org/docs/guide-user/network/wan/multiwan/mwan3-nft), [ProxyRules](https://github.com/m0n5ter/ProxyRules). Обычный `URLTest` выбирает по доступности/задержке среди заданных outbounds и **сам по себе не гарантирует приоритет VPN над DIRECT**, нужен явно определённый fallback-порядок и проверка.

## 4. Как использовать результаты в R12

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
