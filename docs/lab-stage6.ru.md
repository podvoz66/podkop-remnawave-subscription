# R12 Stage6 — live HTTP/HTTPS/DNS transit и независимый rollback PASS

**Draft PR7 / PRODUCTION NO-GO.** Только LAB203/204 через существующий SSH wrapper.
Сеть/VM/ключи production не изменялись, пакеты и образы не скачивались/не устанавливались.

## Путь и изменения

r12-lan ens2 10.253.202.2 → LAB203 br-lan 10.253.202.1 → eth1 10.253.203.2
→ r12-wan ens4 10.253.203.1. Изолированные LAN/WAN Unix stream backends Stage5 сохранены.
В LAB203 обнаружены stock lan→wan forwarding, WAN masquerade=1 и ip_forward=1;
изменения network/firewall/DNS/PBR НЕ понадобились.
В LAB204 добавлен ровно host-route:

```sh
ip -n r12-lan route add 10.253.203.1/32 via 10.253.202.1 dev ens2 proto static
```

Никакого default route. Root netns Debian содержит только lo. Fixture запущен
в r12-wan, слушает ТОЛЬКО10.253.203.1:8080 HTTP,8443 HTTPS,53 DNS UDP+TCP.
Python использует stdlib, не делает upstream DNS/HTTP запросов. .r12.test отвечает
только A=10.253.203.1 TTL0; это synthetic DNS fixture, не recursive resolver.

## Baseline и независимость отката

До изменений на каждой LAB создан root-only /root/r12-stage6.
203: локальные копии network/firewall/dhcp + SHA256, nft -s ruleset, routes/ip rules.
204: boot identity, namespace inode, routes root/LAN/WAN, addr/IP6/rules, namespaces,
исходники fixture/controller, SHA assets; автономный control.sh без Stage5 dependencies.
Nft utility в204 отсутствует: kernel nft rules204 независимо не выгружались;
Debian firewall не менялся. Router firewall baseline203 выгружен и сравнен.
На LAN204 уже существовал LAB ULA route от stock RA203 (fd52:…/64), без default;
его не изменяли. Сценарий IPv4, IPv6 transit не сертифицирован.

204 rollback проверяет MAC/inode/boot/assets и чужие route changes; завершает только
собственный fixture PID после проверки cmdline и namespace, удаляет только свой
host-route, сравнивает исходные маршруты и отсутствие listeners. Namespaces не удаляет,
Stage5 адреса не трогает, конфигурации203 не переписывает. Ключ сертификата synthetic,
локален в204, не выводится/не коммитится. Rollback сохраняет файлы/журнал для анализа.

```sh
# Только внутри LAB204:
bash /root/r12-stage6/control.sh rollback
# Возврат рабочего Stage6:
bash /root/r12-stage6/control.sh apply
bash /root/r12-stage6/control.sh verify
sh /root/r12-stage6/probe.sh
```

При reboot marker меняет boot identity → STOP. Это лабораторный rollback Stage6,
НЕ автономное восстановление production VM и НЕ доказательство host disk recovery.

## Реальные проверки

| Проверка | Подтверждение |
|---|---|
| HTTP | 200, body=R12 + уникальный request token |
| HTTPS | 200, ssl_verify_result=0, --cacert synthetic certificate + SAN fixture.r12.test; без -k |
| Negative TLS | другой hostname при том же CA отклонён curl RC60 |
| DNS UDP | transaction/question/flags/answer проверены полностью, A=10.253.203.1 |
| DNS TCP | length framing, transaction/question/answer проверены полностью |
| WAN receipt | каждый token в requests.jsonl; peer10.253.203.2, подтверждает NAT на LAB203 |
| No bypass | при работающем fixture удалён единственный host-route: HTTP недоступен, token не появился на WAN; route возвращён |
| No external route | root/LAN/WAN без IPv4/6 default; route get1.1.1.1 LAN/WAN failed без отправки пакетов; root толькоlo |
| Fixture outage | остановлен только свой Python; HTTP RC7, DNS UDP/TCP nonzero; LAB203 LAN gateway продолжал отвечать |
| Fixture recovery | HTTP/TLS/DNS снова PASS, новые token/записи WAN |
| Full Stage6 rollback | сервис остановлен, host-route удалён, LAN/WAN routes совпали с baseline, target недоступен |
| Restore after rollback | apply + полный HTTP/TLS/DNS probe PASS, STAGE6_FINAL_WORKING_RESTORED |
| Router unchanged | network/firewall/dhcp cmp PASS; nft -s ruleset/routes/ip rules cmp PASS; нет IPv4/6 default |

Внешние адреса не опрашивались; гарантия ограничена изолированной схемой и проверенными
маршрутами/кодом, не является захватом всего host traffic. Production internet не тестировался.
[Синтетические WAN записи и итоговая изоляция](evidence/r12-stage6-wan-requests.txt).
[Router baseline сравнение](evidence/r12-stage6-router-baseline.txt).
Последний полный token: r12s6-1795444351-1930 (HTTP/HTTPS/UDP/TCP), fixture PID1920
на момент проверки. Не использовать PID из документа для kill: controller проверяет live marker.

## Воспроизводимые исходники

- [Fixture](../scripts/lab/r12-stage6-fixture.py), [controller/rollback](../scripts/lab/r12-stage6-control.sh).
- [Probe](../scripts/lab/r12-stage6-probe.sh), [negative/failure/rollback сценарии](../scripts/lab/r12-stage6-scenarios.sh).
- [Router comparison](../scripts/lab/r12-stage6-verify203.sh).
- [Serial transport](../scripts/lab/r12-serial-run.mjs): только sudo wrapper203/204,
  root identity nonce, SHA256 до исполнения, bounded transfer; no direct host socket.
  Debian base64/gzip; stock203 без base64 — octal printf/gzip. Секреты не передавать.
- [Prepare template](../scripts/lab/r12-stage6-prepare.sh.in) и [bundle generator](../scripts/lab/r12-stage6-bundle.mjs).
  Generator только печатает shell payload. Prepare запрещает существующий /root/r12-stage6,
  не использовать повторно на уже принятом стенде. Перед применением сохранить router
  baseline как описано выше. Fixture/probe/controller передаются offline через serial.

Пример сборки payload для ЧИСТОГО нового Stage6, не запускать повторно здесь:

```sh
node scripts/lab/r12-stage6-bundle.mjs > /tmp/r12-stage6-prepare.sh
node scripts/lab/r12-serial-run.mjs 204 /tmp/r12-stage6-prepare.sh
```

Сценарий требует probe.sh предварительно переданным в /root/r12-stage6; локальные
пути fixture/controller не предполагают internet/package installation.

## Обнаруженные дефекты и regression

Первый запуск fixture до открытия ports завершился UnboundLocalError: локальная
переменная http перекрывала module import. Диагностика прочитала только fixture.out;
исправлено http_service. Первый rollback STOP выявил trailing space ip route;
строка подтверждена sed -n l, сравнение нормализовано без изменения baseline.
Исходные нерабочие файлы и manifest сохранены в204 *.initial. После исправлений
rollback PASS, затем все live сценарии выше PASS. Не выдавать ранние ошибки за успех.

Serial203 initially lacked base64: checksum transport не дошёл до исполнения payload;
baseline затем проверен напрямую и через исправленный octal transport. Сеть не менялась.
Локально:4 DNS codec regression tests +1 real loopback startup/HTTP/TLS/UDP/TCP test PASS.
Bash/JS syntax и diff checks PASS. Эти unit/integration проверки дополняют live LAB,
не заменяют её. Следующий этап — [Stage7 план](lab-stage7-plan.ru.md).
