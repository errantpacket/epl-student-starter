# shared/files-mango/ — Mango drop-firmware overlay root

Contents of this directory are passed to ImageBuilder via `FILES=`. Paths
mirror the on-device filesystem: `etc/uci-defaults/99-enroll.sh.template`
here lands at `/etc/uci-defaults/99-enroll.sh.template` on the Mango.

## What goes here

- `etc/uci-defaults/99-enroll.sh.template` — first-boot enrollment hook.
  Runs once on first boot (OpenWrt convention: every executable in
  `/etc/uci-defaults/` is run, then deleted). Workshop secrets
  (`{{WORKER_URL}}`, `{{TAILSCALE_KEY}}`, `{{SERVICE_TOKEN_ID}}`,
  `{{SERVICE_TOKEN_SECRET}}`) get substituted at build time by the Lab 12
  `bake-secrets.sh` step.

- `etc/banner` — what `ssh root@<mango>` shows on login. Workshop
  branding + slot identifier.

- `etc/dropbear/authorized_keys` — instructor break-glass SSH pubkey.
  Populate from `instructor/instructor.pub` before building. Empty file
  is acceptable; SSH will then require password (workshop-only).

## What does NOT go here

- Tailscale, cloudflared, python3, or anything that doesn't fit on the
  16MB NOR. Those are installed post-flash via `opkg` onto the
  ExtRoot-mounted USB (Lab 03).

- Anything device-specific to the MT3000 / Beryl AX. That belongs in
  `take-home/lab12-mt3000-drop/files/`.
