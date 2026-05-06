#!/bin/sh
# Lab 06 — Cloudflare Tunnel: validation script
#
# Exit 0 on success; prints the first failing assertion and exits non-zero on failure.
#
# Required environment variable:
#   STUDENT  — student slot name, e.g. "alpha"
#              Produces the URL https://api.${STUDENT}.eplabs.cloud
#
# Usage:
#   export STUDENT=yourname
#   bash courses/engagement-platform-labs/labs/lab06-cloudflare-tunnel/validate.sh
#
# Assumes:
#   - devcontainer is running and named ep-devcontainer
#   - cloudflared tunnel is running inside the devcontainer
#   - nginx (or another service) is listening on port 8787 in the devcontainer
#   - DNS record api.<student>.eplabs.cloud exists as a CNAME to the tunnel
#   - CF Access is NOT yet wired (Lab 08 will add it; Lab 06 expects open access)
#   - labs/output/build-manifest.json exists

set -eu

DEVCONTAINER="ep-devcontainer"
MANIFEST="labs/output/build-manifest.json"
CF_CONFIG="${CF_CONFIG:-/etc/cloudflared/config.yml}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

assert_contains() {
    desc="$1"; haystack="$2"; needle="$3"
    case "$haystack" in
        *"$needle"*) pass "$desc" ;;
        *)           fail "$desc — expected to find: $needle" ;;
    esac
}

assert_http_status() {
    desc="$1"; url="$2"; expected_status="$3"
    actual_status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$url" 2>/dev/null) \
        || fail "${desc} — curl failed for: ${url}"
    if [ "$actual_status" = "$expected_status" ]; then
        pass "${desc} (HTTP ${actual_status})"
    else
        fail "${desc} — expected HTTP ${expected_status}, got ${actual_status} for: ${url}"
    fi
}

# ---------------------------------------------------------------------------
# Require STUDENT variable
# ---------------------------------------------------------------------------

if [ -z "${STUDENT:-}" ]; then
    fail "STUDENT environment variable is not set. Export it first: export STUDENT=yourname"
fi

PUBLIC_URL="https://api.${STUDENT}.eplabs.cloud"

printf '=== Lab 06 validation: STUDENT=%s URL=%s ===\n' "$STUDENT" "$PUBLIC_URL"

# ---------------------------------------------------------------------------
# 1. Public URL returns HTTP 200
# ---------------------------------------------------------------------------

assert_http_status "public tunnel URL returns 200" "${PUBLIC_URL}/" "200"

# ---------------------------------------------------------------------------
# 2. /health endpoint returns JSON with "status":"ok"
# ---------------------------------------------------------------------------

HEALTH_BODY=$(curl -s --max-time 20 "${PUBLIC_URL}/health" 2>/dev/null) \
    || fail "/health curl failed"

assert_contains "/health returns status:ok" "$HEALTH_BODY" '"status"'
assert_contains "/health returns ok value" "$HEALTH_BODY" "ok"

# ---------------------------------------------------------------------------
# 3. cloudflared tunnel is HEALTHY inside the devcontainer
# ---------------------------------------------------------------------------

# Detect whether we are inside the operator console (Codespace, or a shell
# already inside the Local Dev Container) or outside it (host shell that
# needs `docker exec` to reach the container).
if command -v cloudflared >/dev/null 2>&1; then
    CF_EXEC=""   # call cloudflared directly
else
    CF_EXEC="docker exec ${DEVCONTAINER}"
fi

# Check that cloudflared process is running
CF_PROC=$(${CF_EXEC} sh -c 'pgrep -x cloudflared 2>/dev/null || echo ""')
if [ -z "$CF_PROC" ]; then
    fail "cloudflared is not running — start it with 'cloudflared tunnel --config /etc/cloudflared/config.yml run &' (foreground/background) or 'systemctl start cloudflared' (systemd)"
fi
pass "cloudflared process is running (PID: ${CF_PROC})"

# Check tunnel info reports at least one active edge connection.
#
# `cloudflared tunnel info` requires the tunnel name/id as a positional
# argument; current cloudflared (2026.x) does not infer it from --config.
# Resolve the tunnel id from the config file (or accept TUNNEL_NAME env
# override), then query JSON output and verify at least one `colo_name`
# field is present, which indicates a registered edge connection.
TUNNEL_NAME="${TUNNEL_NAME:-$(${CF_EXEC} sh -c "awk '/^tunnel:/ {print \$2; exit}' ${CF_CONFIG} 2>/dev/null")}"
if [ -z "$TUNNEL_NAME" ]; then
    fail "could not determine tunnel id/name — set TUNNEL_NAME=ep-<slot> or place a 'tunnel:' line in ${CF_CONFIG}"
fi

CF_INFO=$(${CF_EXEC} cloudflared tunnel info --output json "$TUNNEL_NAME" 2>/dev/null) \
    || fail "cloudflared tunnel info '${TUNNEL_NAME}' failed — confirm the tunnel exists and the credential JSON is in ~/.cloudflared/"

if printf '%s' "$CF_INFO" | grep -q '"colo_name"'; then
    COLOS=$(printf '%s' "$CF_INFO" | grep -o '"colo_name": *"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/' | sort -u | paste -sd, -)
    pass "cloudflared tunnel '${TUNNEL_NAME}' has registered edge connections (${COLOS})"
else
    fail "cloudflared tunnel '${TUNNEL_NAME}' has no active edge connections — check 'cloudflared tunnel info ${TUNNEL_NAME}' manually"
fi

# ---------------------------------------------------------------------------
# 4. DNS CNAME record resolves to cfargotunnel.com
# ---------------------------------------------------------------------------

CNAME=$(dig CNAME "api.${STUDENT}.eplabs.cloud" +short 2>/dev/null | head -1)
if [ -z "$CNAME" ]; then
    # dig may not be available; treat as warning, not failure
    printf '[WARN] dig not available or DNS lookup failed; skipping CNAME check\n'
else
    assert_contains "CNAME resolves to cfargotunnel.com" "$CNAME" "cfargotunnel.com"
fi

# ---------------------------------------------------------------------------
# 5. CF Access is NOT yet blocking (Lab 08 adds Access; Lab 06 expects open)
#    This check is advisory — it warns but does not fail if Access is already on.
# ---------------------------------------------------------------------------

NO_AUTH_STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    "${PUBLIC_URL}/" 2>/dev/null) \
    || NO_AUTH_STATUS="000"

if [ "$NO_AUTH_STATUS" = "403" ] || [ "$NO_AUTH_STATUS" = "401" ]; then
    printf '[NOTE] CF Access is already enforcing authentication (HTTP %s). ' "$NO_AUTH_STATUS"
    printf 'This is expected AFTER Lab 08. If you are running Lab 06 validation before Lab 08, '
    printf 'the open-access check is expected to return 200.\n'
elif [ "$NO_AUTH_STATUS" = "200" ]; then
    pass "public URL accessible without CF Access auth headers (correct for Lab 06)"
else
    printf '[WARN] Unexpected status %s from unauthenticated request; proceeding\n' "$NO_AUTH_STATUS"
fi

# ---------------------------------------------------------------------------
# 6. build-manifest.json contains cloudflared_version
# ---------------------------------------------------------------------------

if [ ! -f "$MANIFEST" ]; then
    fail "labs/output/build-manifest.json does not exist — run step 8 of the lab walkthrough"
fi

CF_VER=$(jq -r '.cloudflared_version // empty' "$MANIFEST" 2>/dev/null)
if [ -z "$CF_VER" ]; then
    fail "build-manifest.json is missing cloudflared_version — run step 8 of the lab walkthrough"
fi
pass "build-manifest.json contains cloudflared_version: ${CF_VER}"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

printf '\n=== Lab 06 validation PASSED ===\n'
printf 'Tunnel URL: %s\n' "$PUBLIC_URL"
printf 'cloudflared version: %s\n' "$CF_VER"
printf 'Note: CF Access protection is added in Lab 08.\n'
