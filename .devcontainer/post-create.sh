#!/bin/sh
# Runs once when the devcontainer is first created (or rebuilt).
# Idempotent: safe to re-run.
#
# This is the OUTER Debian operator console. The OpenWrt rootfs lives on as
# a sibling docker container — see Lab 01 Step 4 — which we pre-pull here
# so the comparison in Step 5 is instant.

set -eu

WORKSPACE="${1:-${PWD}}"
LOG="$WORKSPACE/.devcontainer/post-create.log"
mkdir -p "$(dirname "$LOG")"

log() {
    echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] $*" | tee -a "$LOG"
}

log "EPL devcontainer (operator console) post-create starting"
log "Workspace: $WORKSPACE"

# Confirm engagement-stack tools are present
for bin in tailscale cloudflared python3 wrangler git curl jq tcpdump node; do
    if command -v "$bin" >/dev/null 2>&1; then
        log "ok   $bin: $(command -v "$bin")"
    else
        log "WARN $bin missing — labs that need it will fail; check Dockerfile build"
    fi
done

# Pre-pull the OpenWrt rootfs sibling image so Lab 01 Step 4 is instant.
# Docker-in-Docker may take a moment to be ready on first boot; tolerate that.
SIBLING_IMAGE="${EPL_OPENWRT_SIBLING_IMAGE:-openwrt/rootfs:x86-64-23.05.3}"
SIBLING_NAME="${EPL_OPENWRT_SIBLING_NAME:-ep-devcontainer}"

if command -v docker >/dev/null 2>&1; then
    log "Waiting for inner Docker daemon (DinD) to be ready..."
    _ready=0
    _i=0
    while [ "$_i" -lt 30 ]; do
        if docker info >/dev/null 2>&1; then
            _ready=1
            break
        fi
        _i=$((_i + 1))
        sleep 1
    done
    if [ "$_ready" -eq 1 ]; then
        log "Docker daemon ready; pulling $SIBLING_IMAGE"
        if docker pull "$SIBLING_IMAGE" >>"$LOG" 2>&1; then
            log "ok   $SIBLING_IMAGE pulled"
        else
            log "WARN failed to pull $SIBLING_IMAGE — Lab 01 Step 4 will retry on demand"
        fi
    else
        log "WARN Docker daemon not ready after 30s; sibling image will be pulled on demand"
    fi
else
    log "WARN docker CLI missing — docker-in-docker feature did not install"
fi

# Capture build manifest for reproducibility audit
MANIFEST="$WORKSPACE/labs/output/devcontainer-manifest.json"
mkdir -p "$(dirname "$MANIFEST")"
cat > "$MANIFEST" <<EOF
{
  "role": "engagement-platform-operator-console",
  "base": "debian-bookworm",
  "openwrt_sibling_image": "$SIBLING_IMAGE",
  "openwrt_sibling_name": "$SIBLING_NAME",
  "tailscale_version": "$(tailscale version 2>/dev/null | head -1 || echo unknown)",
  "cloudflared_version": "$(cloudflared --version 2>/dev/null | head -1 || echo unknown)",
  "wrangler_version": "$(wrangler --version 2>/dev/null | head -1 || echo unknown)",
  "node_version": "$(node --version 2>/dev/null || echo unknown)",
  "python_version": "$(python3 --version 2>/dev/null || echo unknown)",
  "docker_version": "$(docker --version 2>/dev/null || echo unknown)",
  "created_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF

log "Manifest written to $MANIFEST"

# Tailscale TUN mode — kernel TUN locally, userspace in Codespaces.
if [ -n "${CODESPACES:-}" ]; then
    log "Codespaces detected; configuring Tailscale for userspace networking."
    cat > /etc/profile.d/epl-tailscale.sh <<'PROFILE'
# Tailscale must run in userspace networking mode on Codespaces (no /dev/net/tun).
export TS_USERSPACE=1
export TS_EXTRA_ARGS="--tun=userspace-networking"
PROFILE
    chmod 644 /etc/profile.d/epl-tailscale.sh
    log "  TS_USERSPACE=1 set; tailscale up should pass --tun=userspace-networking"
fi

cat <<'BANNER'

================================================================================
[EPL] Engagement Platform — Operator Console (Debian)

  This container is the Day-2 operator stack: tailscale, cloudflared, wrangler,
  python, jq. vscode-server runs natively on glibc — no musl shim needed.

  The OpenWrt rootfs lives in a SIBLING container (Lab 01 Step 4):

    docker run -d --rm --name ep-devcontainer \
        openwrt/rootfs:x86-64-23.05.3 \
        /bin/sh -c 'mkdir -p /var/lock /var/run /var/log; tail -f /dev/null'

    openwrt-shell                 # convenience: docker exec into the sibling
    docker stop ep-devcontainer   # tear it down when done

  Everything else (Day 2 labs) runs here in the operator console.

  Codespaces: run `epl login` after pasting a token from
              https://course.eplabs.cloud/profile to enable progress sync.
================================================================================

BANNER

log "EPL devcontainer ready"
