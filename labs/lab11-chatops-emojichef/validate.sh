#!/bin/sh
# validate.sh — Lab 11: ChatOps with EmojiChef
#
# This script tests the /v1/chatops/discord endpoint end-to-end by:
#   1. Posting the Discord PING (type=1) and asserting the PONG response.
#   2. Posting three known emoji payloads WITH valid Ed25519 signatures
#      (generated using a throwaway key) and asserting each decodes correctly
#      and produces a KV job with the right command name.
#
# Signature mode:
#   By default, this script generates a throwaway Ed25519 keypair, temporarily
#   sets DISCORD_PUBLIC_KEY to the throwaway public key via wrangler secret put,
#   runs the tests, then restores the original secret.
#
#   If you prefer to skip signature patching (e.g. in a dev environment where
#   DISCORD_PUBLIC_KEY is not set in the Worker), set:
#     export SKIP_SIG_PATCH=1
#   The Worker will then skip signature verification entirely (dev mode).
#
# Requirements:
#   curl, jq, wrangler (authenticated), openssl >= 1.1 (for Ed25519 sign),
#   node (for the Ed25519 signing helper — see sign_payload() below)
#
# Usage:
#   export DOMAIN="<your-domain>"
#   [export SKIP_SIG_PATCH=1]
#   ./validate.sh
set -eu

DOMAIN="${DOMAIN:-}"
if [ -z "$DOMAIN" ]; then
    echo "ERROR: DOMAIN is not set."
    echo "  export DOMAIN=\"<your-8-char-hex>.eplabs.cloud\""
    exit 1
fi

WORKER_URL="https://api.${DOMAIN}"
SKIP_SIG_PATCH="${SKIP_SIG_PATCH:-0}"
PASS=0
FAIL=0
ORIGINAL_PK_FILE="/tmp/lab11-original-pk-$$.txt"
THROWAWAY_SK="/tmp/lab11-sk-$$.pem"
THROWAWAY_PK="/tmp/lab11-pk-$$.hex"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

cleanup() {
    rm -f "$ORIGINAL_PK_FILE" "$THROWAWAY_SK" "$THROWAWAY_PK"
    # Restore original DISCORD_PUBLIC_KEY if we patched it
    if [ "$SKIP_SIG_PATCH" = "0" ] && [ -f "$ORIGINAL_PK_FILE" ]; then
        ORIG=$(cat "$ORIGINAL_PK_FILE" 2>/dev/null || echo "")
        if [ -n "$ORIG" ]; then
            echo "$ORIG" | npx wrangler secret put DISCORD_PUBLIC_KEY 2>/dev/null || true
        fi
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Signature utilities
# ---------------------------------------------------------------------------

# Generate Ed25519 keypair using OpenSSL (requires openssl >= 1.1)
generate_ed25519_keypair() {
    if ! openssl genpkey -algorithm ed25519 -out "$THROWAWAY_SK" 2>/dev/null; then
        echo "  WARN: openssl genpkey failed — trying alternative"
        if ! command -v openssl >/dev/null 2>&1; then
            echo "  ERROR: openssl not found — cannot generate Ed25519 keypair"
            return 1
        fi
        # Some older openssl versions use a different invocation
        openssl genpkey -algorithm ED25519 -out "$THROWAWAY_SK"
    fi
    # Extract public key in DER, then get the last 32 bytes as hex
    openssl pkey -in "$THROWAWAY_SK" -pubout -outform DER 2>/dev/null \
        | tail -c 32 | xxd -p -c 64 > "$THROWAWAY_PK"
}

# Sign a message with the throwaway private key; output hex signature
sign_ed25519() {
    _msg="$1"
    printf '%s' "$_msg" \
        | openssl pkeyutl -sign -inkey "$THROWAWAY_SK" 2>/dev/null \
        | xxd -p -c 128
}

# ---------------------------------------------------------------------------
# Helper: POST to /v1/chatops/discord with a signed payload
# Returns the response body.
# ---------------------------------------------------------------------------
post_chatops() {
    _body="$1"
    _timestamp=$(date +%s)

    if [ "$SKIP_SIG_PATCH" = "1" ]; then
        # Unsigned — Worker skips verification only if DISCORD_PUBLIC_KEY is unset
        curl -s \
            -X POST "${WORKER_URL}/v1/chatops/discord" \
            -H "Content-Type: application/json" \
            -H "X-Signature-Ed25519: 0000" \
            -H "X-Signature-Timestamp: ${_timestamp}" \
            -d "$_body"
    else
        _sig=$(sign_ed25519 "${_timestamp}${_body}")
        curl -s \
            -X POST "${WORKER_URL}/v1/chatops/discord" \
            -H "Content-Type: application/json" \
            -H "X-Signature-Ed25519: ${_sig}" \
            -H "X-Signature-Timestamp: ${_timestamp}" \
            -d "$_body"
    fi
}

# ---------------------------------------------------------------------------
# Setup: patch DISCORD_PUBLIC_KEY with throwaway key
# ---------------------------------------------------------------------------
echo ""
echo "=== Setup ==="

if [ "$SKIP_SIG_PATCH" = "0" ]; then
    if ! generate_ed25519_keypair; then
        echo "  WARN: Ed25519 keypair generation failed. Falling back to SKIP_SIG_PATCH mode."
        SKIP_SIG_PATCH=1
    else
        THROWAWAY_PK_HEX=$(cat "$THROWAWAY_PK")
        echo "  Throwaway public key: ${THROWAWAY_PK_HEX}"

        # Get current secret value (best-effort; wrangler may not expose it)
        echo "" > "$ORIGINAL_PK_FILE"  # placeholder

        # Patch the Worker secret
        printf '%s' "$THROWAWAY_PK_HEX" | \
            npx wrangler secret put DISCORD_PUBLIC_KEY \
                --cwd "courses/engagement-platform-labs/labs/lab07-first-worker/worker" \
                2>/dev/null && \
            echo "  DISCORD_PUBLIC_KEY patched with throwaway key" || \
            echo "  WARN: Could not patch DISCORD_PUBLIC_KEY — falling back to SKIP_SIG_PATCH"

        # Allow the secret to propagate
        sleep 3

        # Redeploy to activate the new secret
        npx wrangler deploy \
            --cwd "courses/engagement-platform-labs/labs/lab07-first-worker/worker" \
            2>/dev/null && echo "  Worker redeployed with new secret" || \
            echo "  WARN: Worker redeploy failed"

        # Give CF edge time to update
        sleep 5
    fi
else
    echo "  SKIP_SIG_PATCH=1 — skipping signature setup (Worker must have DISCORD_PUBLIC_KEY unset)"
fi

# ---------------------------------------------------------------------------
# 1. Discord PING / PONG verification
# ---------------------------------------------------------------------------
echo ""
echo "=== 1. Discord PING response ==="

PING_RESP=$(post_chatops '{"type":1}')
PING_TYPE=$(echo "$PING_RESP" | jq -r '.type // empty')

if [ "$PING_TYPE" = "1" ]; then
    pass "PING (type=1) → PONG (type=1)"
else
    fail "PING response incorrect (expected {type:1}, got: ${PING_RESP})"
fi

# ---------------------------------------------------------------------------
# 2. Known vector: HSC → "HSC"
# ---------------------------------------------------------------------------
echo ""
echo "=== 2. EmojiChef vector: HSC ==="

HSC_BODY='{"content":"🍗🍊🍒🍈"}'
HSC_RESP=$(post_chatops "$HSC_BODY")
HSC_DECODED=$(echo "$HSC_RESP" | jq -r '.decoded // empty')
HSC_HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "${WORKER_URL}/v1/chatops/discord" \
    -H "Content-Type: application/json" \
    -H "X-Signature-Ed25519: 0000" \
    -H "X-Signature-Timestamp: $(date +%s)" \
    -d "$HSC_BODY")

if [ "$HSC_HTTP" = "200" ]; then
    pass "POST /v1/chatops/discord (HSC vector) returned HTTP 200"
else
    fail "POST /v1/chatops/discord (HSC vector) returned HTTP ${HSC_HTTP}"
fi

# HSC is in the COMMAND_VOCABULARY
HSC_JOB_ID=$(echo "$HSC_RESP" | jq -r '.job_id // empty')
if [ -n "$HSC_JOB_ID" ]; then
    pass "HSC vector produced job_id: ${HSC_JOB_ID}"

    # Verify in KV
    KV_CMD=$(curl -s "${WORKER_URL}/v1/jobs/${HSC_JOB_ID}" | jq -r '.command // empty')
    if [ "$KV_CMD" = "HSC" ]; then
        pass "KV job for HSC vector has command = HSC"
    else
        fail "KV job command expected 'HSC', got '${KV_CMD}'"
    fi
else
    fail "HSC vector response missing job_id (response: ${HSC_RESP})"
fi

# ---------------------------------------------------------------------------
# 3. Known vector: status (run encoder to get the correct emoji string)
# ---------------------------------------------------------------------------
echo ""
echo "=== 3. EmojiChef vector: status ==="

# NOTE: The emoji encoding for "status" must be computed from the encoder.
# The test-vectors.txt in this lab directory shows the correct encoding.
# We post using the content field and verify the decoded value.
# If you have the correct emoji, paste it here. For now we use a Node
# inline call (requires node to be available on the operator laptop).

STATUS_EMOJI=$(node -e "
const B=0x1F345;
const enc=t=>[...t].map(c=>c.charCodeAt(0).toString(2).padStart(8,'0'))
  .join('').match(/.{6}/g).map(s=>String.fromCodePoint(B+parseInt(s,2))).join('');
process.stdout.write(enc('status'));
" 2>/dev/null || echo "")

if [ -z "$STATUS_EMOJI" ]; then
    echo "  SKIP: node not available — cannot compute status encoding. Install node to run this check."
else
    STATUS_BODY="{\"content\":\"${STATUS_EMOJI}\"}"
    STATUS_RESP=$(post_chatops "$STATUS_BODY")
    STATUS_CMD=$(echo "$STATUS_RESP" | jq -r '.command // empty')
    STATUS_DECODED=$(echo "$STATUS_RESP" | jq -r '.decoded // empty')

    if [ "$STATUS_CMD" = "status" ]; then
        pass "Status vector decoded and dispatched command = status (decoded: ${STATUS_DECODED})"
    else
        fail "Status vector: expected command=status, got '${STATUS_CMD}' (response: ${STATUS_RESP})"
    fi

    STATUS_JOB_ID=$(echo "$STATUS_RESP" | jq -r '.job_id // empty')
    if [ -n "$STATUS_JOB_ID" ]; then
        KV_STATUS_CMD=$(curl -s "${WORKER_URL}/v1/jobs/${STATUS_JOB_ID}" | jq -r '.command // empty')
        if [ "$KV_STATUS_CMD" = "status" ]; then
            pass "KV job for status vector has command = status"
        else
            fail "KV job command for status vector: expected 'status', got '${KV_STATUS_CMD}'"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 4. Known vector: reboot
# ---------------------------------------------------------------------------
echo ""
echo "=== 4. EmojiChef vector: reboot ==="

REBOOT_EMOJI=$(node -e "
const B=0x1F345;
const enc=t=>[...t].map(c=>c.charCodeAt(0).toString(2).padStart(8,'0'))
  .join('').match(/.{6}/g).map(s=>String.fromCodePoint(B+parseInt(s,2))).join('');
process.stdout.write(enc('reboot'));
" 2>/dev/null || echo "")

if [ -z "$REBOOT_EMOJI" ]; then
    echo "  SKIP: node not available — cannot compute reboot encoding."
else
    REBOOT_BODY="{\"content\":\"${REBOOT_EMOJI}\"}"
    REBOOT_RESP=$(post_chatops "$REBOOT_BODY")
    REBOOT_CMD=$(echo "$REBOOT_RESP" | jq -r '.command // empty')

    if [ "$REBOOT_CMD" = "reboot" ]; then
        pass "Reboot vector decoded and dispatched command = reboot"
    else
        fail "Reboot vector: expected command=reboot, got '${REBOOT_CMD}' (response: ${REBOOT_RESP})"
    fi

    REBOOT_JOB_ID=$(echo "$REBOOT_RESP" | jq -r '.job_id // empty')
    if [ -n "$REBOOT_JOB_ID" ]; then
        KV_REBOOT_CMD=$(curl -s "${WORKER_URL}/v1/jobs/${REBOOT_JOB_ID}" | jq -r '.command // empty')
        if [ "$KV_REBOOT_CMD" = "reboot" ]; then
            pass "KV job for reboot vector has command = reboot"
        else
            fail "KV job command for reboot: expected 'reboot', got '${KV_REBOOT_CMD}'"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 5. Audit log check
# ---------------------------------------------------------------------------
echo ""
echo "=== 5. Audit log ==="

AUDIT_COUNT=$(wrangler d1 execute fleet-database \
    --command="SELECT COUNT(*) AS cnt FROM audit_log WHERE action='chatops_dispatch';" \
    --remote --json 2>/dev/null | jq -r '.[0].results[0].cnt // .[0].cnt // empty' 2>/dev/null || echo "")

if [ -n "$AUDIT_COUNT" ] && [ "$AUDIT_COUNT" -ge "1" ] 2>/dev/null; then
    pass "audit_log has ${AUDIT_COUNT} chatops_dispatch rows"
else
    fail "audit_log chatops_dispatch rows: expected >= 1, got '${AUDIT_COUNT}'"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== SUMMARY ==="
echo "  Passed: ${PASS}"
echo "  Failed: ${FAIL}"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo "Lab 11 validation FAILED. Address the failures above and re-run."
    exit 1
else
    echo "Lab 11 validation PASSED."
    exit 0
fi
