# Продолжить R12

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
