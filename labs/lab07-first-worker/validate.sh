#!/bin/sh
# validate.sh — Lab 07: First Worker Deployment
# Usage: export DOMAIN=<your-domain> && ./validate.sh
# Exits 0 on success, prints first failing assertion and exits 1 on failure.
set -eu

DOMAIN="${DOMAIN:-}"

if [ -z "${DOMAIN}" ]; then
    echo "FAIL: DOMAIN environment variable is not set."
    echo "      Run: export DOMAIN=<your-domain>  (e.g. a00f3f13.eplabs.cloud)"
    exit 1
fi

HEALTH_URL="https://api.${DOMAIN}/v1/health"

echo "Validating Lab 07 — First Worker Deployment"
echo "Domain: ${DOMAIN}"
echo "Health URL: ${HEALTH_URL}"
echo ""

# --- Assertion 1: HTTP 200 from /v1/health ---
echo "[1/4] Checking HTTP 200 from ${HEALTH_URL} ..."
HTTP_CODE=$(curl -s -o /tmp/lab07_health_body.json -w "%{http_code}" \
    --max-time 15 \
    "${HEALTH_URL}")

if [ "${HTTP_CODE}" != "200" ]; then
    echo "FAIL: Expected HTTP 200 from ${HEALTH_URL}, got ${HTTP_CODE}"
    echo "      If the Worker is not yet deployed, run: cd worker && npx wrangler deploy"
    exit 1
fi
echo "      OK: HTTP ${HTTP_CODE}"

# --- Assertion 2: Response body contains ok=true ---
echo "[2/4] Checking response body contains ok:true ..."
OK_VAL=$(cat /tmp/lab07_health_body.json | grep -o '"ok":[^,}]*' | head -1 | sed 's/"ok"://')
if [ "${OK_VAL}" != "true" ]; then
    echo "FAIL: Response body does not contain \"ok\":true"
    echo "      Response was:"
    cat /tmp/lab07_health_body.json
    echo ""
    exit 1
fi
echo "      OK: ok=true"

# --- Assertion 3: Response body contains version field ---
echo "[3/4] Checking response body contains version field ..."
VERSION_VAL=$(cat /tmp/lab07_health_body.json | grep -o '"version":"[^"]*"' | head -1)
if [ -z "${VERSION_VAL}" ]; then
    echo "FAIL: Response body missing \"version\" field"
    echo "      Response was:"
    cat /tmp/lab07_health_body.json
    echo ""
    exit 1
fi
echo "      OK: ${VERSION_VAL}"

# --- Assertion 4: Response body contains timestamp field ---
echo "[4/4] Checking response body contains timestamp field ..."
TIMESTAMP_VAL=$(cat /tmp/lab07_health_body.json | grep -o '"timestamp":"[^"]*"' | head -1)
if [ -z "${TIMESTAMP_VAL}" ]; then
    echo "FAIL: Response body missing \"timestamp\" field"
    echo "      Response was:"
    cat /tmp/lab07_health_body.json
    echo ""
    exit 1
fi
echo "      OK: ${TIMESTAMP_VAL}"

echo ""
echo "PASS: Lab 07 validation complete."
echo "      Worker is deployed and /v1/health returns correct JSON shape."
rm -f /tmp/lab07_health_body.json
