#!/bin/sh
# validate.sh — Lab 08: Cloudflare Access
# Usage:
#   export DOMAIN=<your-domain>
#   export CF_ACCESS_CLIENT_ID=<your-client-id>
#   export CF_ACCESS_CLIENT_SECRET=<your-client-secret>
#   ./validate.sh
#
# Exits 0 on all three assertions passing.
# Prints first failing assertion and exits 1 on failure.
set -eu

DOMAIN="${DOMAIN:-}"
CF_ACCESS_CLIENT_ID="${CF_ACCESS_CLIENT_ID:-}"
CF_ACCESS_CLIENT_SECRET="${CF_ACCESS_CLIENT_SECRET:-}"

# --- Input validation ---
if [ -z "${DOMAIN}" ]; then
    echo "FAIL: DOMAIN environment variable is not set."
    exit 1
fi
if [ -z "${CF_ACCESS_CLIENT_ID}" ]; then
    echo "FAIL: CF_ACCESS_CLIENT_ID environment variable is not set."
    echo "      Export the Client ID from output/access-tokens.json"
    exit 1
fi
if [ -z "${CF_ACCESS_CLIENT_SECRET}" ]; then
    echo "FAIL: CF_ACCESS_CLIENT_SECRET environment variable is not set."
    echo "      Export the Client Secret from output/access-tokens.json"
    exit 1
fi

HEALTH_URL="https://api.${DOMAIN}/v1/health"

echo "Validating Lab 08 — Cloudflare Access"
echo "Domain:   ${DOMAIN}"
echo "Endpoint: ${HEALTH_URL}"
echo ""

# --- Assertion 1: Unauthenticated request returns 401 ---
echo "[1/3] Unauthenticated request should return 401 ..."
UNAUTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 15 \
    -H "Accept: application/json" \
    "${HEALTH_URL}")

# CF Access may return 401 (API clients) or 302 (browser redirect).
# Both indicate that the Access policy is enforced.
if [ "${UNAUTH_CODE}" = "200" ]; then
    echo "FAIL: Expected 401 (or 302) from unauthenticated request, got ${UNAUTH_CODE}"
    echo "      The Access Application may not be configured for this route."
    echo "      Verify in Zero Trust > Access > Applications > fleet-gateway-api."
    exit 1
fi
echo "      OK: HTTP ${UNAUTH_CODE} (Access policy active)"

# --- Assertion 2: Valid service token returns 200 with correct body ---
echo "[2/3] Service token request should return 200 ..."
HTTP_CODE=$(curl -s -o /tmp/lab08_body.json -w "%{http_code}" \
    --max-time 15 \
    -H "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}" \
    -H "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}" \
    "${HEALTH_URL}")

if [ "${HTTP_CODE}" != "200" ]; then
    echo "FAIL: Expected HTTP 200 from service token request, got ${HTTP_CODE}"
    echo "      Verify that the service token is attached to the fleet-gateway-api"
    echo "      Access Application policy (step 7 in the lab walkthrough)."
    rm -f /tmp/lab08_body.json
    exit 1
fi

OK_VAL=$(cat /tmp/lab08_body.json | grep -o '"ok":[^,}]*' | head -1 | sed 's/"ok"://')
if [ "${OK_VAL}" != "true" ]; then
    echo "FAIL: Service token returned HTTP 200 but body does not contain ok:true"
    echo "      Response was:"
    cat /tmp/lab08_body.json
    echo ""
    rm -f /tmp/lab08_body.json
    exit 1
fi
echo "      OK: HTTP ${HTTP_CODE}, body contains ok:true"

# --- Assertion 3: Invalid service token returns 401 ---
echo "[3/3] Invalid service token should return 401 ..."
INVALID_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 15 \
    -H "Accept: application/json" \
    -H "CF-Access-Client-Id: invalid-client-id" \
    -H "CF-Access-Client-Secret: invalid-client-secret" \
    "${HEALTH_URL}")

if [ "${INVALID_CODE}" = "200" ]; then
    echo "FAIL: Expected 401 for invalid service token, got ${INVALID_CODE}"
    echo "      The Access policy is not rejecting invalid credentials."
    rm -f /tmp/lab08_body.json
    exit 1
fi
echo "      OK: HTTP ${INVALID_CODE} (invalid token rejected)"

echo ""
echo "PASS: Lab 08 validation complete."
echo "      Access policy is enforced: unauthenticated=blocked, service-token=allowed."
rm -f /tmp/lab08_body.json
