#!/bin/sh
# Lab 01 — validate.sh
# Exits 0 if both platform checks pass; prints the first failing assertion and exits 1.
#
# Usage:
#   bash labs/lab01-hardware-familiarization/validate.sh
#
# Make executable once after cloning:
#   chmod +x labs/lab01-hardware-familiarization/validate.sh

set -eu

# MANGO_HOST defaults to 192.168.8.1 (stock GL.iNet firmware). For Mangos
# running pure upstream OpenWrt, set MANGO_HOST=192.168.1.1 (or whatever
# your unit is configured to). The script does NOT auto-probe.
MANGO_HOST="${MANGO_HOST:-192.168.8.1}"
MANGO_USER="${MANGO_USER:-root}"
SSH_TIMEOUT="${SSH_TIMEOUT:-10}"
CONTAINER_NAME="${CONTAINER_NAME:-ep-devcontainer}"

PASS=0
FAIL=1

fail() {
    printf '[FAIL] %s\n' "$*" >&2
    exit "$FAIL"
}

pass() {
    printf '[PASS] %s\n' "$*"
}

# ---------------------------------------------------------------------------
# Check 1: SSH into the Mango and verify /etc/openwrt_release
# ---------------------------------------------------------------------------

printf 'Checking SSH to Mango at %s...\n' "$MANGO_HOST"

MANGO_RELEASE=$(ssh \
    -o ConnectTimeout="$SSH_TIMEOUT" \
    -o StrictHostKeyChecking=no \
    -o BatchMode=yes \
    "${MANGO_USER}@${MANGO_HOST}" \
    'cat /etc/openwrt_release' 2>/dev/null) || {
    fail "ssh ${MANGO_USER}@${MANGO_HOST} failed — is the Mango connected and SSH enabled?"
}

printf '%s\n' "$MANGO_RELEASE" | grep -qE "DISTRIB_ID=['\"]OpenWrt['\"]" || {
    fail "Mango /etc/openwrt_release does not contain DISTRIB_ID='OpenWrt'. Got:\n${MANGO_RELEASE}"
}

pass "Mango SSH ok — DISTRIB_ID=OpenWrt"

# Optionally validate the OpenWrt version matches the course pin (23.05.x)
MANGO_VERSION=$(printf '%s\n' "$MANGO_RELEASE" | grep 'DISTRIB_RELEASE' | cut -d= -f2 | tr -d '"')
printf '    Mango DISTRIB_RELEASE: %s\n' "$MANGO_VERSION"

# ---------------------------------------------------------------------------
# Check 2: docker exec into the devcontainer and verify /etc/openwrt_release
# ---------------------------------------------------------------------------

printf 'Checking docker exec into container "%s"...\n' "$CONTAINER_NAME"

# Confirm container is running before attempting exec
docker inspect "$CONTAINER_NAME" >/dev/null 2>&1 || {
    fail "Container '$CONTAINER_NAME' not found. Start it via VS Code 'Reopen in Container' or with:
  docker run --rm -d --name $CONTAINER_NAME openwrt/rootfs:x86-64-23.05.3 tail -f /dev/null"
}

RUNNING=$(docker inspect --format '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || echo false)
if [ "$RUNNING" != "true" ]; then
    fail "Container '$CONTAINER_NAME' exists but is not running. Start it first."
fi

CONTAINER_RELEASE=$(docker exec "$CONTAINER_NAME" cat /etc/openwrt_release 2>/dev/null) || {
    fail "docker exec ${CONTAINER_NAME} cat /etc/openwrt_release failed"
}

printf '%s\n' "$CONTAINER_RELEASE" | grep -qE "DISTRIB_ID=['\"]OpenWrt['\"]" || {
    fail "Devcontainer /etc/openwrt_release does not contain DISTRIB_ID='OpenWrt'. Got:\n${CONTAINER_RELEASE}"
}

pass "Devcontainer exec ok — DISTRIB_ID=OpenWrt"

CONTAINER_VERSION=$(printf '%s\n' "$CONTAINER_RELEASE" | grep 'DISTRIB_RELEASE' | cut -d= -f2 | tr -d '"')
printf '    Devcontainer DISTRIB_RELEASE: %s\n' "$CONTAINER_VERSION"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\nAll Lab 01 checks passed.\n'
printf '  Mango:        %s @ %s\n' "$MANGO_VERSION" "$MANGO_HOST"
printf '  Devcontainer: %s (%s)\n' "$CONTAINER_VERSION" "$CONTAINER_NAME"

exit "$PASS"
