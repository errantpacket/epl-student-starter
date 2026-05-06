# Lab 12 — Drop Device Deployment (Mango)

**Duration: 45 minutes**
**Day:** 2, Session 4

The Mango has been with you since Lab 01. Today it graduates from "practice target" to
"deployed drop device." By the end of this lab, flashing the sealed image to a fresh Mango,
plugging it into any USB power source with an Ethernet uplink, and walking away is all that
is required. The device enrolls itself, joins your tailnet, and appears in D1 — with no
post-boot operator interaction required.

That is the moment this course has been building toward.

---

## Learning objectives

- Understand baked-secret image building: secrets live in the firmware, not on the wire.
- Substitute the `99-enroll.sh.template` placeholders at build time using `bake-secrets.sh`.
- Rebuild the sealed Mango image with `build-drop-mango.sh` and verify the output SHA.
- Flash and observe self-enrollment via `/v1/devices` and D1 audit_log.
- Confirm that a second power cycle does NOT re-enroll (the script self-deletes after success).

---

## Pre-state

Confirm these labs are complete and their artifacts are in place:

```sh
# Lab 02 — base Mango image was produced
ls courses/engagement-platform-labs/labs/output/build-manifest.json

# Lab 05 — tailnet is up; magicDNS works
# (Your Tailscale account is logged in and you can generate auth keys)
tailscale status 2>/dev/null | grep -E 'drop-|ep-' || echo "tailnet may be partial — ok to proceed"

# Lab 08 — CF Access service token produced
ls courses/engagement-platform-labs/labs/lab08-cloudflare-access/output/access-tokens.json

# Lab 09 — Worker D1 enrollment endpoint is live (not stub 501)
curl -sf https://api.${DOMAIN}/v1/health | grep '"ok":true' && echo "worker ok"

# DOMAIN is exported
echo "DOMAIN=${DOMAIN}"   # e.g. a00f3f13.eplabs.cloud

# STUDENT slot name is exported (matches Lab 05 tailnet hostname prefix)
echo "STUDENT=${STUDENT}"  # e.g. alpha — Mango will join as drop-alpha
```

If `STUDENT` is not set, derive it from your domain or ask the instructor. It must be the
same slot token used in Lab 05 (`tailscale up --hostname=drop-${STUDENT}`).

---

## Walkthrough

### 1. Understand what is being baked

Open `labs/shared/files-mango/etc/uci-defaults/99-enroll.sh.template` and read the top
block. The four `{{PLACEHOLDER}}` variables are substituted at build time:

| Placeholder | Source |
|---|---|
| `{{WORKER_URL}}` | `wrangler.toml` (your deployed Worker) |
| `{{TAILSCALE_KEY}}` | Tailscale admin — generate now |
| `{{SERVICE_TOKEN_ID}}` | `lab08-cloudflare-access/output/access-tokens.json` |
| `{{SERVICE_TOKEN_SECRET}}` | same file |
| `{{SLOT}}` | `drop-${STUDENT}` |

After the script runs successfully on first boot, it calls `rm -f "$SELF"` and exits. The
next boot finds no `/etc/uci-defaults/99-enroll.sh` to run; OpenWrt's uci-defaults
mechanism is satisfied. Tailscale retains its state on the ExtRoot USB overlay. The device
simply reconnects to the tailnet on subsequent boots without re-enrolling.

### 2. Generate a Tailscale ephemeral auth key

In the Tailscale admin console (`login.tailscale.com/admin/settings/keys`):

- Key type: **Reusable: off** (single-use is safer for a drop scenario)
- Expiry: 1 hour is sufficient for the workshop; use a longer TTL in production
- Tags: add `tag:device` (the ACL from Lab 05 requires this)

Copy the key. You will pass it to `bake-secrets.sh` via the environment.

```sh
export TAILSCALE_KEY="tskey-auth-kXXXXXXXXXXXXXX-XXXXXXXXXXXXXXXXXXXXXXXX"
```

### 3. Run bake-secrets.sh

`bake-secrets.sh` reads the three secret sources, substitutes them into the enrollment
template, writes the substituted file into a temporary overlay directory, then re-invokes
the Lab 02 imagebuilder script to produce the sealed image.

```sh
cd courses/engagement-platform-labs/labs/lab12-drop-device
chmod +x bake-secrets.sh
./bake-secrets.sh
```

The script will:

1. Read `lab08-cloudflare-access/output/access-tokens.json` for the service token pair.
2. Read `TAILSCALE_KEY` from the environment (or prompt if unset).
3. Read `WORKER_URL` from `lab07-first-worker/worker/wrangler.toml` (or `WORKER_URL` env var).
4. Substitute all five placeholders into the template.
5. Write the substituted script to a temporary overlay under `/tmp/bake-$$`.
6. Call `build-drop-mango.sh` with `FILES_DIR` pointing at the temp overlay.
7. Move the resulting `.bin` to `labs/output/drop-mango-sealed-${STUDENT}.bin`.

Expected output (last few lines):

```
>>> secrets injected into overlay
>>> running imagebuilder (this takes 2-4 minutes)
>>> built: bin/targets/ramips/mt76x8/openwrt-...-glinet_gl-mt300n-v2-squashfs-sysupgrade.bin
    size: NNNNNNN bytes
    sha256: <hex>
>>> sealed image: /path/to/labs/output/drop-mango-sealed-alpha.bin
```

### 4. Verify the sealed image

```sh
ls -lh courses/engagement-platform-labs/labs/output/drop-mango-sealed-${STUDENT}.bin
# Should be 7-10 MB, not 0 bytes

# Confirm the enrollment script is present and substituted inside the squashfs.
# This requires squashfs-tools in the devcontainer.
unsquashfs -ll courses/engagement-platform-labs/labs/output/drop-mango-sealed-${STUDENT}.bin 2>/dev/null \
  | grep 99-enroll || echo "note: unsquashfs not available; verify on device after flash"
```

The instructor can also run `sha256sum` and compare against the reference hash in the
build manifest:

```sh
sha256sum courses/engagement-platform-labs/labs/output/drop-mango-sealed-${STUDENT}.bin
cat courses/engagement-platform-labs/labs/output/build-manifest.json | grep image_sha256
```

### 5. Flash the Mango

Use the LuCI web interface or `sysupgrade` from the Mango shell:

**Option A — LuCI (recommended for first flash):**

1. Connect your laptop to the Mango's LAN port.
2. Navigate to `http://192.168.1.1`.
3. System > Backup/Flash Firmware > Flash new firmware image.
4. Upload `drop-mango-sealed-${STUDENT}.bin`.
5. Uncheck "Keep settings" — the sealed image must start clean.
6. Click "Proceed". Wait for the LED to stop blinking (approximately 90 seconds).

**Option B — sysupgrade from Mango shell:**

```sh
# Copy the image to the Mango first (ensure it's still running original firmware)
scp courses/engagement-platform-labs/labs/output/drop-mango-sealed-${STUDENT}.bin \
    root@192.168.1.1:/tmp/sealed.bin

# Flash (this disconnects your SSH session immediately)
ssh root@192.168.1.1 'sysupgrade -n /tmp/sealed.bin'
```

The `-n` flag discards any existing overlay configuration, which is correct here — you want
the sealed secrets and no prior overlay contamination.

### 6. Plug in USB and power; observe enrollment

After the Mango reboots on the new firmware:

1. Plug your formatted USB drive into the Mango's USB-A port (ExtRoot overlay for Lab 03).
2. Connect Ethernet from the Mango WAN port to your lab network (not your laptop).
3. Watch the D1 devices table via the Worker:

```sh
# Poll until the drop device appears (timeout ~120s)
for i in $(seq 1 24); do
    result=$(curl -sf \
        -H "CF-Access-Client-Id: ${SERVICE_TOKEN_ID}" \
        -H "CF-Access-Client-Secret: ${SERVICE_TOKEN_SECRET}" \
        "https://api.${DOMAIN}/v1/devices" 2>/dev/null)
    if printf '%s' "$result" | grep -q "drop-${STUDENT}"; then
        printf '\nenrolled: %s\n' "$result"
        break
    fi
    printf '.'
    sleep 5
done
```

Expected: a JSON array containing a device row with `"tailscale_hostname":"drop-${STUDENT}.*"`.

You can also tail the enrollment log directly from the Mango once it has enrolled and
you can SSH in via tailscale:

```sh
tailscale ssh root@drop-${STUDENT} 'cat /tmp/enrollment.log'
```

### 7. Confirm power-cycle behavior

Power-cycle the Mango (unplug, wait 5 seconds, replug). After it comes back up, check:

```sh
tailscale ssh root@drop-${STUDENT} 'ls /etc/uci-defaults/'
# Expected: empty or no 99-enroll.sh listed
```

The enrollment script deleted itself on first run. The second boot reuses the Tailscale
state on the ExtRoot overlay. No new enrollment row should appear in D1 (the device_id is
already registered).

```sh
curl -sf \
    -H "CF-Access-Client-Id: ${SERVICE_TOKEN_ID}" \
    -H "CF-Access-Client-Secret: ${SERVICE_TOKEN_SECRET}" \
    "https://api.${DOMAIN}/v1/devices" | grep "drop-${STUDENT}"
# Expected: still exactly one row with the original enrolled_at timestamp
```

---

## Post-state

When this lab is complete:

- [ ] `labs/output/drop-mango-sealed-${STUDENT}.bin` exists with a recorded SHA256.
- [ ] Mango is flashed with the sealed image and reboots successfully.
- [ ] `/v1/devices` returns a row with `tailscale_hostname` matching `drop-${STUDENT}`.
- [ ] `enrolled_at` timestamp is within the last 5 minutes (validate.sh checks this).
- [ ] `tailscale ssh root@drop-${STUDENT}` works from the devcontainer.
- [ ] `/etc/uci-defaults/99-enroll.sh` is absent from the Mango (self-deleted).
- [ ] Power-cycling the Mango does not create a duplicate enrollment row.

---

## Validation

```sh
export DOMAIN="<your-domain>"
export STUDENT="<your-slot>"  # e.g. alpha
export SERVICE_TOKEN_ID="<from lab08 output>"
export SERVICE_TOKEN_SECRET="<from lab08 output>"
chmod +x courses/engagement-platform-labs/labs/lab12-drop-device/validate.sh
courses/engagement-platform-labs/labs/lab12-drop-device/validate.sh
```

The script exits 0 on success and prints the failing assertion otherwise.

---

## Troubleshooting

<details>
<summary>bake-secrets.sh: "access-tokens.json not found"</summary>

Lab 08 must be complete. The file is produced when you run Lab 08's step to create a CF
Access service token. If you skipped that step, re-run Lab 08's service token creation and
verify `lab08-cloudflare-access/output/access-tokens.json` exists with `service_token_id`
and `service_token_secret` fields.

</details>

<details>
<summary>bake-secrets.sh: "TAILSCALE_KEY not set"</summary>

The script prompts if the variable is unset. Generate a new auth key in the Tailscale
admin console as described in Step 2, then either export it or paste it at the prompt.

</details>

<details>
<summary>Imagebuilder fails: "profile not found"</summary>

Run `docker compose run --rm imagebuilder make info | grep glinet` to confirm the
`glinet_gl-mt300n-v2` profile is available in your ImageBuilder container. If the container
image is stale, re-pull: `docker compose pull imagebuilder`.

</details>

<details>
<summary>Mango flashed but enrollment.log is empty or missing</summary>

SSH to the Mango directly on the LAN (192.168.1.1) within the first 2 minutes of boot,
before the script finishes. Check if 99-enroll.sh is still present:

```sh
ssh root@192.168.1.1 'ls -la /etc/uci-defaults/'
```

If it is present but not yet run, uci-defaults runs during `procd` initialization. Check
`logread` for errors:

```sh
ssh root@192.168.1.1 'logread | grep -i enroll'
```

Common causes: USB ExtRoot not mounted (tailscale binary not present), no upstream network
on WAN port.

</details>

<details>
<summary>Tailscale up fails on Mango: "tailscale: command not found"</summary>

The sealed image does not include tailscale in NOR flash — it installs on the ExtRoot USB in
Lab 03. If the USB is not plugged in or the ExtRoot overlay is not mounted, tailscale is not
available. Verify:

```sh
ssh root@192.168.1.1 'df -h | grep /overlay'
# Should show the USB device mounted at /overlay
```

If the USB is missing, plug it in, run `block-mount-extroot`, and reboot.

</details>

<details>
<summary>D1 shows enrollment but tailscale SSH fails</summary>

The enrollment script posts to D1 before Tailscale finishes settling. Wait 30 seconds after
enrollment appears in D1, then retry `tailscale ssh root@drop-${STUDENT}`. If it still fails,
check that the device appears in `tailscale status` on your devcontainer:

```sh
tailscale status | grep drop-${STUDENT}
```

If absent, the ephemeral auth key may have expired. Regenerate a key, re-run `bake-secrets.sh`,
and reflash.

</details>

---

## Take-home extension

See `labs/take-home/lab12-mt3000-drop/README.md` for the MT3000 / WiFi-6 active drop
variant of this lab.
