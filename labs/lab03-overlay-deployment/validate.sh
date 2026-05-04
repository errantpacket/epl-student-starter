#!/bin/sh
# Lab 03 validate.sh — ExtRoot, package presence, version probes.
#
# Connects to the Mango via SSH and asserts:
#   1. /overlay is mounted from a block device (USB), not the NOR overlayfs.
#   2. /overlay has at least 1 GB free (confirms USB, not a ramdisk stub).
#   3. tailscale --version returns a non-empty string.
#   4. cloudflared --version returns a non-empty string.
#   5. python3 --version returns a non-empty string.
#
# Usage:
#   ./validate.sh                     # connects to 192.168.8.1 (default)
#   MANGO_HOST=10.0.0.1 ./validate.sh # override host
#
# Exit 0 on full pass; non-zero with a descriptive message on first failure.

set -eu

MANGO_HOST="${MANGO_HOST:-192.168.8.1}"
MANGO_USER="${MANGO_USER:-root}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

# Minimum free space on /overlay to accept as "USB, not NOR" (bytes).
# NOR overlayfs typically reports < 8 MB free; a USB drive reports GB.
MIN_FREE_BYTES=$((1024 * 1024 * 1024))   # 1 GB

pass() {
    printf 'PASS  %s\n' "$1"
}

fail() {
    printf 'FAIL  %s\n' "$1" >&2
    exit 1
}

run_on_mango() {
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "${MANGO_USER}@${MANGO_HOST}" "$@"
}

echo "=== Lab 03 validate: Mango at ${MANGO_HOST} ==="
echo ""

# ---- 1. SSH reachability ----
if ! run_on_mango 'true' 2>/dev/null; then
    fail "Cannot SSH to ${MANGO_USER}@${MANGO_HOST} — is the Mango powered on and reachable?"
fi
pass "SSH reachable: ${MANGO_USER}@${MANGO_HOST}"

# ---- 2. /overlay is a block device mount ----
# `mount` output for ExtRoot looks like: /dev/sdaX on /overlay type ext4
OVERLAY_FSTYPE=$(run_on_mango 'mount | awk '"'"'$3=="/overlay" {print $5}'"'"'')
if [ -z "$OVERLAY_FSTYPE" ]; then
    fail "/overlay is not listed in mount output — ExtRoot is not active. Check 'uci show fstab' and reboot."
fi
if [ "$OVERLAY_FSTYPE" != "ext4" ]; then
    fail "/overlay is mounted as type '$OVERLAY_FSTYPE', expected ext4 (USB). ExtRoot may not be configured correctly."
fi
pass "/overlay is mounted as ext4 (ExtRoot active)"

# ---- 3. /overlay reports free space >= 1 GB ----
# df -k output column 4 is available KB
OVERLAY_FREE_KB=$(run_on_mango "df -k /overlay | awk 'NR==2 {print \$4}'")
if [ -z "$OVERLAY_FREE_KB" ]; then
    fail "Could not read free space from df -k /overlay"
fi
OVERLAY_FREE_BYTES=$((OVERLAY_FREE_KB * 1024))
if [ "$OVERLAY_FREE_BYTES" -lt "$MIN_FREE_BYTES" ]; then
    FREE_MB=$((OVERLAY_FREE_KB / 1024))
    fail "/overlay has only ${FREE_MB} MB free — expected at least 1 GB. Is the USB drive mounted?"
fi
FREE_GB=$((OVERLAY_FREE_KB / 1024 / 1024))
pass "/overlay free space: ${FREE_GB} GB (>= 1 GB threshold)"

# ---- 4. tailscale --version is non-empty ----
TS_VERSION=$(run_on_mango 'tailscale --version 2>/dev/null | head -1' || true)
if [ -z "$TS_VERSION" ]; then
    fail "tailscale --version returned empty output — tailscale is not installed or not on PATH. Run: opkg install tailscale"
fi
pass "tailscale version: ${TS_VERSION}"

# ---- 5. cloudflared --version is non-empty ----
CF_VERSION=$(run_on_mango 'cloudflared --version 2>/dev/null | head -1' || true)
if [ -z "$CF_VERSION" ]; then
    fail "cloudflared --version returned empty output — cloudflared is not installed. See Lab 03 Troubleshooting."
fi
pass "cloudflared version: ${CF_VERSION}"

# ---- 6. python3 --version is non-empty ----
PY_VERSION=$(run_on_mango 'python3 --version 2>/dev/null' || true)
if [ -z "$PY_VERSION" ]; then
    fail "python3 --version returned empty output — python3-light is not installed. Run: opkg install python3-light"
fi
pass "python3 version: ${PY_VERSION}"

echo ""
echo "=== Lab 03 validate: ALL PASSED ==="
exit 0
