# R12 Stage5: live LAB203 network mapping и связность PASS

Источник: Codex через proxmox-cloud → sudo codexops-r12-lab serial203/204.
Serial203 освободился; аутентифицированные root shell обеих LAB подтверждены id -u.
Только LAB изменялись. VM201/202/PVE bridges/routes/DNS не менялись.

## Mapping, preflight

- eth0 MAC02:52:12:02:03:01, единственный port br-lan → Unix lab-lan.
- eth1 MAC02:52:12:02:03:02, без master → Unix lab-wan.
- brctl: br-lan только eth0, STP no. Stock UCI: lan static192.168.1.1/24,
  wan DHCP/eth1, wan6 DHCPv6/eth1. Default route отсутствовал, pending UCI пуст.
- Host wrapper ранее принял обе VM: exact pinned Unix backends, no PVE NIC,
  onboot0, scsi0 extra-storage; inspect202 отклоняется sudo. Это config gate,
  не доказательство защиты от аппаратного сбоя/гипервизора.

## Backup/rollback до изменений

Создан внутри LAB203 root-only /root/r12-stage5:
network.before, network.sha256, addr.before, route.before, rollback.sh (0700).
Конфиг не публикуется, stock UCI содержит device-specific идентификаторы.
network.before SHA256:
1036f38cb97ea83b5993c51a3636725c6fdd7bb230c37079696ce40097a6322e.
Rollback сохранён также в [исходниках](../scripts/lab/r12-lab-stage5-rollback.sh).

```sh
# Внутри LAB203, не PVE:
sh /root/r12-stage5/rollback.sh
```

Он проверяет LAB MAC, checksum и отсутствие pending UCI, возвращает только исходный
network и reload сети LAB203. DNS config/firewall не меняет. Проверено реальным
rollback: R12_ROLLBACK_APPLIED, cmp исходного файла PASS; runtime снова только
192.168.1.0/24 br-lan src192.168.1.1, без WAN IP/default. Не применять после будущих
Stage6 изменений без проверки дополнительных файлов/fixtures: это Stage5-only rollback.

## Применённые изменения (сначала apply, затем rollback, затем reapply)

Перед первым apply: sha256sum backup и cmp baseline с /etc/config/network PASS.
Перед reapply: cmp baseline снова PASS. Только эти UCI поля изменены:

```sh
uci set network.lan.ipaddr='10.253.202.1/24'
uci set network.wan.proto='static'
uci set network.wan.ipaddr='10.253.203.2/24'
uci commit network
/etc/init.d/network reload
```

Итог network SHA256:
650cbab30ad388fd953b326e0236e36282a3b7e9e077713b88209a67948e6605.
Ни gateway/default, ни DNS не добавлялись. IPv6/wan6 stock настройки не менялись.
BusyBox не имеет stty: попытки stty -echo/echo дали not found; это только
терминальное echo, сеть/применение не затронуты. В дальнейшем stty на LAB203 не использовать.

## Изолированные live проверки

| Проверка | Результат |
|---|---|
| LAB203 br-lan→10.253.202.2 | 2/2 ICMP,0% loss, два раза (apply/reapply) |
| LAB203 eth1→10.253.203.1 | 2/2 ICMP,0% loss, два раза |
| LAB204 r12-lan→10.253.202.1 | 2/2 ICMP,0% loss |
| LAB204 r12-wan→10.253.203.2 | 2/2 ICMP,0% loss |
| r12-lan curl --noproxy '*' http://10.253.202.1/ | HTTP200 |
| LAB204 default route r12-lan/r12-wan | оба пустые |
| LAB204 endpoints | ens2 .202.2/24 UP, ens4 .203.1/24 UP, каждый в своём netns |

HTTP200 подтверждает LAN router endpoint, НЕ LAN→WAN транзит и НЕ VPN/DNS fail-open.
Полный HTTP/HTTPS/DNS transit пока UNVERIFIED. curl/openssl/python3 присутствуют
в LAB204 (только command -v, Python не запускался); пакеты не устанавливались.

Serial203 закончился штатным лимитом wrapper120s (exit124), после завершения всех
команд, без reboot/stop гостя. При последующем освобождении serial204 закрывать
только свой клиент; чужие console не перехватывать.

Следующий этап: локальные HTTP/HTTPS/DNS fixture в r12-wan, ограниченные маршруты
только внутри LAB, измерение LAN→LAB203→WAN транзита. До изменений сохранить новые
baseline/rollback; не считать Stage5 достаточным для VPN fault tests или production GO.
Draft PR7 / PRODUCTION NO-GO.
