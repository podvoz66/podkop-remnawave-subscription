# R12: минимальный root-owned SSH capability для LAB203/204

Статус: ПОДГОТОВЛЕНО, НЕ установлено. Новый MCP-сервер не нужен: Codex может вызывать
существующий SSH alias proxmox-cloud и точный sudo wrapper. Production не менялся.
MCP текущего агента: proxmox_readonly inventory/node_status/guest_status; proxmox_ops
только CT101–106 start/reboot с согласованием, не использовать для этой задачи.

## Текущая read-only проверка

proxmox-cloud=codexops UID1001. qm list подтвердил203/204 running, память1024MiB,
bootdisk0.12/3.00GiB. Конфигурации/serial закрыты правами; sudo только inventory и
старые фиксированные CT wrappers. socat и timeout установлены. Read-only Stage5
ip link/MAC/brctl/UCI внутри203 агент НЕ получил: не обходить root/serial permissions.
Stage4 runtime PASS и stock br-lan192.168.1.1/24/no default приняты от владельца.

## Единственное предлагаемое изменение полномочий

[Wrapper](../scripts/lab/codexops-r12-lab) root:root0755,
[bootstrap](../scripts/lab/install-r12-lab-access.sh) и отдельный sudoers файл
/etc/sudoers.d/codexops-r12-lab, root:root0440. Новые paths должны отсутствовать:
существующие реализации не заменяются. Baseline отсутствия файлов сохраняется в
root0700 /var/lib/codexops-r12-lab-access. Откат удаляет только новые неизменённые
wrapper/grant; ни VM, ни диски, ни прежний sudoers не меняются.

Точные команды разрешены для203/204: inspect, serial, start, stop. Никаких qm set,
restore/destroy/clone, произвольного VMID, host shell, SETENV, пути файла или команды
на хосте. Конфигурация каждый раз проверяется: имя LAB, onboot0, scsi0 extra-storage,
boot/scsi0, serial0/socket, точные stream args/MAC; netN/passthrough/hooks запрещены.
Serial — прямой bounded120s socat к root socket; позволяет shell/передачу данных
ТОЛЬКО внутри изолированного гостя. Не предназначен для чтения секретов.
Существующий терминал владельца надо отсоединить; занятый socket → STOP.
Проверка console busy через ss — best effort, не глобальный lock всех root terminals;
владелец не должен подключать второй терминал во время автоматизации.

inspect маскирует password/sshkeys. Serial не пишет transcript на хост; клиент не
должен запрашивать/публиковать приватные ключи или cloud-init user-data. Это доступ
к лабораторным гостям, не к сетевой инфраструктуре хоста. Guard не доказывает отсутствие
ошибок QEMU/host; обычные границы VM остаются необходимыми.

## Один owner bootstrap — только после явного разрешения

После согласования агент может передать два reviewable исходника в
/home/codexops/r12-lab-access (это staging, не sudo grant). Root владелец один раз
копирует их в новый root-only каталог, проверяет checksum и запускает bootstrap:

```bash
set -e
umask 077
stage=$(mktemp -d /root/r12-access.XXXXXXXX)
install -o root -g root -m 0600 /home/codexops/r12-lab-access/codexops-r12-lab "$stage/"
install -o root -g root -m 0600 /home/codexops/r12-lab-access/install-r12-lab-access.sh "$stage/"
(cd "$stage" && printf '%s  %s\n' \
  3fb991f06371f8d6a98ca9e959f87cb061e6ced494a0d38b48da5e7ebb7bc338 codexops-r12-lab \
  467a74cdd399d207781c71549783db69e44e8417b4caa344c99e4835f342efe4 install-r12-lab-access.sh | sha256sum -c -)
bash "$stage/install-r12-lab-access.sh" install
# Точный rollback из той же root shell:
# bash "$stage/install-r12-lab-access.sh" rollback
```

Bootstrap проверяет root/hostname, existing sudoers через visudo, зависимости,
wrapper hash и syntax; создаёт только новый grant, перепроверяет visudo. При ошибке
после начала установки удаляет новые grant/wrapper и сохраняет marker. Никаких
VM действий/пакетов/сети. Если файл изменился после установки, rollback STOP, не удалять
вслепую. Для повторной установки после rollback нужен отдельный review marker.

## После принятой установки — агент самостоятельно

```sh
ssh proxmox-cloud sudo -n /usr/local/sbin/codexops-r12-lab inspect 203
ssh proxmox-cloud sudo -n /usr/local/sbin/codexops-r12-lab inspect 204
ssh -T proxmox-cloud sudo -n /usr/local/sbin/codexops-r12-lab serial 203
```

Не передавать пароль через stdin/командную строку. Serial203 должен показать уже
аутентифицированный LAB root shell; иначе STOP. Сначала только ip link show,
sysfs MAC/master, brctl show, uci -q show network (без secrets, stock config).
Сопоставить eth0/eth1 по03:01/03:02, НЕ угадывать номера. До применения сохранить
локально внутри LAB203 /etc/config/network и runtime состояние, подготовить обратный
UCI+runtime откат, проверить LAB204 namespaces. Только после этого Stage5 адреса
10.253.202.1/24 LAN,10.253.203.2/24 WAN и обмен с LAB204. Конкретные UCI изменения
сейчас не составляются без live mapping. Никаких production probes/ключей.

Файлы передавать существующим serial/base64+SHA способом; root shell проверять
ответом на nonce, echo не считать исполнением команды. Не запускать текущий
r12-lab-serial-transfer.py вслепую: он фиксирован на Stage4 и не является generic203 tool.

## Границы приёмки

Локальные проверки: Bash syntax, негативные CLI tests201/202/107/host-shell/extraargs,
проверка pinned hash. Это НЕ доказательство живого sudoers/QEMU/serial. После установки
первый gate — inspect203/204 и отклонение inspect202. Любое несовпадение → STOP.
VM-independent disk recovery этим wrapper НЕ реализован: offline disk switch требует
отдельного ограниченного action и испытаний; пока остаётся BLOCKER production.
Ни bootstrap, ни wrapper на PVE не выполнялись. Draft PR7 / PRODUCTION NO-GO.
