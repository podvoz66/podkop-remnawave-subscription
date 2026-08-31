# AdeptPro Bootstrap v2 work log

## 2026-09-01 read-only audit and approved implementation

- Scope: GitHub repository only. Production Remnawave, DNS, Nginx Proxy Manager,
  `bootstrap.adeptpro.online`, server `188.226.97.49`, and real routers are out of scope.
- Base commit: `3cf06121c03815c1c50c620a55ef46cdafa5e949`.
- Branch: `feat/adeptpro-bootstrap-mirror-v2`.
- Backup: `C:\Users\Podvoz\Documents\New project\backups\adeptpro-bootstrap-v2-20260901-003631`.
- The separate dirty checkout `podkop-remnawave-subscription` was not modified.
- Audit found 12 GitHub dependency lines in the production-pinned router scripts,
  a four-hour updater cron, Podkop/sing-box restart on changed configuration,
  interactive Podkop installer automation, and ttyd installation in the critical path.
- Existing safeguards retained as design requirements: guard wrapper delegates to the
  real updater, manual links are preserved, subscription URLs and Tailscale keys are
  masked, and `podkop.settings.dont_touch_dhcp=1` is committed only when different.
- GitHub API verification confirmed Podkop release `0.7.22` has exactly six package
  assets: three APK and three IPK files for Podkop, LuCI, and Russian localization.
- User approved implementation, commit, push, and PR creation.
- Follow-up requirement added mandatory OpenWrt 24.10 opkg/IPK and OpenWrt
  25.12+ apk/APK support with fail-closed package-manager and architecture checks.
- Official release files were downloaded to a temporary audit directory. All three
  IPK packages report `Architecture: all`. The official 0.7.22 Makefiles declare
  `PKGARCH:=all` and `LUCI_PKGARCH:=all`; the release workflow builds IPK and APK
  independently. The approved mirror layout therefore uses `opkg/all` and `apk/all`.
- Official tag Dockerfiles build IPK with `itdoginfo/openwrt-sdk-ipk:24.10.6`
  and APK with `itdoginfo/openwrt-sdk-apk:25.12.3`, confirming both production
  OpenWrt package classes for the same pinned 0.7.22 release.

## 2026-09-01 validation

- `tests/test-bootstrap-static.sh`: PASS, `STATIC_TEST_FAILURES=0`.
- Router GitHub dependency count: 0.
- Daily cron and no four-hour cron: PASS.
- Periodic Podkop restart, sing-box restart, and sing-box kill counts: 0.
- OpenWrt 24.10/opkg/IPK and OpenWrt 25.12+/apk/APK static scenarios: PASS.
- IPK/APK SHA256, architecture fail-closed, Russian non-interactive Podkop,
  postboot ttyd, `dont_touch_dhcp`, manual-link preservation, and masking: PASS.
- `sh -n`/`bash -n` selected from each file shebang: PASS for all shell files.
- `git diff --check`: PASS.
- `shellcheck`: not installed; skipped without failing the suite as required.

## 2026-09-01 PR review blocker remediation

- Scope remained repository-only; PR #2 was not merged and production was not accessed.
- Review backup: `C:\Users\Podvoz\Documents\New project\backups\adeptpro-bootstrap-v2-review-20260901-012742`.
- Replaced both legacy installers with AdeptPro Bootstrap v2 compatibility launchers.
  The existing-Podkop launcher preserves the installation and disables hostname change
  and reboot by default while allowing explicit environment overrides.
- Removed the router-side GitHub dependency and Podkop/sing-box stop/kill behavior from
  the legacy Tailscale entrypoint.
- Added a boot-time deferred runtime marker handler. It performs a bounded wait,
  requires sing-box plus `podkop global_check`, verifies the current UCI SHA256, and
  atomically moves the marker only after success. It never restarts or kills runtime.
- Static discovery now scans every router-side `.sh`/`.init` automatically. The only
  server-side GitHub allowlist is the mirror sync script and deployment scripts.
- Static suite: PASS (`STATIC_TEST_FAILURES=0`, 12 router scripts discovered).
- Runtime marker success and marker-preservation failure tests: PASS.
- Router GitHub dependencies, four-hour cron, periodic Podkop restart, periodic
  sing-box restart/kill, and ttyd critical-path counts: 0.
- Added-content secret pattern scan: 0 findings. `git diff --check`: PASS.
- `sh -n`/`bash -n`: PASS via Git Bash. `shellcheck`: unavailable locally.
