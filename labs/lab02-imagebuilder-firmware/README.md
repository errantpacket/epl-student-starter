# Lab 02 — Engagement Platform Build

**Duration: 75 minutes**

Every package in an OpenWrt image is a deliberate choice. On a 16 MB NOR flash chip,
the wrong choice means the firmware doesn't fit. On an unconstrained container, it means
missing a tool at the worst possible moment. This lab makes that tradeoff concrete by
producing two artifacts from the same OpenWrt 23.05.3 ImageBuilder baseline:

- **Contract A — engagement-platform:** a VS Code devcontainer image carrying the full
  engagement-stack (Tailscale, cloudflared, Python, wrangler, tcpdump, nmap, etc.).
  Flash is not a constraint here; the image is your primary operator tool for Labs 05–14.
- **Contract B — drop-mango:** a sysupgrade `.bin` for the GL.iNet Mango (GL-MT300N-V2)
  that must fit in 16 MB NOR flash. Heavy packages are deliberately absent and installed
  post-flash via opkg onto an ExtRoot USB drive in Lab 03.

Both targets pin OpenWrt **23.05.3 / ramips / mt76x8** so any student building on any
host on the same day can compare SHA256 checksums against a known-good reference build.

---

## Learning objectives

- Understand the ImageBuilder model: pre-compiled packages assembled into a firmware
  image without a full source build.
- Build two firmware contracts from one baseline and explain why their package lists
  diverge.
- Read and interpret `build-manifest.json` as a reproducibility artifact.
- Verify a squashfs size constraint programmatically — and understand what to cut when
  the constraint fails.

---

## Pre-state

Before starting this lab confirm:

```sh
# Lab 01 is complete — SSH to Mango works
ssh -o ConnectTimeout=5 root@192.168.8.1 'echo ok'

# Docker is running
docker info | grep -E '^Server Version'

# Pull the ImageBuilder image (course Dockerfile extends it; this warms the cache)
docker pull openwrt/imagebuilder:ramips-mt76x8-23.05.3

# Clone/checkout confirms the canonical bundle files are present
ls courses/engagement-platform-labs/.devcontainer/Dockerfile
ls courses/engagement-platform-labs/labs/Makefile
ls courses/engagement-platform-labs/labs/lab02-imagebuilder-firmware/build-engagement-platform.sh
ls courses/engagement-platform-labs/labs/lab02-imagebuilder-firmware/build-drop-mango.sh
ls courses/engagement-platform-labs/labs/shared/files-mango/etc/banner
ls courses/engagement-platform-labs/labs/shared/build-manifest.schema.json
```

All of these files are checked into the repo. If any are missing, `git status` will show
them as untracked or deleted — restore with `git checkout HEAD -- <path>`.

---

## Walkthrough

### 1. Inspect the build contracts

Spend five minutes reading the four key files. The rest of the lab will make more sense
with this context.

```sh
# All commands run from the course root:
# cd courses/engagement-platform-labs

# Contract A: devcontainer Dockerfile
#   Adds engagement-stack on top of openwrt/rootfs:x86-64-23.05.3
#   No flash constraint; heavy packages all present.
cat .devcontainer/Dockerfile

# Contract B: Mango drop firmware build script
#   Must fit in 16MB NOR. Minimal package list.
#   Heavy packages (tailscale, python3, cloudflared) are ABSENT — installed post-flash in Lab 03.
cat labs/lab02-imagebuilder-firmware/build-drop-mango.sh

# The PACKAGES variable in build-drop-mango.sh is the engineering document.
# Read it alongside Contract A to understand what was cut and why.

# Shared overlay baked into the Mango image
cat labs/shared/files-mango/etc/banner
cat labs/shared/files-mango/etc/uci-defaults/99-enroll.sh.template
# Note: the template placeholders ({{WORKER_URL}} etc.) are NOT substituted here.
# Lab 12 substitutes real secrets and rebuilds.

# Makefile: the two build targets and their per-lab validator hooks
cat labs/Makefile
```

**Discussion checkpoint (instructor-led, ~5 minutes):**

Compare the PACKAGES lists between Contract A (`.devcontainer/Dockerfile`, the `opkg
install` lines) and Contract B (`build-drop-mango.sh`, the `PACKAGES=` variable).
Ask: which packages appear in Contract A but not B? Why? The answer is the engineering
constraint: `tailscale`, `python3`, `cloudflared`, `wrangler`, `nmap`, `nginx` — all
multi-megabyte — simply don't fit in 16 MB alongside a kernel and bootloader. The Mango
carries only what it needs to survive independently and self-enroll; everything else lives
on the ExtRoot USB (Lab 03) or in the devcontainer.

---

### 2. Build Contract A — engagement-platform devcontainer

The build script wraps `docker build` and writes a `build-manifest.json` to
`labs/output/`.

```sh
cd courses/engagement-platform-labs/labs

# Via the Makefile (recommended)
make engagement-platform

# Or invoke the script directly from the repo root
bash lab02-imagebuilder-firmware/build-engagement-platform.sh
```

Expected output (abbreviated):

```
>>> engagement-platform build
    OPENWRT_VERSION=23.05.3
    IMAGE_TAG=epl-engagement-platform:23.05.3
    DEVCONTAINER=.../engagement-platform-labs/.devcontainer
[+] Building ...
 => FROM openwrt/rootfs:x86-64-23.05.3
 => opkg update && opkg install ca-bundle ca-certificates curl ...
 => opkg install tailscale luci nginx-ssl ...
 => cloudflared binary download
 => npm install -g wrangler@4
...
>>> built: epl-engagement-platform:23.05.3
    digest: sha256:<...>
    docker image size: <N> bytes
    rootfs tar: labs/output/engagement-platform-rootfs.tar (<N> bytes, sha256=<...>)
>>> next: open this folder in VS Code and 'Reopen in Container'
```

The build writes `labs/output/build-manifest.json`. Examine it:

```sh
cat labs/output/build-manifest.json
```

Expected structure (values will differ):

```json
{
  "role": "engagement-platform",
  "openwrt_version": "23.05.3",
  "openwrt_target": "x86_64",
  "imagebuilder_image": "sha256:...",
  "image_sha256": "...",
  "image_size_bytes": 123456789,
  "created_at": "2026-05-03T...",
  "builder_host": "yourlaptop"
}
```

**First-run note:** the `opkg install tailscale` layer can take 3–5 minutes to download
on a slow connection; subsequent rebuilds use Docker's layer cache and are much faster.
The `cloudflared` binary download adds another 30–60 seconds on first run.

---

### 3. Open the devcontainer in VS Code

Now that the image is built, reopen the project inside the container:

1. In VS Code, open the Command Palette (`Ctrl+Shift+P` / `Cmd+Shift+P`).
2. Select **"Dev Containers: Reopen in Container"**.
3. VS Code builds (or uses the cached image) and attaches. Open a new terminal.

Confirm you are inside OpenWrt:

```sh
cat /etc/openwrt_release
# DISTRIB_ID="OpenWrt"
# DISTRIB_RELEASE="23.05.3"
# DISTRIB_TARGET="x86_64"

# Confirm the engagement-stack tools are present
for bin in tailscale cloudflared python3 wrangler git curl jq tcpdump nmap; do
    command -v "$bin" && echo "ok: $bin"
done
```

The post-create hook (`post-create.sh`) ran automatically and wrote
`labs/output/devcontainer-manifest.json` with tool versions. Check it:

```sh
cat labs/output/devcontainer-manifest.json
```

---

### 4. Build Contract B — drop-mango firmware

The Mango build runs **inside the ImageBuilder Docker container** — the ImageBuilder image
ships with the cross-compilation toolchain and pre-built packages for `ramips/mt76x8`.
You do not need a native MIPS toolchain on your laptop.

```sh
# From the labs/ directory (course root → labs/)
cd courses/engagement-platform-labs/labs

# Via the Makefile
make drop-mango
```

The Makefile invokes:
```sh
docker compose run --rm imagebuilder \
    /labs/lab02-imagebuilder-firmware/build-drop-mango.sh
```

Expected output (abbreviated):

```
>>> drop-mango build
    PROFILE=glinet_gl-mt300n-v2
    FILES_DIR=/labs/shared/files-mango
    SOURCE_DATE_EPOCH=1714694400
    OUTPUT_DIR=/labs/output
    PWD=/home/buildbot/openwrt-imagebuilder-23.05.3-ramips-mt76x8.Linux-x86_64
>>> built: bin/targets/ramips/mt76x8/openwrt-...-glinet_gl-mt300n-v2-drop-v1-squashfs-sysupgrade.bin
    size: <N> bytes
    sha256: <...>
    squashfs rootfs: <M> bytes
>>> artifacts in /labs/output/
```

The build script enforces a squashfs ceiling of 13 MB. If the package list is too large,
the build exits with:

```
ERROR: squashfs rootfs N bytes exceeds ceiling 13631488
       trim the PACKAGES list or move heavy packages to ExtRoot (Lab 03)
```

This is intentional. The constraint is the lesson.

---

### 5. Verify build artifacts and squashfs size

```sh
# Confirm both artifacts exist
ls -lh labs/output/
# Expected:
#   engagement-platform-rootfs.tar
#   openwrt-...-glinet_gl-mt300n-v2-drop-v1-squashfs-sysupgrade.bin
#   build-manifest.json
#   devcontainer-manifest.json (written by post-create.sh)

# Verify the Mango .bin is present
BIN=$(ls labs/output/*glinet_gl-mt300n-v2*sysupgrade.bin 2>/dev/null | head -1)
echo "$BIN"

# Compute size in MB for human review
wc -c < "$BIN" | awk '{printf "%.2f MB\n", $1/1024/1024}'
# Should be well under 16 MB

# Read the drop-mango build-manifest.json
cat labs/output/build-manifest.json
# Verify "role": "drop-mango" and "openwrt_version": "23.05.3"
```

**Compare SHA256 with a neighbor's build:**

Both builds used `SOURCE_DATE_EPOCH=1714694400` (set in `build-drop-mango.sh`) to strip
squashfs timestamps. Two students building from the same commit on the same day should
produce identical `.bin` SHA256 values:

```sh
sha256sum labs/output/*sysupgrade.bin
```

If the SHAs differ, check whether the package feeds served different package versions.
The `package_list_sha256` field in `build-manifest.json` records a hash of the package
list itself; if that matches between two students but the `.bin` doesn't, a package
metadata difference in the feed is the likely cause.

---

### 6. Compare the two contracts (discussion)

With both artifacts in hand, compare them side by side:

```sh
# Contract A: what's in the devcontainer rootfs tarball
tar tf labs/output/engagement-platform-rootfs.tar | grep -E 'tailscale|cloudflared|python3|wrangler' | head -20

# Contract B: what's in the Mango squashfs
# (unsquashfs requires squashfs-tools on the host; skip if unavailable)
# Instead, read the package list from the ImageBuilder manifest
ls labs/output/*.manifest 2>/dev/null || \
    docker compose run --rm imagebuilder \
        cat /home/buildbot/openwrt-imagebuilder-23.05.3-ramips-mt76x8.Linux-x86_64/bin/targets/ramips/mt76x8/*.manifest
```

Key questions to answer before moving on:

1. Which packages in Contract A are absent from Contract B? (Answer: tailscale,
   cloudflared, python3, nmap, nginx, luci, wrangler — all too large for 16 MB NOR.)
2. What does Contract B have that enables it to grow past its NOR constraint? (Answer:
   `block-mount`, `kmod-usb-storage`, `kmod-fs-ext4`, `e2fsprogs` — the ExtRoot toolchain
   taught in Lab 03.)
3. Why does Contract B omit `dnsmasq`, `firewall4`, and `nftables`? (Answer: the Mango
   in its drop role connects only via Tailscale, not as a router; no DNS/firewall/NAT
   needed from the NOR image. These can be added to ExtRoot later if the mission profile
   requires them.)

---

## Post-state

When this lab is complete:

- [ ] `labs/output/engagement-platform-rootfs.tar` exists and SHA256 is recorded in
  `labs/output/build-manifest.json`.
- [ ] `labs/output/openwrt-...-glinet_gl-mt300n-v2-drop-v1-squashfs-sysupgrade.bin`
  exists and fits in 16 MB (confirmed by `validate.sh`).
- [ ] The devcontainer is rebuilt and VS Code shows **"Dev Container: EPL Engagement
  Platform (OpenWrt 23.05.3)"** in the bottom-left status bar.
- [ ] You can articulate the three packages that define the size boundary between what
  fits in NOR and what must go on ExtRoot.

---

## Validation

```sh
# From the course root
chmod +x courses/engagement-platform-labs/labs/lab02-imagebuilder-firmware/validate.sh
bash courses/engagement-platform-labs/labs/lab02-imagebuilder-firmware/validate.sh

# Or via Makefile
cd courses/engagement-platform-labs/labs
make validate-lab02-imagebuilder-firmware
```

The script checks:

1. `labs/output/build-manifest.json` exists and `role` field is present and valid.
2. The sysupgrade `.bin` for `glinet_gl-mt300n-v2` exists in `labs/output/`.
3. The `.bin` is smaller than 16,777,216 bytes (16 MB hard ceiling — the NOR chip size).
4. `build-manifest.json` validates against
   `labs/shared/build-manifest.schema.json` using `python3` (available in the
   devcontainer or the host).

---

## Take-home extension

See `take-home/lab02-mt3000-build/` (not yet written — Wave 4 content). The scope:

- Same dual-contract exercise on `mediatek/filogic` / `glinet_gl-mt3000`.
- The MT3000 carries eMMC, so the "drop firmware" has no 16 MB NOR constraint.
- The contrast becomes package selection for a different reason: what should the MT3000
  carry that the Mango cannot, and vice versa for a mission that uses both?

---

## Troubleshooting

<details>
<summary>make drop-mango: docker compose run fails — imagebuilder service not found</summary>

The `docker-compose.yml` must be present in `courses/engagement-platform-labs/labs/`.
Verify:

```sh
ls courses/engagement-platform-labs/labs/docker-compose.yml
docker compose -f courses/engagement-platform-labs/labs/docker-compose.yml config
```

If the file is missing, check `git status` — it may be untracked or deleted.

</details>

<details>
<summary>opkg download errors during engagement-platform build</summary>

The devcontainer `Dockerfile` runs `opkg update` at build time against the OpenWrt 23.05.3
package feeds. If a feed is temporarily unavailable:

```sh
# Retry the build (Docker caches layers, so only the failed layer reruns)
make engagement-platform

# If the feed is consistently down, check the OpenWrt downloads mirror status:
# https://downloads.openwrt.org/
```

The `cloudflared` binary download in the Dockerfile is the most likely to fail on a
corporate network (GitHub releases may be blocked). If so, the instructor can pre-stage
the binary in `.devcontainer/` and update the `Dockerfile` to `COPY` it instead of
`curl`-ing it.

</details>

<details>
<summary>squashfs ceiling exceeded — build-drop-mango.sh exits with ERROR</summary>

The 13 MB ceiling is enforced by the build script. If you modified `PACKAGES` and exceeded
it:

```sh
# Identify the heaviest packages in the image
docker compose run --rm imagebuilder \
    find /home/buildbot/openwrt-imagebuilder-23.05.3-ramips-mt76x8.Linux-x86_64/bin/targets \
         -name '*.ipk' | xargs ls -lS 2>/dev/null | head -20
```

Candidate packages to remove: `e2fsprogs` (small, but check) and any extra kmod modules.
Do not remove `block-mount` or `kmod-usb-storage` — they are required for ExtRoot in
Lab 03.

</details>

<details>
<summary>build-manifest.json validation fails (python3 not found on host)</summary>

`validate.sh` uses `python3` to validate JSON against the schema. If your host lacks
Python 3, run validation from inside the devcontainer:

```sh
# Open devcontainer terminal in VS Code, then:
bash /workspaces/engagement-platform-labs/labs/lab02-imagebuilder-firmware/validate.sh
```

Or install `python3` on the host (`apt install python3` / `brew install python3`).

</details>
