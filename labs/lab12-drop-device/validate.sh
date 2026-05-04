#!/bin/sh
# lab12-drop-device/validate.sh
#
# Asserts that a drop-<STUDENT> Mango has enrolled via the Worker within the
# last 5 minutes.
#
# Required env vars:
#   DOMAIN               — e.g. a00f3f13.eplabs.cloud
#   STUDENT              — slot name, e.g. alpha
#   SERVICE_TOKEN_ID     — CF Access service token id (from lab08)
#   SERVICE_TOKEN_SECRET — CF Access service token secret (from lab08)
#
# Exit codes:
#   0 — all assertions pass
#   1 — first failing assertion printed to stderr

set -eu

WORKER_URL="${WORKER_URL:-https://api.${DOMAIN}}"
TARGET_HOSTNAME="drop-${STUDENT}"
MAX_AGE_SECONDS=300   # 5 minutes

# ---------------------------------------------------------------------------
die() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

pass() {
    printf 'ok   %s\n' "$*"
}

require_env() {
    eval "val=\${$1:-}"
    [ -n "$val" ] || die "Required env var \$$1 is not set.
  Export it before running this script:
    export $1=<value>"
}

# ---------------------------------------------------------------------------
require_env DOMAIN
require_env STUDENT
require_env SERVICE_TOKEN_ID
require_env SERVICE_TOKEN_SECRET

# ---------------------------------------------------------------------------
# 1. Fetch the device list from the Worker
# ---------------------------------------------------------------------------
printf 'Fetching /v1/devices from %s...\n' "$WORKER_URL"

RESPONSE=$(curl -sf \
    -H "CF-Access-Client-Id: ${SERVICE_TOKEN_ID}" \
    -H "CF-Access-Client-Secret: ${SERVICE_TOKEN_SECRET}" \
    "${WORKER_URL}/v1/devices" 2>/dev/null) || \
    die "curl to ${WORKER_URL}/v1/devices failed (is the Worker up? Lab 09 complete?)"

pass "received response from /v1/devices"

# ---------------------------------------------------------------------------
# 2. Assert a row exists with the correct tailscale_hostname pattern
# ---------------------------------------------------------------------------
# The hostname is set by the enrollment script as "${SLOT}-<uuid-prefix>".
# The SLOT is "drop-${STUDENT}", so the full hostname starts with "drop-${STUDENT}-".
# We accept both the bare slot name and the slot-uuid variant.
if ! printf '%s' "$RESPONSE" | grep -q "\"drop-${STUDENT}"; then
    die "No device with tailscale_hostname matching 'drop-${STUDENT}' found in response.
  Response was: $(printf '%s' "$RESPONSE" | head -c 512)"
fi
pass "device 'drop-${STUDENT}' is present in /v1/devices"

# ---------------------------------------------------------------------------
# 3. Assert enrolled_at is within the last MAX_AGE_SECONDS seconds
# ---------------------------------------------------------------------------
# Extract enrolled_at for the target device.
# Use jsonfilter if available (Mango), otherwise awk for the devcontainer path.
if command -v jsonfilter >/dev/null 2>&1; then
    # jsonfilter doesn't do conditional object filter well; fall through to awk
    ENROLLED_AT=""
fi

# awk-based extraction: find the line with our hostname and then find enrolled_at
# Works on single-line or pretty-printed JSON responses from the Worker.
ENROLLED_AT=$(printf '%s' "$RESPONSE" | \
    awk -v host="drop-${STUDENT}" '
        /drop-[a-z]+/ && $0 ~ host { found=1 }
        found && /enrolled_at/ {
            gsub(/.*"enrolled_at": *"/, ""); gsub(/".*/, ""); print; exit
        }
    ')

if [ -z "$ENROLLED_AT" ]; then
    # Simpler fallback: just grep for the ISO timestamp near the hostname
    ENROLLED_AT=$(printf '%s' "$RESPONSE" | \
        grep -o '"enrolled_at":"[^"]*"' | head -1 | \
        sed 's/"enrolled_at":"//;s/"//')
fi

if [ -z "$ENROLLED_AT" ]; then
    die "Could not extract enrolled_at from response.
  Check that Lab 09 D1 schema includes enrolled_at column.
  Response: $(printf '%s' "$RESPONSE" | head -c 512)"
fi
pass "enrolled_at = ${ENROLLED_AT}"

# ---------------------------------------------------------------------------
# 4. Parse enrolled_at and compare to current time
# ---------------------------------------------------------------------------
# ISO 8601 → epoch via date.  BusyBox date uses a different -d format.
# Try GNU date first, fall back to busybox.
NOW_EPOCH=$(date +%s)

if date --version >/dev/null 2>&1; then
    # GNU date
    ENROLLED_EPOCH=$(date -d "$ENROLLED_AT" +%s 2>/dev/null || echo 0)
else
    # BusyBox date — expects "YYYY-MM-DD HH:MM:SS" format
    TS_SPACE=$(printf '%s' "$ENROLLED_AT" | sed 's/T/ /;s/\.[0-9]*Z//;s/Z//')
    ENROLLED_EPOCH=$(date -D '%Y-%m-%d %H:%M:%S' -d "$TS_SPACE" +%s 2>/dev/null || echo 0)
fi

if [ "$ENROLLED_EPOCH" -eq 0 ]; then
    printf 'WARN: could not parse enrolled_at timestamp "%s" — skipping recency check\n' \
        "$ENROLLED_AT" >&2
else
    AGE_SECONDS=$(( NOW_EPOCH - ENROLLED_EPOCH ))
    if [ "$AGE_SECONDS" -lt 0 ]; then
        AGE_SECONDS=$(( ENROLLED_EPOCH - NOW_EPOCH ))
    fi

    if [ "$AGE_SECONDS" -gt "$MAX_AGE_SECONDS" ]; then
        die "enrolled_at is ${AGE_SECONDS}s ago — exceeds the ${MAX_AGE_SECONDS}s recency window.
  Did the Mango just enroll?  If you reflashed more than 5 minutes ago, the enrollment is
  stale.  Flash again, wait for the enrollment, and re-run validate.sh immediately."
    fi
    pass "enrollment is recent (${AGE_SECONDS}s ago, limit ${MAX_AGE_SECONDS}s)"
fi

# ---------------------------------------------------------------------------
# 5. Assert sealed image file exists (build artifact check)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/../output"
SEALED_BIN="${OUTPUT_DIR}/drop-mango-sealed-${STUDENT}.bin"

if [ ! -f "$SEALED_BIN" ]; then
    printf 'WARN: sealed image not found at %s — did bake-secrets.sh complete?\n' \
        "$SEALED_BIN" >&2
else
    SEALED_SIZE=$(wc -c < "$SEALED_BIN")
    if [ "$SEALED_SIZE" -lt 5000000 ]; then
        die "sealed image at ${SEALED_BIN} is suspiciously small (${SEALED_SIZE} bytes)"
    fi
    pass "sealed image exists: ${SEALED_BIN} (${SEALED_SIZE} bytes)"
fi

# ---------------------------------------------------------------------------
printf '\nlab12 validation passed.\n'
