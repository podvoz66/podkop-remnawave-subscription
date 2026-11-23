# R12 Stage7: offline readiness + предложенный host-side recovery203

**STOP перед установкой пакетов: требуется новый owner-approved root capability.**
Ничего не установлено в LAB203, sudo не расширялся, capture/restore/arm не выполнялись.
Production VM201/202/ключи/PVE bridges/routes/DNS не менялись. Stage6 остаётся принятой базой.

## Новая read-only диагностика LAB203

OpenWrt25.12.4 r32933-4ccb782af7, x86/64/x86_64; kernel6.12.87.
APK tools3.0.5 (apk-mbedtls), не opkg. Root FS100692KiB, available75304KiB (~73.5MiB).
/tmp available504576KiB. Стандартные firewall4/nftables-json/dnsmasq/procd/netifd/
uci/ca-bundle/openwrt-keyring/usign установлены. Podkop/sing-box/curl отсутствуют.
Init boot/cron/network/firewall/dnsmasq/dropbear/rpcd/uhttpd присутствуют, proxy init нет.
Чтение apk info выдало missing-cache-index warnings, а не apk update; сеть не подключалась.
Kmod feed строго6.12.87-1-d037e17efc2c7cd4972f63d6de88677f.

## Офлайн-набор пока НЕ готов к установке

В Codespace /tmp/r12-stage7-packages (не Git, не LAB rootfs) скачаны8 APK:
Podkop0.7.24-r1, sing-box1.13.21-r1, curl8.23.0-r1, jq1.8.1-r2,
coreutils-base649.9-r2, bind-dig9.20.31-r1, flock2.41.5-r1,
kmod-nft-tproxy6.12.87-r1. Сохранены официальные base/packages indexes.adb и index.json.
[Имена/размеры/SHA256/статус](evidence/r12-stage7-package-manifest.json).

[Официальный Podkop release](https://github.com/itdoginfo/podkop/releases/tag/0.7.24)
публикует asset SHA256; podkop APK совпал:
a444a784a7dc22b2ba17336b773f75b27861daf3fb358fea21b31935a975318e.
Kmod совпал с [OpenWrt target manifest](https://downloads.openwrt.org/releases/25.12.4/targets/x86/64/sha256sums):
3d63272a15450a2ca92d7dfdc416094f0041f592acca5635299eb9f7592a428e.
Sing-box SHA256 вычислен локально (НЕ утверждение о проверке trusted signature):
e76298c3581918adae1e7da49d293b221fa14cb082bf3ca1d1b80b2e9f7b0964.
Feed index.json подтвердил x86_64 и имена версий; APK metadata architecture ещё не прочитана.

[Tagged Makefile Podkop](https://github.com/itdoginfo/podkop/blob/0.7.24/podkop/Makefile)
требует sing-box,curl,jq,kmod-nft-tproxy,coreutils-base64,bind-dig. Это только DIRECT
requirements, не полная transitive closure. Ещё нужны package solver и проверка
всех недостающих libs/kmods по installed DB, без unplanned upgrades. Распакованный
размер17MiB sing-box APK НЕ равен потреблению rootfs: требуется расчёт до установки.

Официальные feed не предоставили sha256sums по проверенным URLs (404);
не выдавать locally computed SHA за authenticated feed checksum. APK verify должен
использовать штатный trusted /etc/apk/keys и подписанные ADB indexes.
[Upstream install.sh](https://github.com/itdoginfo/podkop/blob/0.7.24/install.sh)
использует --allow-untrusted для собственного пакета. Это НЕ доказательство trusted
signature и НЕ разрешение отключить проверку здесь. До explicit verification
architecture/signature/closure — STOP installation. --allow-untrusted не выполнялся.

## Контролируемый STOP bulk serial

Для чтения metadata предпринята передача одного37KiB Podkop APK только в /tmp.
Увеличенные octal chunks перегрузили serial/ash line: timeout, continuation prompt.
До payload execution не дошло. По существующему wrapper через pipe (не local PTY)
передан Ctrl+C BYTE только гостевому shell. Подтверждены R12_RECOVERED_UID_0,
R12_APK_PAYLOAD_NOT_EXECUTED, исходные две LAB routes; podkop/sing-box по-прежнему отсутствуют.
Transport source возвращён к ранее проверенным40-byte chunks. Blind retry не делался.
Нет новых maintainer scripts/пакетов/служб. Bulk transport — отдельный незакрытый gate:
проверить flow control/chunking и SHA на маленьком synthetic binary, затем пакетах;
не подключать production NIC и не устанавливать пакеты ради удобства переноса.

## Минимальное расширение host capability — ТОЛЬКО VM203

Новый [codexops-r12-recovery](../scripts/lab/codexops-r12-recovery), отдельный от уже
установленного LAB wrapper; новый [owner bootstrap](../scripts/lab/install-r12-recovery.sh).
Не произвольный qm set/snapshot/clone/restore и не global LVM operations.
Точные sudo actions status/capture/accept/restore/arm/confirm203; expire только root timer.
201/202/204, caller-selected files/devices/commands запрещены. Existing wrapper НЕ меняется.

Почему cold copy: диск203124MiB на extra-storage:vm-203-disk-0, видимый PVE path
/dev/extra-storage/vm-203-disk-0→dm-22 (minor не pin: может меняться). Full offline
QCOW2 image не зависит от live LVM snapshot/linked clone/backing chain; не меняет
bridges/host routing/VM hardware. Новый storage/VMID не нужен.

- capture: isolation guard existing wrapper; размер≤512MiB, запас host space;
  owner перед этим выполняет guest sync. Fence203, проверить stopped/исчезновение
  прежнего QEMU PID/no mount/no fuser, qemu-img convert raw→QCOW2+check+hash/config/size;
  сохранить в root0700 /var/lib/r12-lab203-recovery; запустить только203.
- accept: explicit операторское подтверждение ПОСЛЕ serial и Stage6 HTTP/TLS/DNS
  smoke, не автоматическая отметка по running. До этого baseline UNVERIFIED.
- restore: сначала проверить hash/config/size и подготовить полный rescue.raw;
  затем fence только203, сохранить failed disk как forensic QCOW2, переписать ТОЛЬКО
  известный LV203, fsync, побайтно qemu-img compare, start203. После этого только
  RESTORED_UNVERIFIED: health/transit проверяется отдельно. Baseline не затирается.
- arm: только принятый baseline, фиксированный900s transient systemd deadline,
  локальные boot/monotonic markers; disconnect Codespace/нет WAN/DNS/Tailscale/
  guest SSH/procd/QGA не отменяют host job. Явный confirm до deadline отменяет timer.
- expire/restore: guest network/kernel для disk restore не нужны. Все операции
  flock, без повторных попыток. При timeout/неизвестном state STOP с сохранёнными
  baseline и forensic image; никогда не boot после частично неуспешной записи.

**Ограничения:** ни один recovery action не выполнен; это НЕ доказанный recovery.
Первый capture/readback/boot+probes и реальный restore нужны ДО package install.
Прямой guest sync требует пока здорового гостя ТОЛЬКО при capture, не при restore.
Current LAB start зависит от работающих Unix endpoints LAB204 (existing guard).
Не покрываются отказ самого PVE/storage/NIC/питания и потеря обоих LAB. Host reboot
теряет transient timer: это отдельный BLOCKER расширения на такой failure model;
не заявлять boot-persistent recovery. Время восстановления не измерено.
Ошибка forensic copy/disk write/boot оставляет диагностируемый STOP, не гарантированный
интернет. Повреждение PVE LV/mapping/config также STOP вместо попытки угадать устройство.

## Staging и единственный root bootstrap для согласования

Два файла уже подготовлены в /home/codexops/r12-recovery-access, каталог codexops0700,
файлы0600, SHA совпали. Ничего root-owned не установлено.
После отдельного GO владелец выполняет один block в root Shell (перед копированием
не запускать исходники из writable codexops каталога):

```bash
(
set -e
umask 077
d=$(mktemp -d /root/r12-recovery.XXXXXXXX)
install -o root -g root -m 0600 /home/codexops/r12-recovery-access/{codexops-r12-recovery,install-r12-recovery.sh} "$d/"
cd "$d"
printf '%s  %s\n' \
f6ce60fbfd94f9d9ee27d82beabdb0543379a93bfc4e72d3a04b7d5313da3ea0 codexops-r12-recovery \
a77bdab4057b0caa4392322d625716cc12eafaf4d63a4537d60d781964ee33ba install-r12-recovery.sh | sha256sum -c -
bash ./install-r12-recovery.sh install
printf 'ROLLBACK_ACCESS: bash %s/install-r12-recovery.sh rollback\n' "$d"
)
```

Install только новый wrapper/root state/exact sudoers; visudo до/после, hash/syntax
и absence paths; не выполняет VM/disk/timer actions. Ошибка установки снимает новый grant.
Root rollback bootstrap удаляет только неизменённые grant/wrapper, сохраняет образы;
при armed deployment отказывается отключать защиту. Original LAB wrapper не меняется.
Бинарные backups и test SSH/private keys никогда не публикуются в Git; только evidence.

## После разрешения — последовательные gates агента

1. status203 и обязательный denial202/204 (не вызывать capture как negative test).
2. guest sync203; capture203; serial и Stage6 full probes; accept baseline.
3. restore203 без участия guest agents, serial/full probes; root archive checksum.
4. arm и намеренный разрыв клиента, затем полный отказ203 только на принятой baseline;
   deadline должен вернуть filesystem/boot/transit. Сохранить реальные downtime и logs.
5. Только после recovery PASS: завершить APK signature/closure/transport verification,
   offline install, synthetic main/USA/VPN endpoint и сценарии Fail-Open/recovery.

Локально negative CLI/host-shell/VMID tests и hash/syntax PASS. Они НЕ подтверждают
LVM/fencing/systemd live поведение. На PVE пока выполнены только inspect203 и staging.
