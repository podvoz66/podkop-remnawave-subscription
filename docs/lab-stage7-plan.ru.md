# R12 Stage7 — подготовка после Stage6 PASS, не выполнено

Stage6 принят реальным LAN→WAN HTTP/TLS/DNS и rollback. Production NO-GO.
LAB203 сейчас не содержит podkop/sing-box/curl (command -v); в Stage6 ничего не
устанавливалось. Поэтому пока нельзя запускать готовый Fail-Open guard и утверждать VPN PASS.

1. Подготовить проверенные офлайн-пакеты именно для LAB OpenWrt25.12.4 x86/64 и
   согласованные версии Podkop/sing-box; проверить package manager, зависимости,
   подписи/checksums/архитектуру, свободное место. Никаких production ключей/config.
   Новый offline install — отдельный лабораторный этап, не был выполнен Stage6.
2. Сохранить baseline диска/пакетов/init/config гостя и независимый rollback ДО установки.
   Host capability разрешает inspect/serial/start/stop, НЕ disk snapshot/restore/switch.
   Для полного отказа kernel отдельный rescue disk/host rollback ещё не реализован:
   это остаётся BLOCKER независимого полного восстановления, не скрывать ограничение.
3. Synthetic VPN endpoint в r12-wan, два синтетических набора main/USA, тестовая
   подписка обслуживается локальным fixture. Продолжать использовать локальный TLS CA,
   HTTP token/DNS UDP+TCP и WAN receipt; различать DIRECT и VPN по независимым
   endpoint/server logs, а не только PID/успешному ping.
4. После preflight/backup: NORMAL; неверные ключи; пустая USA; остановка sing-box/
   Podkop; DNS failure; recovery3success/cooldown; reboot только LAB. При каждом
   сценарии LAN HTTP/TLS/DNS, serial доступ и отсутствие внешнего route/bypass.
5. Отдельно полный отказ LAB guest: SSH/procd/QGA unavailable/kernel hang;
   только после разработанного ограниченного host recovery/fencing и rescue image.
   stop/start не является восстановлением повреждённого диска. Ни один такой тест
   не переносить на202 и не расширять existing wrapper до произвольного qm set.

Stage6 rollback доступен автономно в204, Stage5 rollback203 отдельно. Перед Stage7
согласовать их композицию с новыми VPN routes/nft rules, не удалять чужие состояния.
Следующий безопасный шаг: офлайн package/readiness inventory и проект snapshot/rescue
в пределах LAB; никаких production deploy/merge.

## Изменение приоритета после исследования готовых fail-open решений (2026-11-23)

До разработки самописного crash-watchdog сравнить штатный `podkop stop`,
OpenWrt `procd`, `podkop-engine` с готовым `failsafe` и `urltest.fallbacks`.
[Основания, источники, границы и LAB-критерии](r12-native-fail-open-options.ru.md).
Это изменение плана, не установка и не доказательство, что полное переключение
VPN→DIRECT→VPN существует в обычном Podkop. Пункты snapshot/host rollback,
transaction-safe updater и полный guest recovery остаются обязательными.

## Фактическое исполнение podkop-engine

[Текущий LAB-отчёт](lab-podkop-engine-results.ru.md) заменяет прежние статусы подготовки.
Owner разрешил guest-only tests после проверенного package/config rollback без новых
root grants; это не снимает обязательный BLOCKER независимого host disk recovery.
Production NO-GO. Автоматический URLTest DIRECT→VPN доказан, terminal failsafe recovery
самостоятельно не реализует; provider DNS fallback требует отдельной приёмки.
