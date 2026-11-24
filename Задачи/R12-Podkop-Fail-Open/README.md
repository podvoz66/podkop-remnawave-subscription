# R12 — Podkop Fail-Open VM202

**Итог закрытия 24.11.2026:** R12 закрыт со статусом `CLOSED — PARTIALLY VALIDATED / OPERATIONALLY RESTORED`. После двух отдельных одиночных SIGKILL procd повторно запускал sing-box; последний подтверждённый снимок: PID `15536`, `running=true`. Полный terminal fail-open и DIRECT egress LAN-клиента при исчерпании retry **не доказаны**. Новые fault/reboot tests прекращены по решению владельца. Подробности: [итоговый отчёт](04-Итог-закрытия-2026-11-24.md).

**Обновление 24.11.2026:** владелец отдельно установил `podkop-engine-full 1.14.4-r28` на production VM202 и подтвердил DNS/HTTPS/штатный STOP→DIRECT→START. Это не развёртывание экспериментальных R12 guards и **не** приёмка полного fail-open или независимого host rollback. В дальнейшем диагностика причин `N/A`/timeouts и отдельный контролируемый fail-safe тест через VS Code/Codex: [checkpoint](../../docs/vm202-production-rollout-20261124.ru.md), [продолжить](03-Продолжить-в-Codex.md).

**Исторические ограничения Draft PR #7 ниже** относятся к неразвёрнутым R12 guards; новая ручная установка engine описана выше.

**PRODUCTION NO-GO.** До отдельного разрешения никаких установок/перезапусков/изменений VM202 или PVE.
Новый приоритет: [независимый rollback, Stage1/Stage2](../../docs/independent-rollback.ru.md).
Предыдущий rollback через новый guard недостаточен. Нужен изолированный OpenWrt-стенд,
проверенный LAN SSH PVE→VM и решение сценария SSH+guest scheduler unavailable.

Статус: разработка и локальная проверка; production НЕ изменён.

[План](01-Задача-и-план.md) · [Результаты](02-Ход-работы.md) · [Продолжение](03-Продолжить-в-Codex.md) · [Эксплуатация и rollback](../../docs/fail-open.ru.md)

Цель: WAN и DNS работают при отказе Podkop/ключей, подписки не применяются пустыми,
recovery подтверждает реальный HTTP(S). Отдельное согласование требуется для установки,
старта guard, изменения автозапуска и всех fault/reboot тестов.
