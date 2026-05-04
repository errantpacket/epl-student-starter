# files/ — Firmware Overlay Root

Contents of this directory are merged into the firmware filesystem at build
time (passed to ImageBuilder via `FILES=files/`). Mirror real paths here:

```
files/etc/banner            → /etc/banner on the device
files/etc/uci-defaults/...  → runs once on first boot, then deletes itself
files/etc/dropbear/authorized_keys
files/root/.ssh/...
```

The lab guide walks through populating this directory.
