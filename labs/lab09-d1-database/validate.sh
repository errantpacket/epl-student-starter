#!/bin/sh
# validate.sh — Lab 09: D1 Device Registry + Audit Log
# Usage: export DOMAIN="<your-domain>"; ./validate.sh
# Requires: curl, jq, wrangler (authenticated)
set -eu

DOMAIN="${DOMAIN:-}"
if [ -z "$DOMAIN" ]; then
    echo "ERROR: DOMAIN is not set. Export it before running this script."
    echo "  export DOMAIN=\"<your-8-char-hex>.eplabs.cloud\""
    exit 1
fi

WORKER_URL="https://api.${DOMAIN}"
DEVICE_ID="validate-lab09-$(date +%s)"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# 1. Enroll a synthetic device
# ---------------------------------------------------------------------------
echo ""
echo "=== 1. Device enrollment ==="

ENROLL_RESPONSE=$(curl -sf \
    -X POST "${WORKER_URL}/v1/devices/enroll" \
    -H "CF-Access-Client-Id: validate-client-id" \
    -H "CF-Access-Client-Secret: validate-client-secret" \
    -H "Content-Type: application/json" \
    -d "{
        \"device_id\": \"${DEVICE_ID}\",
        \"device_type\": \"mango\",
        \"tailscale_hostname\": \"drop-validate.tailnet.ts.net\",
        \"metadata\": { \"lab\": \"09\", \"test\": true }
    }" 2>&1) || {
    fail "POST /v1/devices/enroll failed (curl error or non-2xx response)"
    echo "  Response: ${ENROLL_RESPONSE}"
    echo ""
    echo "SUMMARY: 0 passed, 1 failed"
    exit 1
}

# Check HTTP-level status by re-running with status code capture
ENROLL_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "${WORKER_URL}/v1/devices/enroll" \
    -H "CF-Access-Client-Id: validate-client-id" \
    -H "CF-Access-Client-Secret: validate-client-secret" \
    -H "Content-Type: application/json" \
    -d "{
        \"device_id\": \"${DEVICE_ID}\",
        \"device_type\": \"mango\",
        \"tailscale_hostname\": \"drop-validate.tailnet.ts.net\",
        \"metadata\": { \"lab\": \"09\", \"test\": true }
    }")

if [ "$ENROLL_STATUS" = "200" ]; then
    pass "POST /v1/devices/enroll returned HTTP 200"
else
    fail "POST /v1/devices/enroll returned HTTP ${ENROLL_STATUS} (expected 200)"
fi

ENROLLED=$(echo "$ENROLL_RESPONSE" | jq -r '.enrolled // empty')
if [ "$ENROLLED" = "true" ]; then
    pass "Response contains enrolled: true"
else
    fail "Response missing enrolled: true (got: ${ENROLL_RESPONSE})"
fi

TAG=$(echo "$ENROLL_RESPONSE" | jq -r '.tag // empty')
if echo "$TAG" | grep -q "^device-mango-"; then
    pass "Response tag matches expected prefix 'device-mango-' (got: ${TAG})"
else
    fail "Response tag unexpected (got: ${TAG})"
fi

RETURNED_ID=$(echo "$ENROLL_RESPONSE" | jq -r '.device_id // empty')
if [ "$RETURNED_ID" = "$DEVICE_ID" ]; then
    pass "Response device_id matches submitted device_id"
else
    fail "Response device_id mismatch: expected '${DEVICE_ID}', got '${RETURNED_ID}'"
fi

# ---------------------------------------------------------------------------
# 2. Re-enroll the same device (idempotency / upsert check)
# ---------------------------------------------------------------------------
echo ""
echo "=== 2. Re-enrollment idempotency ==="

curl -sf \
    -X POST "${WORKER_URL}/v1/devices/enroll" \
    -H "CF-Access-Client-Id: validate-client-id" \
    -H "CF-Access-Client-Secret: validate-client-secret" \
    -H "Content-Type: application/json" \
    -d "{
        \"device_id\": \"${DEVICE_ID}\",
        \"device_type\": \"mango\",
        \"tailscale_hostname\": \"drop-validate-v2.tailnet.ts.net\",
        \"metadata\": { \"lab\": \"09\", \"test\": true, \"reenroll\": true }
    }" > /dev/null

# Query D1 directly to confirm only one row exists
DEVICE_COUNT=$(wrangler d1 execute fleet-database \
    --command="SELECT COUNT(*) AS cnt FROM devices WHERE device_id='${DEVICE_ID}';" \
    --remote --json 2>/dev/null | jq -r '.[0].results[0].cnt // .[0].cnt // empty' 2>/dev/null || echo "")

if [ "$DEVICE_COUNT" = "1" ]; then
    pass "D1 devices table has exactly 1 row for device_id (upsert works)"
else
    fail "D1 devices table row count for device_id: expected 1, got '${DEVICE_COUNT}'"
fi

# ---------------------------------------------------------------------------
# 3. Device list returns the enrolled device
# ---------------------------------------------------------------------------
echo ""
echo "=== 3. Device list ==="

# Obtain a CF Access token if wrangler access token is available
ACCESS_TOKEN=$(wrangler access token "https://api.${DOMAIN}" 2>/dev/null || echo "")

if [ -z "$ACCESS_TOKEN" ]; then
    echo "  SKIP: Could not obtain CF Access JWT via wrangler (not logged in via Access?)."
    echo "        Run: wrangler access token https://api.${DOMAIN}"
    echo "        Then re-export ACCESS_TOKEN and curl manually:"
    echo "        curl -H \"CF-Access-Jwt-Assertion: \$TOKEN\" ${WORKER_URL}/v1/devices"
else
    DEVICE_LIST=$(curl -sf \
        -H "CF-Access-Jwt-Assertion: ${ACCESS_TOKEN}" \
        "${WORKER_URL}/v1/devices" 2>&1) || {
        fail "GET /v1/devices failed"
        DEVICE_LIST=""
    }

    if [ -n "$DEVICE_LIST" ]; then
        LIST_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
            -H "CF-Access-Jwt-Assertion: ${ACCESS_TOKEN}" \
            "${WORKER_URL}/v1/devices")

        if [ "$LIST_STATUS" = "200" ]; then
            pass "GET /v1/devices returned HTTP 200"
        else
            fail "GET /v1/devices returned HTTP ${LIST_STATUS} (expected 200)"
        fi

        DEVICE_IN_LIST=$(echo "$DEVICE_LIST" | \
            jq -r --arg id "$DEVICE_ID" \
            '[.[] | select(.device_id == $id)] | length' 2>/dev/null || echo "0")

        if [ "$DEVICE_IN_LIST" = "1" ]; then
            pass "Enrolled device appears in /v1/devices response"
        else
            fail "Enrolled device NOT found in /v1/devices response"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 4. Audit log via D1 direct query
# ---------------------------------------------------------------------------
echo ""
echo "=== 4. Audit log ==="

AUDIT_COUNT=$(wrangler d1 execute fleet-database \
    --command="SELECT COUNT(*) AS cnt FROM audit_log WHERE device_id='${DEVICE_ID}' AND action='enroll';" \
    --remote --json 2>/dev/null | jq -r '.[0].results[0].cnt // .[0].cnt // empty' 2>/dev/null || echo "")

if [ -n "$AUDIT_COUNT" ] && [ "$AUDIT_COUNT" -ge "2" ] 2>/dev/null; then
    pass "audit_log has ${AUDIT_COUNT} enroll rows for this device (2 enrollments = 2 rows)"
elif [ -n "$AUDIT_COUNT" ] && [ "$AUDIT_COUNT" -ge "1" ] 2>/dev/null; then
    pass "audit_log has at least 1 enroll row for device_id"
else
    fail "audit_log enroll rows for device_id: expected >= 1, got '${AUDIT_COUNT}'"
fi

# ---------------------------------------------------------------------------
# 5. Verify schema tables exist
# ---------------------------------------------------------------------------
echo ""
echo "=== 5. Schema integrity ==="

TABLES=$(wrangler d1 execute fleet-database \
    --command="SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;" \
    --remote --json 2>/dev/null | jq -r '.[0].results[].name' 2>/dev/null | sort | tr '\n' ' ')

for table in audit_log devices sessions; do
    if echo "$TABLES" | grep -q "$table"; then
        pass "Table '${table}' exists in fleet-database"
    else
        fail "Table '${table}' NOT found in fleet-database (got: ${TABLES})"
    fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== SUMMARY ==="
echo "  Passed: ${PASS}"
echo "  Failed: ${FAIL}"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo "Lab 09 validation FAILED. Address the failures above and re-run."
    exit 1
else
    echo "Lab 09 validation PASSED."
    exit 0
fi
