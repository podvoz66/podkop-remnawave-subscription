# VM202: ручная установка podkop-engine-full и диагностика VPN/Fail-safe — 24.11.2026

> Статус документа: подтверждённые факты из вывода владельца в ChatGPT и дальнейший план проверки. Это **не** утверждение о полной готовности R12 и не разрешение на новые production-изменения. Ветка документации создана отдельно от Draft PR #7, без merge.

## 1. Окружение и граница изменений

- Production: **VM202** `OpenWrt-Podkop`, Proxmox `podvoz-beelink`; основной шлюз домашней сети. OpenWrt 25.12.4 x86_64, Podkop 0.7.24-r1, `apk`.
- Владелец выполнил ручную замену `sing-box 1.13.21-r1` → `podkop-engine-full 1.14.4-r28` (**sing-box 1.14.4-pdk-r28**).
- Затронут только VM202: на PVE создана резервная копия; конфигурация `podkop.settings.dont_touch_dhcp` изменена `1 → 0`; `apk` удалил штатный sing-box и `kmod-inet-diag` как его зависимость.
- **Не развёрнуты** новые guards/rollback-watcher из Draft PR #7, не менялись Remnawave API-объекты, пользователи, шаблоны и ключи. Не утверждать обратное.
- Консоль `qm terminal 202` открывалась владельцем из домашней LAN; независимая автономная host-level recovery при отказе guest/kernel **не проверялась**.

## 2. Backup и возможность восстановления

- `vzdump` VM202, `snapshot`, 24.11.2026 00:44:08 +05:00, `/mnt/backups-hdd/dump/vzdump-qemu-202-2026_11_24-00_44_08.vma.zst`, `Backup job finished successfully`.
- `zstd -dc ... | vma verify -` с `pipefail`: `VERIFY_RC=0`. Архив проверен на целостность структуры, но тестовое восстановление отдельной VM не проводилось.
- Зафиксированная копия вне pruning: `/mnt/backups-hdd/manual-preserved/vm202-pre-podkop-engine-full/vzdump-qemu-202-2026_11_24-00_44_08.vma.zst`; `cmp` → `BACKUP_PRESERVED=PASS`.
- В госте сохранены `/root/podkop-engine-install/config-before.tar.gz`, `dhcp-before-failsafe`, `podkop-before-failsafe`, старый бинарник `sing-box-1.13.21.original` (SHA256 `2434339b36defef0a083ebfdae3a781dbb09eda3b3f43f4c2cfc4df23e2a637b`).
- Оригинальный APK `sing-box 1.13.21-r1` в репозитории не найден (`apk fetch` RC1). Сохранённый бинарник **не равен** полному пакетному rollback. Основной подтверждённый откат — VMA backup через PVE; план восстановления предполагает перерыв в работе VM202/сети, команда восстановления намеренно не автоматизирована.
- Установочный APK проверен SHA256 `22b4d92279f754c45d85b2d58ca8ffc041896b026572918f9cb9d37c950f1530`. `apk add --simulate` и проверка нового исполняемого файла `sing-box check` выполнены до установки.

## 3. Принятые результаты

| Проверка | Факт |
|---|---|
| `apk add --allow-untrusted` | RC0; `podkop-engine-full-1.14.4-r28` installed |
| `/etc/init.d/podkop restart` | RC0; sing-box process запущен |
| `sing-box check -c /etc/sing-box/config.json` | RC0 |
| DNS при STOP | `127.0.0.42` удалён из dnsmasq; `noresolv=0`; `nslookup 127.0.0.1` успешен |
| Маршрутизация при STOP | `PodkopTable` и правило fwmark отсутствуют |
| DNS и маршрутизация после START | `127.0.0.42`, `noresolv=1`, `PodkopTable`, fwmark восстановлены |
| HTTPS после установки | `https://openwrt.org` → HTTP200 с роутера |
| LuCI / Podkop | DNS, sing-box, nftables, outbounds, FakeIP показывали PASS |
| failsafe init | `enabled` RC0; `status=running`; procd `failsafe` PID 19777 |
| liveness | UCI `sing-box.main.liveness=1`; `failsafe` не задан — штатное enabled default |
| procd sing-box | `respawn threshold=600 timeout=5 retry=5`; `nofile=65536`; `SING_BOX_DNS_FALLBACK=ubus` |

Внимание: работа штатного STOP→DIRECT→START доказана на production. **Автоматический fail-open после шести аварий и DNS-hang на production НЕ проверялся.** Нет `/etc/sing-box/failsafe.last` и нет подтверждения выполнения предложенного 18-секундного SIGKILL/watchdog-теста. Повторять fault injection без отдельного согласованного плана нельзя.

## 4. Наблюдения, которые нельзя смешивать

### A. Потеря подписочных URLTest-ссылок (предыдущий инцидент 23.11)

[Исторический разбор](incident-20261123-0800.ru.md) подтверждает cron/updater: получено `main=6, USA=0`, затем секция `USA` записана пустой, podkop упал на `URLTest proxy links is not set`. Отсутствие защитной проверки пустой USA в **production updater** доказано исходным кодом. Почему входной ответ subscription дал USA=0, не доказано; нельзя приписывать это новой сборке engine или считать, что PR #7 уже внедрён.

### B. `N/A` и тайм-ауты при *сохранённых* VPN-выходах (24.11)

- На скриншоте LuCI URLTest: main — 3 узла с задержкой и 5 с `N/A`, USA — 2 с задержкой и 1 с `N/A`; Podkop и sing-box отображались running.
- В `logread` (01:11–01:13 +05) были `context deadline exceeded` около 15 s через `main-6-out`, `main-1-out`, `main-2-out`, включая ChatGPT/GitHub/Telegram; 01:20:41 — также `main-1-out` для YouTube/другого адреса. `N/A` не доказывает удаление ключей.
- URLTest `sing-box.main.urltest_download_check=1`; URL `https://speed.cloudflare.com/__down?bytes=65536`. В журнале 01:12:49 `main-2-out download test could not run … context deadline exceeded`. **Это диагностический сигнал, не доказательство первопричины**; отключение теста без сравнительного плана не разрешено.
- Изменение PID `22233 → 26739` объясняется `Podkop reload` в 01:13; команда, вызвавшая reload, неизвестна. Позже PID `330` при 01:24, но reboot или respawn отдельно не доказаны; нужно сверить `btime/uptime` и procd.
- В `logread` нет доказанного `instance.fail`/failsafe аварийного отключения, `failsafe.last` отсутствует. Не утверждать, что failsafe устраняет недоступность отдельного endpoint.

## 5. План для VS Code / Codex: только read-only до нового GO

1. Прочитать `AGENTS.md`, R12 карточку и этот отчёт, текущие R12 guards и `docs/incident-20261123-0800.ru.md`. Подтвердить branch/HEAD; не путать Draft PR7 (не deployed) с вручную установленным engine.
2. Read-only inventory VM202: `date`, `uptime`, `/proc/stat btime`, `pidof sing-box`, `ubus call service list` для sing-box и podkop-engine; `nft list tables`, `ip rule`, DNS, WAN; конфигурации считывать только с удалением secrets.
3. Разделить две ветки исследования: **A** race/empty USA subscription updater (сохранять прежние/ручные ключи, preflight, no destructive commit); **B** работоспособность *существующих* узлов: per-outbound VLESS/Hysteria2, TLS/SNI/XHTTP, маршрут WAN, блокировки, URLTest/download-check и ошибки на стороне сервера. Показать корреляцию по времени/тегу, не раскрывать UUID/ключи/полные URL.
4. Получить неизменяемый baseline и составить диагностическую матрицу с повторными запросами/длительностями и подтверждением с LAN-клиента; не менять список URLTest до доказательства причины.
5. Fail-safe: сравнить /usr/libexec/podkop-engine/failsafe с upstream, определить порог procd (600/5/5), отрицательные условия liveness и разделить тест single crash (respawn) от terminal fail-open (несколько падений) и DNS-hang (примерно 49–72 s). **18-секундное окно годится для наблюдения single respawn, не гарантирует полный fail-open.**
6. До fault injection на основном шлюзе согласовать план: root PVE/serial console, owner LAN, снимок/сохранённый backup, независимый от sing-box доступ к восстановлению, ограничения по времени, автоматический fallback DIRECT и критерии STOP. Отдельно признать невозможность гарантировать guest-only таймер при зависании kernel.
7. После каждого разрешённого теста — реальные LAN DNS UDP/TCP, HTTP(S), nft/ip rule и работа ключевых сервисов. Записать время восстановления, журналы с редактированием секретов; не проводить reboot/restore/host changes без нового разрешения.
8. Подготовить MR/PR только документации/тестов на отдельной ветке. **Никаких** Remnawave changes, замены подписок/пользователей, выключения download check, рестартов, `kill -9` или `apk` без отдельного согласования.

## 6. Критерии закрытия

- Раздельно доказаны или помечены неизвестными причины A и B; получена таблица узлов, с повторными пер-узловыми тестами, контрольной группой и временем наблюдения.
- Для fail-safe чётко указаны отдельные результаты normal, single-crash, terminal crash-loop→DIRECT, liveness/hang, post-failure recovery; отсутствие результата не выдаётся за PASS.
- Подтверждение 20-секундного auto-rollback допускается только для фактически испытанной процедуры; полный fail-open не обязан укладываться в 20 s.
- Обновлены R12 документы, список остаточных рисков, точные обратимые изменения и разрешения владельца.

Источники: владелец/выводы VM202 24.11.2026; [R12 лабораторные результаты](lab-podkop-engine-results.ru.md); upstream podkop-engine [INSTALL.ru.md](https://github.com/podkop-net/podkop-engine/blob/main/docs/INSTALL.ru.md) и [FEATURES.ru.md](https://github.com/podkop-net/podkop-engine/blob/main/docs/FEATURES.ru.md). Секреты и full logs не публиковались.
