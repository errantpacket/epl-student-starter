# Engagement Platform Labs — Lab Files

Supporting configs, scripts, and build wrappers for the 2-day Engagement
Platform Labs workshop.

> **Status:** All 14 labs written and ready for delivery.

## Kit (per student)

| Role | Item | Notes |
|------|------|-------|
| Engagement platform | VS Code devcontainer (OpenWrt 23.05.3 rootfs on student laptop) | Full engagement stack; unconstrained on flash/RAM |
| Drop device | GL.iNet Mango (GL-MT300N-V2) | 16MB NOR, 128MB RAM, ramips/mt76x8 |
| Storage | USB flash drive (16GB+) | ExtRoot overlay for the Mango |
| Operator client | Laptop | Discord, wrangler, ssh — also hosts the devcontainer |

## Quick Start

```bash
# Build the devcontainer rootfs (engagement platform)
make engagement-platform

# Build the Mango drop firmware
make drop-mango

# Output images land in ./output/
ls output/
```

Both `make` targets use the ImageBuilder container defined in
`Dockerfile` + `docker-compose.yml`.

## Lab Index

### Day 1 — Foundation

| Lab | Topic | Duration | Status |
|-----|-------|----------|--------|
| [01](lab01-hardware-familiarization/) | Hardware familiarization & recovery | 45 min | Written |
| [02](lab02-imagebuilder-firmware/) | Engagement platform build (devcontainer + Mango) | 75 min | Written |
| [03](lab03-overlay-deployment/) | Overlay deployment, ExtRoot, persistence | 60 min | Written |
| [04](lab04-domain-verification/) | Domain & Cloudflare verification | 15 min | Written |
| [05](lab05-tailscale-mesh/) | Tailscale mesh network | 60 min | Written |
| [06](lab06-cloudflare-tunnel/) | Cloudflare Tunnel from devcontainer | 45 min | Written |
| [07](lab07-first-worker/) | First Worker deployment | 60 min | Written |

### Day 2 — Control Plane + Capstone

| Lab | Topic | Duration | Status |
|-----|-------|----------|--------|
| [08](lab08-cloudflare-access/) | Cloudflare Access for operators | 45 min | Written |
| [09](lab09-d1-database/) | D1 device registry + audit log | 60 min | Written |
| [10](lab10-kv-r2-storage/) | KV + R2 storage | 75 min | Written |
| [11](lab11-chatops-emojichef/) | ChatOps with EmojiChef | 60 min | Written |
| [12](lab12-drop-device/) | Drop device deployment (Mango) | 45 min | Written |
| [13](lab13-redirector-relay/) | Redirector / edge relay | 60 min | Written |
| [14](lab14-capstone/) | Capstone end-to-end | 75 min | Written |

## Directory Layout

```
labs/
├── Makefile                             # make engagement-platform, make drop-mango, make validate-XX
├── Dockerfile                           # ImageBuilder container
├── docker-compose.yml                   # Mounts labs + output volume
├── shared/                              # Helpers shared across labs
│   ├── build-manifest.schema.json       # Schema for per-build SHA manifests
│   └── files-mango/                     # Overlay root baked into Mango firmware
│       └── etc/uci-defaults/99-enroll.sh.template
│
├── lab01-hardware-familiarization/      # Day 1 — Hardware tour & recovery
├── lab02-imagebuilder-firmware/         # Day 1 — Dual-target build
├── lab03-overlay-deployment/            # Day 1 — ExtRoot & persistence
├── lab04-domain-verification/           # Day 1 — Cloudflare DNS check
├── lab05-tailscale-mesh/                # Day 1 — Two-node tailnet
├── lab06-cloudflare-tunnel/             # Day 1 — Tunnel ingress
├── lab07-first-worker/                  # Day 1 — Edge function skeleton
├── lab08-cloudflare-access/             # Day 2 — SSO + service tokens
├── lab09-d1-database/                   # Day 2 — Device registry
├── lab10-kv-r2-storage/                 # Day 2 — Session + artifact storage
├── lab11-chatops-emojichef/             # Day 2 — Discord/hack.chat integration
├── lab12-drop-device/                   # Day 2 — Mango self-enrollment
├── lab13-redirector-relay/              # Day 2 — Edge redirector (Oblique-Relay)
├── lab14-capstone/                      # Day 2 — End-to-end demo
│
├── take-home/                           # Post-workshop depth track (MT3000 hardware)
│   ├── README.md                        # Index
│   ├── lab01-mt3000-tour/               # Physical tour of MT3000
│   ├── lab02-mt3000-build/              # mediatek/filogic build variant
│   ├── lab03-mt3000-emmc/               # eMMC vs ExtRoot contrast
│   └── lab12-mt3000-drop/              # MT3000 drop with WiFi-6
│
└── instructor/                          # Facilitator-only scripts
```

## Target Hardware

| Role | Device | OpenWrt profile |
|------|--------|-----------------|
| Engagement platform (primary) | VS Code devcontainer | `openwrt/rootfs:ramips-mt76x8-23.05.3` |
| Drop device | GL.iNet Mango (GL-MT300N-V2) | `glinet_gl-mt300n-v2` |

> **Devcontainer baseline:** Both the engagement platform (devcontainer) and the
> drop device (Mango) pin to OpenWrt 23.05.3 / ramips / mt76x8. The devcontainer
> is the per-student "primary engagement platform" — it runs the full Tailscale
> daemon, cloudflared, and the wrangler/tooling stack without the 16MB NOR
> constraint. The Mango keeps its drop-device role. MT3000/Beryl AX content
> is in `take-home/` for students who later acquire that hardware.

## Reference Repositories

- [Oblique Relay](https://github.com/errantpacket/Oblique-Relay) — canonical
  redirector reference for Lab 13.
