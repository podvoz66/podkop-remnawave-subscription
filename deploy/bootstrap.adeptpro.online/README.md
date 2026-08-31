# bootstrap.adeptpro.online static deployment

This directory is an example deployment bundle only. Nothing here changes the
live server automatically.

The recommended server root is `/srv/bootstrap.adeptpro.online`:

```text
/srv/bootstrap.adeptpro.online/
  releases/<release-id>/
    health.txt
    openwrt/v1/
  current -> releases/<release-id>
```

Run `scripts/publish-mirror.sh` on the future mirror server from a trusted clone.
It validates the pinned upstream Podkop 0.7.22 asset set, downloads all assets,
computes SHA256 values, stages router scripts, and only then atomically changes
the `current` symlink.

No `.ipk` or `.apk` files are stored in Git.
