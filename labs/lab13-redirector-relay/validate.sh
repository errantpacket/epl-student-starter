#!/bin/sh
# lab13-redirector-relay/validate.sh
#
# Asserts:
#   (a) curl /relay/* with VALID profile → proxied response (not decoy HTML)
#   (b) curl /relay/* with INVALID profile → decoy 200 with HTML body
#   (c) D1 audit_log contains relay_decision rows for both requests
#
# Required env vars:
#   DOMAIN               — e.g. a00f3f13.eplabs.cloud
#   SERVICE_TOKEN_ID     — CF Access service token id
#   SERVICE_TOKEN_SECRET — CF Access service token secret
#
# Optional:
#   WORKER_URL           — defaults to https://api.${DOMAIN}
#   RELAY_TEST_PATH      — path to test (default: /relay/update)
#   PROFILE_UA           — User-Agent for valid-profile test
#   PROFILE_HEADER_NAME  — header name for valid-profile test
#   PROFILE_HEADER_VALUE — header value for valid-profile test

set -eu

WORKER_URL="${WORKER_URL:-https://api.${DOMAIN}}"
RELAY_TEST_PATH="${RELAY_TEST_PATH:-/relay/update}"

# Default profile values matching profile.example.json
PROFILE_UA="${PROFILE_UA:-Mozilla/5.0 (Windows NT 10.0; Win64; x64) EPL-Implant/1.0}"
PROFILE_HEADER_NAME="${PROFILE_HEADER_NAME:-X-EPL-Profile}"
PROFILE_HEADER_VALUE="${PROFILE_HEADER_VALUE:-epl-relay-alpha-2024}"

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
    [ -n "$val" ] || die "Required env var \$$1 is not set."
}

# ---------------------------------------------------------------------------
require_env DOMAIN
require_env SERVICE_TOKEN_ID
require_env SERVICE_TOKEN_SECRET

TARGET_URL="${WORKER_URL}${RELAY_TEST_PATH}"
printf 'Testing relay endpoint: %s\n' "$TARGET_URL"

# ---------------------------------------------------------------------------
# (a) Valid profile — should proxy to backend (not return decoy HTML)
# ---------------------------------------------------------------------------
printf '\n[1] Valid-profile request (should be proxied)...\n'

VALID_BODY=$(curl -sf \
    -A "$PROFILE_UA" \
    -H "${PROFILE_HEADER_NAME}: ${PROFILE_HEADER_VALUE}" \
    "$TARGET_URL" 2>/dev/null) || \
    die "curl with valid profile failed (connection error or non-2xx response)
  Check that Worker is deployed, /relay/* route exists, and backend is reachable."

# The proxied response should NOT contain the decoy page fingerprint
if printf '%s' "$VALID_BODY" | grep -q 'NetOps Platform'; then
    die "Valid-profile request returned decoy HTML instead of proxied response.
  Check:
    1. KV relay_profile is uploaded (wrangler kv key get --binding RATE_LIMITS --remote relay_profile)
    2. PROFILE_UA contains the user_agent_pattern substring
    3. PROFILE_HEADER_NAME/VALUE match required_header in the profile
    4. RELAY_TEST_PATH is in the allowed_paths list
    5. Backend (app.${DOMAIN}) is reachable via cloudflared tunnel"
fi
pass "valid-profile request did not return decoy HTML"

# Check for the debug relay header the Worker adds in workshop mode
VALID_HEADERS=$(curl -sI \
    -A "$PROFILE_UA" \
    -H "${PROFILE_HEADER_NAME}: ${PROFILE_HEADER_VALUE}" \
    "$TARGET_URL" 2>/dev/null)
if printf '%s' "$VALID_HEADERS" | grep -qi 'x-relay-backend'; then
    pass "X-Relay-Backend header present (proxied response confirmed)"
else
    printf 'WARN: X-Relay-Backend header absent — proxy may still be working; check Worker logs\n' >&2
fi

# ---------------------------------------------------------------------------
# (b) Invalid profile — should return decoy HTML
# ---------------------------------------------------------------------------
printf '\n[2] Invalid-profile request (should return decoy HTML)...\n'

DECOY_STATUS=$(curl -s -o /tmp/lab13-decoy.body -w '%{http_code}' \
    -A "curl/7.88.1" \
    "$TARGET_URL" 2>/dev/null)

if [ "$DECOY_STATUS" != "200" ]; then
    die "Invalid-profile request returned HTTP ${DECOY_STATUS}, expected 200.
  The decoy response must always return 200 to avoid fingerprinting."
fi
pass "invalid-profile request returned HTTP 200"

DECOY_BODY=$(cat /tmp/lab13-decoy.body 2>/dev/null || echo "")
rm -f /tmp/lab13-decoy.body

if ! printf '%s' "$DECOY_BODY" | grep -q 'NetOps Platform'; then
    die "Invalid-profile response body does not contain expected decoy content ('NetOps Platform').
  Check that relay_decoy_html KV key is populated:
    wrangler kv key get --binding RATE_LIMITS --remote relay_decoy_html"
fi
pass "decoy response body contains expected content"

# Also confirm Content-Type is text/html
DECOY_CT=$(curl -sI \
    -A "curl/7.88.1" \
    "$TARGET_URL" 2>/dev/null | grep -i 'content-type' | head -1)
if ! printf '%s' "$DECOY_CT" | grep -qi 'text/html'; then
    printf 'WARN: Content-Type is "%s" — expected text/html for decoy response\n' "$DECOY_CT" >&2
else
    pass "decoy Content-Type is text/html"
fi

# ---------------------------------------------------------------------------
# (c) D1 audit_log has relay_decision rows
# ---------------------------------------------------------------------------
printf '\n[3] Checking D1 audit_log for relay_decision entries...\n'

AUDIT_RESULT=$(wrangler d1 execute fleet-database \
    --remote \
    --command "SELECT action, details FROM audit_log WHERE action='relay_decision' ORDER BY created_at DESC LIMIT 6" \
    --json 2>/dev/null) || \
    die "wrangler d1 execute failed. Check that:
  1. fleet-database D1 is provisioned (Lab 09)
  2. FLEET_DB binding is active in wrangler.toml
  3. You are in the worker/ directory or have wrangler.toml in scope"

# Expect at least 2 rows
ROW_COUNT=$(printf '%s' "$AUDIT_RESULT" | grep -c '"relay_decision"' || echo 0)
if [ "$ROW_COUNT" -lt 2 ]; then
    die "Expected at least 2 relay_decision rows in audit_log, found ${ROW_COUNT}.
  The Worker must log both proxy and decoy decisions.
  Response: $(printf '%s' "$AUDIT_RESULT" | head -c 256)"
fi
pass "audit_log has ${ROW_COUNT} relay_decision rows (minimum 2 required)"

# Verify both proxy and decoy decisions appear. wrangler d1 execute returns
# the audit_log.details column as a JSON-escaped string within an outer JSON
# response, so the embedded `"result":"proxy"` arrives as
# `\"result\":\"proxy\"`. Match the escaped form. With jq we can do the
# unwrap properly.
have_result() {
    target=$1
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$AUDIT_RESULT" \
            | jq -r '.[]?.results[]?.details // empty' 2>/dev/null \
            | jq -r '.result // empty' 2>/dev/null \
            | grep -qx "$target"
    else
        # Match the JSON-escaped substring directly.
        printf '%s' "$AUDIT_RESULT" | grep -q "\\\\\"result\\\\\":\\\\\"$target\\\\\""
    fi
}

if have_result proxy; then
    pass "proxy decision is present in audit_log"
else
    printf 'WARN: no proxy result found in recent relay_decision rows\n' >&2
fi

if have_result decoy; then
    pass "decoy decision is present in audit_log"
else
    printf 'WARN: no decoy result found in recent relay_decision rows\n' >&2
fi

# ---------------------------------------------------------------------------
printf '\nlab13 validation passed.\n'
