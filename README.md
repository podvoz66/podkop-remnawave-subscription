# AdeptPro Bootstrap v2

Production-oriented OpenWrt bootstrap sources for Podkop, Remnawave subscription
sync, and direct Tailscale administration. This branch prepares a static mirror;
it does not deploy or change any production service by itself.

Russian documentation: [README.ru.md](README.ru.md).

## Flow

```text
Remnawave Wizard
  -> bootstrap.adeptpro.online
  -> Tailscale
  -> Podkop 0.7.22 from the AdeptPro mirror
  -> Russian Podkop UI
  -> Remnawave subscription
  -> daily deferred sync
  -> reboot
  -> postboot ttyd one-shot
```

The existing production wizard remains pinned to commit
`3cf06121c03815c1c50c620a55ef46cdafa5e949`. This repository change does not
switch existing users to Bootstrap v2.

## Supported OpenWrt platforms

| OpenWrt | Package manager | Package format | Approved package architecture |
|---|---|---|---|
| 24.10.x | `opkg` | `.ipk` | upstream `all` |
| 25.12.x and newer | `apk` | `.apk` | upstream `all` |

Bootstrap detects `DISTRIB_RELEASE`, `DISTRIB_ARCH`, and `DISTRIB_TARGET`, then
checks the package manager that is actually installed. A version/manager
contradiction, unknown manager, missing architecture, or absent manifest platform
stops before Podkop mutation. The router architecture is still detected even
though Podkop 0.7.22 declares these packages architecture-independent.

The approved release contains three real IPK assets and three real APK assets:
Podkop, LuCI, and Russian localization. The server-side sync validates this exact
asset set and never follows `latest` or converts one package format into another.
The official tag builds them with OpenWrt SDK images 24.10.6 (IPK) and 25.12.3
(APK).

## Why the router does not use GitHub

A clean router may not yet have working VPN access, while GitHub paths may be
unreachable. All router-side downloads therefore use:

```text
https://bootstrap.adeptpro.online/openwrt/v1
```

Only `scripts/sync-podkop-mirror.sh`, which runs on the future mirror server, may
contact GitHub. It pins Podkop 0.7.22, checks the exact release asset contract,
downloads both package formats into separate `opkg/all` and `apk/all` directories,
checks non-empty files, calculates SHA256, and builds the JSON manifest.

No third-party package binaries are committed to Git.

## Package validation and installation

Router order is strictly:

```text
download manifest
  -> validate schema/version/package manager/architecture
  -> download all three packages
  -> validate size and SHA256 for every package
  -> install Podkop
  -> install LuCI
  -> install luci-i18n-podkop-ru
```

Any mismatch exits non-zero before a package is installed or Podkop configuration
is changed. Podkop installation has no installer prompts and automatically installs
the Russian UI.

## Daily Remnawave sync

The managed cron entry is:

```cron
50 3 * * * /usr/bin/update-podkop-from-remnawave.sh >/tmp/podkop-sub-update.log 2>&1
```

The wrapper guard retains cached subnet-list precheck/apply behavior and delegates
subscription transformation to the real updater. The updater preserves manual
links and unrelated Podkop sections, rejects placeholders, builds an isolated UCI
candidate, and compares current and candidate state semantically.

When unchanged, it performs no UCI commit. When changed, it backs up the Podkop
configuration, commits the candidate, and writes:

```text
/etc/podkop-remnawave/pending-runtime-reload
```

Daily sync never stops or restarts Podkop, never restarts or kills sing-box, and
does not interrupt active sessions. New VPN keys become active at the next normal
Podkop/sing-box start or router reboot.

Bootstrap always enforces `podkop.settings.dont_touch_dhcp=1` only when the value
differs, so direct internet remains available while Podkop is stopped.

## Tailscale and postboot ttyd

Tailscale is installed from the active OpenWrt repository, enabled, and brought
up with `--accept-dns=false`, `--ssh=false`, and the normalized router hostname.
The one-off auth key is not printed. Direct SSH and LuCI firewall rules apply only
to the Tailscale range; no WAN port is opened.

Installing or updating ttyd can terminate a LuCI Terminal session. The critical
bootstrap only installs and enables `/etc/init.d/adeptpro-postboot`. After reboot,
the late one-shot waits for network and performs bounded repository retries for
`ttyd` and `luci-app-ttyd` using the detected package manager. Success disables
the one-shot. Failure never reboots or changes the main router configuration and
leaves the service enabled for the next boot.

## Static mirror deployment example

Prepared files are under `deploy/bootstrap.adeptpro.online/`. The recommended
root is `/srv/bootstrap.adeptpro.online` with immutable releases and an atomic
`current` symlink. The example does not touch live Nginx.

After a future deployment, validate read-only:

```sh
curl -fsS https://bootstrap.adeptpro.online/health.txt
curl -fsS https://bootstrap.adeptpro.online/openwrt/v1/manifest.json
```

Expected health response is `OK`. Do not update the production Remnawave wizard
until the mirror is deployed and these checks pass.

## Tests

Run:

```sh
sh tests/test-bootstrap-static.sh
```

The suite checks router GitHub dependency count, daily cron, deferred runtime,
IPK/APK paths, fail-closed platform selection, SHA256 validation, non-interactive
Russian Podkop installation, postboot ttyd, secret masking, shell syntax, and
shellcheck when available.

Never commit real subscription URLs or tokens, Tailscale keys/OAuth secrets,
UUIDs, private keys, or VPN links.
