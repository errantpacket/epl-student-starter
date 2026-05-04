#!/bin/sh
# Lab 05 — Tailscale Mesh: validation script
#
# Exit 0 on success; prints the first failing assertion and exits non-zero on failure.
#
# Required environment variable:
#   STUDENT  — student slot name, e.g. "alpha" or "yourname"
#              Produces hostnames ep-${STUDENT} and drop-${STUDENT}.
#
# Usage:
#   export STUDENT=yourname
#   bash courses/engagement-platform-labs/labs/lab05-tailscale-mesh/validate.sh
#
# Assumes:
#   - devcontainer is running and named ep-devcontainer (docker exec target)
#   - Mango SSH is reachable at 192.168.8.1 with root access via default key
#   - tailscale is up on both nodes and joined the workshop tailnet
#   - labs/output/build-manifest.json exists and is in JSON format

set -eu

MANGO_SSH="root@192.168.8.1"
MANGO_SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes"
DEVCONTAINER="ep-devcontainer"
MANIFEST="labs/output/build-manifest.json"

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

assert_contains() {
    # assert_contains <description> <haystack> <needle>
    desc="$1"
    haystack="$2"
    needle="$3"
    case "$haystack" in
        *"$needle"*) pass "$desc" ;;
        *)           fail "$desc — expected to find: $needle" ;;
    esac
}

# ---------------------------------------------------------------------------
# Require STUDENT variable
# ---------------------------------------------------------------------------

if [ -z "${STUDENT:-}" ]; then
    fail "STUDENT environment variable is not set. Export it before running: export STUDENT=yourname"
fi

EP_HOST="ep-${STUDENT}"
DROP_HOST="drop-${STUDENT}"

printf '=== Lab 05 validation: STUDENT=%s EP=%s DROP=%s ===\n' \
    "$STUDENT" "$EP_HOST" "$DROP_HOST"

# ---------------------------------------------------------------------------
# 1. Devcontainer: check Self hostname and tag
# ---------------------------------------------------------------------------

EP_STATUS=$(docker exec "$DEVCONTAINER" tailscale status --json 2>/dev/null) \
    || fail "devcontainer tailscale status --json failed — is tailscale up in the devcontainer?"

EP_SELF_HOST=$(printf '%s' "$EP_STATUS" | jq -r '.Self.DNSName // empty' 2>/dev/null | sed 's/\..*//')
assert_contains "devcontainer Self.DNSName matches ep-${STUDENT}" "$EP_SELF_HOST" "$EP_HOST"

EP_TAGS=$(printf '%s' "$EP_STATUS" | jq -r '.Self.Tags // [] | join(",")' 2>/dev/null)
assert_contains "devcontainer Self.Tags contains tag:operator" "$EP_TAGS" "tag:operator"

# ---------------------------------------------------------------------------
# 2. Devcontainer: drop-<student> appears as a peer
# ---------------------------------------------------------------------------

EP_PEER=$(printf '%s' "$EP_STATUS" \
    | jq -r --arg h "$DROP_HOST" \
        '.Peer | to_entries[] | select(.value.DNSName | startswith($h)) | .value.DNSName' \
        2>/dev/null | head -1)

if [ -z "$EP_PEER" ]; then
    fail "devcontainer peers do not include ${DROP_HOST} — is the Mango joined to the tailnet?"
fi
pass "devcontainer sees ${DROP_HOST} as a tailnet peer"

# ---------------------------------------------------------------------------
# 3. Mango: check Self hostname and tag
# ---------------------------------------------------------------------------

# shellcheck disable=SC2086
DROP_STATUS=$(ssh $MANGO_SSH_OPTS "$MANGO_SSH" 'tailscale status --json' 2>/dev/null) \
    || fail "SSH to Mango failed or tailscale status failed on Mango — check connectivity"

DROP_SELF_HOST=$(printf '%s' "$DROP_STATUS" | jq -r '.Self.DNSName // empty' 2>/dev/null | sed 's/\..*//')
assert_contains "Mango Self.DNSName matches drop-${STUDENT}" "$DROP_SELF_HOST" "$DROP_HOST"

DROP_TAGS=$(printf '%s' "$DROP_STATUS" | jq -r '.Self.Tags // [] | join(",")' 2>/dev/null)
assert_contains "Mango Self.Tags contains tag:device" "$DROP_TAGS" "tag:device"

# ---------------------------------------------------------------------------
# 4. Mango: ep-<student> appears as a peer
# ---------------------------------------------------------------------------

DROP_PEER=$(printf '%s' "$DROP_STATUS" \
    | jq -r --arg h "$EP_HOST" \
        '.Peer | to_entries[] | select(.value.DNSName | startswith($h)) | .value.DNSName' \
        2>/dev/null | head -1)

if [ -z "$DROP_PEER" ]; then
    fail "Mango peers do not include ${EP_HOST} — devcontainer not yet visible in tailnet"
fi
pass "Mango sees ${EP_HOST} as a tailnet peer"

# ---------------------------------------------------------------------------
# 5. tailscale ping from devcontainer to Mango
# ---------------------------------------------------------------------------

PING_OUT=$(docker exec "$DEVCONTAINER" \
    tailscale ping --c 3 "$DROP_HOST" 2>/dev/null) \
    || fail "tailscale ping ${DROP_HOST} from devcontainer failed"

assert_contains "tailscale ping returns pong" "$PING_OUT" "pong from ${DROP_HOST}"

# ---------------------------------------------------------------------------
# 6. build-manifest.json contains tailscale_version
# ---------------------------------------------------------------------------

if [ ! -f "$MANIFEST" ]; then
    fail "labs/output/build-manifest.json does not exist — run step 7 of the lab walkthrough"
fi

TS_VER=$(jq -r '.tailscale_version // empty' "$MANIFEST" 2>/dev/null)
if [ -z "$TS_VER" ]; then
    fail "build-manifest.json is missing tailscale_version — run step 7 of the lab walkthrough"
fi
pass "build-manifest.json contains tailscale_version: ${TS_VER}"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

printf '\n=== Lab 05 validation PASSED ===\n'
printf 'Tailnet state: ep-%s (tag:operator) <-> drop-%s (tag:device)\n' "$STUDENT" "$STUDENT"
printf 'Tailscale version pinned: %s\n' "$TS_VER"
