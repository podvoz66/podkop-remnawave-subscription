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
