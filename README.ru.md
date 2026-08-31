# AdeptPro Bootstrap v2

Production-заготовка автоматического ввода OpenWrt-роутеров с Podkop,
Remnawave subscription sync и прямым администрированием через Tailscale. Этот PR
только готовит GitHub-репозиторий и static mirror layout — production не меняется.

## Схема

```text
Remnawave Wizard
  -> bootstrap.adeptpro.online
  -> Tailscale
  -> Podkop 0.7.22 из AdeptPro mirror
  -> русский интерфейс Podkop
  -> Remnawave subscription
  -> daily deferred sync
  -> reboot
  -> postboot ttyd one-shot
```

Текущий production wizard остаётся pinned на
`3cf06121c03815c1c50c620a55ef46cdafa5e949`. Этот PR его не переключает.

## Поддерживаемые OpenWrt

| OpenWrt | Менеджер | Формат | Architecture пакетов Podkop |
|---|---|---|---|
| 24.10.x | `opkg` | `.ipk` | upstream `all` |
| 25.12.x и новее | `apk` | `.apk` | upstream `all` |

Bootstrap читает `DISTRIB_RELEASE`, `DISTRIB_ARCH`, `DISTRIB_TARGET`, фактически
определяет package manager и сверяет их. Противоречие версии и менеджера,
неизвестный менеджер, неизвестная архитектура или отсутствие platform в manifest
останавливают bootstrap до изменения Podkop.

В официальном релизе 0.7.22 подтверждены три IPK и три APK: `podkop`,
`luci-app-podkop`, `luci-i18n-podkop-ru`. Makefile объявляет пакеты как `all`.
Server-side sync требует точного набора assets и никогда не использует `latest`,
не угадывает имена и не конвертирует IPK в APK.
Официальные Dockerfile tag-а используют OpenWrt SDK 24.10.6 для IPK и 25.12.3
для APK.

## Почему router не использует GitHub

На чистом роутере VPN ещё нет, а GitHub может быть недоступен. Все router-side
скрипты используют только:

```text
https://bootstrap.adeptpro.online/openwrt/v1
```

GitHub разрешён только server-side скрипту `scripts/sync-podkop-mirror.sh`. Он
публикует раздельные `opkg/all` и `apk/all`, проверяет непустые файлы, вычисляет
SHA256 и формирует manifest. Сторонние `.ipk/.apk` в Git не коммитятся.

## Безопасная установка Podkop

Порядок неизменяемый:

```text
скачать manifest
  -> проверить schema/version/package manager/architecture
  -> скачать все 3 пакета
  -> проверить size и SHA256 каждого
  -> установить podkop
  -> установить luci-app-podkop
  -> установить luci-i18n-podkop-ru
```

При любой ошибке package install, изменение Podkop config и restart сервисов не
выполняются. Официальный interactive installer не запускается, вопросов `y/n` нет,
русский интерфейс Podkop устанавливается автоматически.

## Daily Remnawave sync без restart

Cron:

```cron
50 3 * * * /usr/bin/update-podkop-from-remnawave.sh >/tmp/podkop-sub-update.log 2>&1
```

Guard сохраняет subnet cache precheck/apply и делегирует real updater. Updater
сохраняет manual links и unrelated sections, отклоняет placeholders, строит
изолированный UCI candidate и выполняет semantic compare.

Если состояние одинаковое — нет UCI commit. Если изменилось — создаётся backup,
candidate коммитится и создаётся marker:

```text
/etc/podkop-remnawave/pending-runtime-reload
```

Daily sync никогда не останавливает и не перезапускает Podkop, не перезапускает и
не убивает sing-box. Новые VPN-ключи активируются при следующем штатном старте
Podkop/sing-box или reboot.

Bootstrap идемпотентно гарантирует `podkop.settings.dont_touch_dhcp=1`, поэтому
обычный direct internet продолжает работать при остановленном Podkop.

## Tailscale и postboot ttyd

Tailscale устанавливается из OpenWrt repository, включается и запускается с
`--accept-dns=false`, `--ssh=false` и hostname из имени роутера. Auth key не
выводится. SSH/LuCI открываются только через Tailscale, WAN ports не открываются.

`ttyd` отсутствует в critical path. Bootstrap только включает поздний one-shot
`adeptpro-postboot`. После reboot он ждёт сеть и с ограниченным числом попыток
ставит `ttyd` и `luci-app-ttyd` через opkg либо apk. При успехе one-shot отключает
себя. При ошибке не делает reboot и не ломает основную конфигурацию.

## Будущее развёртывание mirror

Пример находится в `deploy/bootstrap.adeptpro.online/`. Рекомендуемый root:
`/srv/bootstrap.adeptpro.online`, публикация — immutable releases и atomic symlink
`current`. Реальный Nginx этим PR не меняется.

После отдельного deploy выполнить только read-only проверки:

```sh
curl -fsS https://bootstrap.adeptpro.online/health.txt
curl -fsS https://bootstrap.adeptpro.online/openwrt/v1/manifest.json
```

Ожидаемый `/health.txt`: `OK`. Production Remnawave wizard нельзя переключать до
успешного deploy и проверки mirror.

## Тесты и безопасность

```sh
sh tests/test-bootstrap-static.sh
```

Тесты проверяют отсутствие GitHub в router scripts, daily cron, отсутствие
periodic restart/kill, оба package manager, architecture fail-closed, SHA256,
русский non-interactive Podkop, postboot ttyd, masking и shell syntax.

Нельзя коммитить реальные `SUB_URL`, subscription tokens, Tailscale/OAuth secrets,
UUID/private keys или VPN links.
