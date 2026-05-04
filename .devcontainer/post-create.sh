#!/bin/sh
# Runs once when the devcontainer is first created (or rebuilt).
# Idempotent: safe to re-run.

set -eu

WORKSPACE="${1:-/workspaces/engagement-platform-labs}"
LOG="$WORKSPACE/.devcontainer/post-create.log"

log() {
    echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] $*" | tee -a "$LOG"
}

log "EPL devcontainer post-create starting"

# Sanity: confirm we're inside an OpenWrt rootfs
if [ ! -f /etc/openwrt_release ]; then
    log "ERROR: /etc/openwrt_release missing — base image isn't OpenWrt"
    exit 1
fi

# shellcheck disable=SC1091
. /etc/openwrt_release
log "OpenWrt: $DISTRIB_ID $DISTRIB_RELEASE ($DISTRIB_TARGET)"

# Confirm engagement-stack tools are present
for bin in tailscale cloudflared python3 wrangler git curl jq tcpdump; do
    if command -v "$bin" >/dev/null 2>&1; then
        log "ok   $bin: $(command -v "$bin")"
    else
        log "WARN $bin missing — labs that need it will fail; check Dockerfile build"
    fi
done

# Capture build manifest for reproducibility audit
MANIFEST="$WORKSPACE/labs/output/devcontainer-manifest.json"
mkdir -p "$(dirname "$MANIFEST")"
cat > "$MANIFEST" <<EOF
{
  "role": "engagement-platform",
  "openwrt_version": "$DISTRIB_RELEASE",
  "openwrt_target": "$DISTRIB_TARGET",
  "tailscale_version": "$(tailscale version 2>/dev/null | head -1 || echo unknown)",
  "cloudflared_version": "$(cloudflared --version 2>/dev/null | head -1 || echo unknown)",
  "wrangler_version": "$(wrangler --version 2>/dev/null | head -1 || echo unknown)",
  "node_version": "$(node --version 2>/dev/null || echo unknown)",
  "python_version": "$(python3 --version 2>/dev/null || echo unknown)",
  "created_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF

log "Manifest written to $MANIFEST"
log "EPL devcontainer ready"

# Tailscale TUN mode — kernel TUN locally, userspace in Codespaces.
if [ -n "${CODESPACES:-}" ]; then
    log "Codespaces detected; configuring Tailscale for userspace networking."
    # Persist the env var so subsequent shells / scripts see it
    cat > /etc/profile.d/epl-tailscale.sh <<'PROFILE'
# Tailscale must run in userspace networking mode on Codespaces (no /dev/net/tun).
export TS_USERSPACE=1
export TS_EXTRA_ARGS="--tun=userspace-networking"
PROFILE
    chmod 644 /etc/profile.d/epl-tailscale.sh
    log "  TS_USERSPACE=1 set; tailscale up should pass --tun=userspace-networking"
fi
