#!/bin/sh
# validate.sh — Lab 10: KV + R2 Storage
# Usage: export DOMAIN="<your-domain>"; ./validate.sh
# Requires: curl, jq, sha256sum (or shasum -a 256 on macOS), wrangler
set -eu

DOMAIN="${DOMAIN:-}"
if [ -z "$DOMAIN" ]; then
    echo "ERROR: DOMAIN is not set. Export it before running this script."
    echo "  export DOMAIN=\"<your-8-char-hex>.eplabs.cloud\""
    exit 1
fi

# CF Access service-token credentials are required when Lab 08 is in front of
# the Worker (every Worker route under /v1/* is gated). Earlier versions of
# this script sent unauthenticated requests, which 403 against a real Access
# app — see delivery-notes §11.9 (Lab 10 walk).
CF_ACCESS_CLIENT_ID="${CF_ACCESS_CLIENT_ID:-}"
CF_ACCESS_CLIENT_SECRET="${CF_ACCESS_CLIENT_SECRET:-}"
if [ -z "$CF_ACCESS_CLIENT_ID" ] || [ -z "$CF_ACCESS_CLIENT_SECRET" ]; then
    echo "ERROR: CF_ACCESS_CLIENT_ID / CF_ACCESS_CLIENT_SECRET not set."
    echo "  Export the service-token credentials minted in Lab 08:"
    echo "    export CF_ACCESS_CLIENT_ID=<...>"
    echo "    export CF_ACCESS_CLIENT_SECRET=<...>"
    exit 1
fi
ACCESS_HEADERS="-H CF-Access-Client-Id:${CF_ACCESS_CLIENT_ID} -H CF-Access-Client-Secret:${CF_ACCESS_CLIENT_SECRET}"

WORKER_URL="https://api.${DOMAIN}"

WRANGLER="${WRANGLER:-npx --no-install wrangler}"
FIXTURE_DATA="lab10-validate-fixture-$(date +%s)"
FIXTURE_FILE="/tmp/lab10-fixture-$$.bin"
RETRIEVED_FILE="/tmp/lab10-retrieved-$$.bin"
PASS=0
FAIL=0

# Portable sha256sum (Linux: sha256sum, macOS: shasum -a 256)
sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        echo "ERROR: neither sha256sum nor shasum found" >&2
        exit 1
    fi
}

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

cleanup() {
    rm -f "$FIXTURE_FILE" "$RETRIEVED_FILE"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. Enqueue a command
# ---------------------------------------------------------------------------
echo ""
echo "=== 1. Command enqueue ==="

DEVICE_ID="validate-lab10-device"

ENQUEUE_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "${WORKER_URL}/v1/commands/${DEVICE_ID}" \
    -H "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}" \
    -H "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}" \
    -H "Content-Type: application/json" \
    -d '{"command": "status", "timeout": 60}')

if [ "$ENQUEUE_STATUS" = "200" ]; then
    pass "POST /v1/commands/${DEVICE_ID} returned HTTP 200"
else
    fail "POST /v1/commands/${DEVICE_ID} returned HTTP ${ENQUEUE_STATUS} (expected 200)"
fi

ENQUEUE_RESP=$(curl -s \
    -X POST "${WORKER_URL}/v1/commands/${DEVICE_ID}" \
    -H "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}" \
    -H "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}" \
    -H "Content-Type: application/json" \
    -d '{"command": "status", "timeout": 60}')

JOB_ID=$(echo "$ENQUEUE_RESP" | jq -r '.job_id // empty')
if [ -n "$JOB_ID" ]; then
    pass "Response contains job_id: ${JOB_ID}"
else
    fail "Response missing job_id (got: ${ENQUEUE_RESP})"
    JOB_ID="missing"
fi

JOB_STATUS_FIELD=$(echo "$ENQUEUE_RESP" | jq -r '.status // empty')
if [ "$JOB_STATUS_FIELD" = "queued" ]; then
    pass "Response status = queued"
else
    fail "Response status expected 'queued', got '${JOB_STATUS_FIELD}'"
fi

# ---------------------------------------------------------------------------
# 2. Read job from KV via /v1/jobs/<id>
# ---------------------------------------------------------------------------
echo ""
echo "=== 2. Job status read-back ==="

if [ "$JOB_ID" != "missing" ]; then
    JOB_STATUS_HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}" \
        -H "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}" \
        "${WORKER_URL}/v1/jobs/${JOB_ID}")

    if [ "$JOB_STATUS_HTTP" = "200" ]; then
        pass "GET /v1/jobs/${JOB_ID} returned HTTP 200"
    else
        fail "GET /v1/jobs/${JOB_ID} returned HTTP ${JOB_STATUS_HTTP} (expected 200)"
    fi

    JOB_RESP=$(curl -s \
        -H "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}" \
        -H "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}" \
        "${WORKER_URL}/v1/jobs/${JOB_ID}")
    KV_STATUS=$(echo "$JOB_RESP" | jq -r '.status // empty')
    KV_COMMAND=$(echo "$JOB_RESP" | jq -r '.command // empty')

    if [ "$KV_STATUS" = "queued" ]; then
        pass "KV job object has status = queued"
    else
        fail "KV job object status expected 'queued', got '${KV_STATUS}'"
    fi

    if [ "$KV_COMMAND" = "status" ]; then
        pass "KV job object has command = status"
    else
        fail "KV job object command expected 'status', got '${KV_COMMAND}'"
    fi
else
    fail "Skipping job read-back — no job_id available"
fi

# ---------------------------------------------------------------------------
# 3. Artifact upload via signed PUT URL
# ---------------------------------------------------------------------------
echo ""
echo "=== 3. Artifact upload (signed PUT URL) ==="

UPLOAD_RESP=$(curl -s \
    -X POST "${WORKER_URL}/v1/artifacts/upload" \
    -H "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}" \
    -H "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}" \
    -H "Content-Type: application/json" \
    -d '{"content_type": "application/octet-stream"}')

UPLOAD_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "${WORKER_URL}/v1/artifacts/upload" \
    -H "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}" \
    -H "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}" \
    -H "Content-Type: application/json" \
    -d '{"content_type": "application/octet-stream"}')

if [ "$UPLOAD_STATUS" = "200" ]; then
    pass "POST /v1/artifacts/upload returned HTTP 200"
else
    fail "POST /v1/artifacts/upload returned HTTP ${UPLOAD_STATUS} (expected 200)"
fi

ARTIFACT_ID=$(echo "$UPLOAD_RESP" | jq -r '.artifact_id // empty')
UPLOAD_URL=$(echo "$UPLOAD_RESP" | jq -r '.upload_url // empty')

if [ -n "$ARTIFACT_ID" ] && [ -n "$UPLOAD_URL" ]; then
    pass "Upload response contains artifact_id and upload_url"
else
    fail "Upload response missing artifact_id or upload_url (got: ${UPLOAD_RESP})"
    ARTIFACT_ID="missing"
    UPLOAD_URL=""
fi

if [ -n "$UPLOAD_URL" ]; then
    # Create deterministic fixture
    printf '%s\n' "$FIXTURE_DATA" > "$FIXTURE_FILE"
    ORIGINAL_SHA=$(sha256 "$FIXTURE_FILE")

    # Worker-proxy mode: upload_url points back at the same Worker; same
    # CF Access service-token gate applies.
    PUT_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
        -X PUT "$UPLOAD_URL" \
        -H "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}" \
        -H "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}" \
        -H "Content-Type: application/octet-stream" \
        --data-binary @"$FIXTURE_FILE")

    if [ "$PUT_STATUS" = "200" ]; then
        pass "PUT to upload_url returned HTTP 200"
    else
        fail "PUT to upload_url returned HTTP ${PUT_STATUS} (expected 200)"
        ARTIFACT_ID="missing"
    fi
fi

# ---------------------------------------------------------------------------
# 4. Artifact download via signed GET URL and SHA verification
# ---------------------------------------------------------------------------
echo ""
echo "=== 4. Artifact download (signed GET URL + SHA check) ==="

if [ "$ARTIFACT_ID" != "missing" ] && [ -n "$ARTIFACT_ID" ]; then
    # Brief pause — R2 object may need a moment to become consistent
    sleep 2

    DOWNLOAD_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}" \
        -H "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}" \
        "${WORKER_URL}/v1/artifacts/${ARTIFACT_ID}")

    if [ "$DOWNLOAD_STATUS" = "200" ]; then
        pass "GET /v1/artifacts/${ARTIFACT_ID} returned HTTP 200"
    else
        fail "GET /v1/artifacts/${ARTIFACT_ID} returned HTTP ${DOWNLOAD_STATUS} (expected 200)"
    fi

    DOWNLOAD_RESP=$(curl -s \
        -H "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}" \
        -H "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}" \
        "${WORKER_URL}/v1/artifacts/${ARTIFACT_ID}")
    DOWNLOAD_URL=$(echo "$DOWNLOAD_RESP" | jq -r '.download_url // empty')

    if [ -n "$DOWNLOAD_URL" ]; then
        pass "Download response contains download_url"

        # Worker-proxy mode: download_url points back at the Worker; same
        # CF Access service-token gate applies.
        curl -sf \
            -H "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}" \
            -H "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}" \
            "$DOWNLOAD_URL" -o "$RETRIEVED_FILE" 2>/dev/null || {
            fail "Download from download_url failed"
            DOWNLOAD_URL=""
        }

        if [ -n "$DOWNLOAD_URL" ] && [ -f "$RETRIEVED_FILE" ]; then
            RETRIEVED_SHA=$(sha256 "$RETRIEVED_FILE")
            if [ "$ORIGINAL_SHA" = "$RETRIEVED_SHA" ]; then
                pass "SHA256 match — artifact round-trip verified (${ORIGINAL_SHA})"
            else
                fail "SHA256 mismatch: original=${ORIGINAL_SHA}, retrieved=${RETRIEVED_SHA}"
            fi
        fi
    else
        fail "Download response missing download_url (got: ${DOWNLOAD_RESP})"
    fi
else
    fail "Skipping artifact download — no artifact_id available (upload likely failed)"
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
    echo "Lab 10 validation FAILED. Address the failures above and re-run."
    exit 1
else
    echo "Lab 10 validation PASSED."
    exit 0
fi
