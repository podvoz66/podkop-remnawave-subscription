# R12 Stage4 — только LAB204, подготовка до GO

Stage1–3 не повторять. По подтверждению владельца: Debian12, sudo без пароля,
ens2/ens4 unmanaged/DOWN/noIP, Cloud-Init done, Unix isolation принята.
Актуальные потенциальные конфликты может проверить только `check` ВНУТРИ LAB204;
доступного SSH в изолированную VM нет. Не выдавать локальную syntax-проверку за live PASS.

Скрипт [r12-lab-stage4.sh](../scripts/lab/r12-lab-stage4.sh) — Bash Debian12,
check/verify не пишут; apply/rollback используют flock, root-only marker и boot/netns
identity. Требуются уже установленные iproute2/util-linux; пакеты не устанавливать.
Он не содержит команд PVE, host networking, production SSH или DNS.
Защита идентичности: Debian12 + исходный netns + ровно lo/ens2/ens4 + точные LAB MAC.
Это не доказательство безопасности гипервизора: Unix isolation принята на Stage2–3.

## Через serial

Перенести текст скрипта в отдельный файл внутри LAB204 через serial, без секретов,
например here-doc с quoted EOF. Не выполнять apply до отдельного GO.
Файл должен находиться в root-owned каталоге (например /root/r12-lab-stage4.sh),
root:root0600. Не скачивать через production NIC и не перенастраивать Cloud-Init.

```sh
sudo -n bash -n /root/r12-lab-stage4.sh
sudo -n bash /root/r12-lab-stage4.sh check
# Только после отдельного GO:
sudo -n bash /root/r12-lab-stage4.sh apply
sudo -n bash /root/r12-lab-stage4.sh verify
```

PASS: r12-lan содержит lo UP + ens2 UP/MAC02:52:12:02:04:01/10.253.202.2/24;
r12-wan — lo UP + ens4 UP/MAC02:52:12:02:04:02/10.253.203.1/24.
В исходном netns только lo; никаких default routes ни в одном новом namespace.
IPv6 addrgenmode интерфейсов временно none, чтобы не создавать побочные link-local
адреса/маршруты; исходный режим сохранён для rollback. Существующих IP/routes по
preflight быть не должно. LAN default через LAB203 здесь тоже НЕ добавляется.
LO/connected routes создаются ядром только внутри LAB204 namespaces.

STOP: неверная MAC/ОС, лишний интерфейс/адрес/route/master, занятое имя namespace,
неизвестный state, missing tools или ошибка. Ничего не переустанавливать.
apply не повторяет операции при готовом state: выполняет verify. При частичной ошибке
state сохраняется, автоматических повторов нет — диагностировать и rollback.

## Точный rollback (только Stage4, до fixture-процессов/новых маршрутов)

```sh
sudo -n bash /root/r12-lab-stage4.sh rollback
```

Rollback проверяет принадлежность обоих namespaces и MAC, отсутствие процессов и
чужих адресов/маршрутов; удаляет только добавленные IPv4, возвращает ens2/ens4
DOWN/noIP в netns PID1 и исходный addrgenmode, удаляет только свои namespaces.
Состояние сохраняется /run/r12-stage4.rolled-back.TIMESTAMP.PID, активный marker снят.
Если кто-то добавил DHCP/IPv6/процессы/маршруты — STOP вместо слепого flush/delete.
После reboot /run state и namespaces исчезнут; permanent config не меняется.
Скрипт не является rollback последующих Stage5+: сначала отдельно остановить fixture
и согласовать возврат поздних изменений. Не удалять state вручную при частичной ошибке.

Проверено локально: bash -n, git diff --check. Реальная netns/runtime проверка НЕ
выполнялась; check на LAB204 — обязательный gate до GO. LAB203/VM202 не затрагивались.
