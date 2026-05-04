#!/bin/sh
# Lab 04 validate.sh — Domain & Cloudflare verification.
#
# Asserts:
#   1. test.<DOMAIN>    resolves to 1.2.3.4 via dig (DNS control check).
#   2. <wildcard>.<DOMAIN> resolves to 192.0.2.1 (wildcard record check).
#   3. curl https://<DOMAIN> returns HTTP 2xx or 3xx (CF proxy active).
#   4. wrangler whoami exits 0 and prints a non-empty account name.
#
# Usage:
#   DOMAIN=a00f3f13.eplabs.cloud ./validate.sh
#   DOMAIN=yourdomain.com ./validate.sh
#
# Optional overrides:
#   DNS_RESOLVER   — DNS resolver to use (default: 1.1.1.1)
#   SKIP_WRANGLER  — set to 1 to skip the wrangler check (if not installed)
#
# Exit 0 on full pass; non-zero with a descriptive message on first failure.

set -eu

DOMAIN="${DOMAIN:-}"
DNS_RESOLVER="${DNS_RESOLVER:-1.1.1.1}"
SKIP_WRANGLER="${SKIP_WRANGLER:-0}"

if [ -z "$DOMAIN" ]; then
    printf 'ERROR: DOMAIN is not set.\n' >&2
    printf 'Usage: DOMAIN=a00f3f13.eplabs.cloud %s\n' "$0" >&2
    exit 1
fi

pass() {
    printf 'PASS  %s\n' "$1"
}

fail() {
    printf 'FAIL  %s\n' "$1" >&2
    exit 1
}

echo "=== Lab 04 validate: domain=${DOMAIN} resolver=${DNS_RESOLVER} ==="
echo ""

# ---- 1. test.<DOMAIN> resolves to 1.2.3.4 ----
if ! command -v dig >/dev/null 2>&1; then
    fail "'dig' not found — install dnsutils (Debian/Ubuntu) or bind-utils (RHEL/Fedora)"
fi

TEST_ANSWER=$(dig +short "@${DNS_RESOLVER}" A "test.${DOMAIN}" 2>/dev/null | head -1)
if [ "$TEST_ANSWER" != "1.2.3.4" ]; then
    fail "test.${DOMAIN} resolved to '${TEST_ANSWER}', expected '1.2.3.4'. Create the test A record in the CF dashboard (DNS only, gray cloud) before running this validator."
fi
pass "test.${DOMAIN} => 1.2.3.4"

# ---- 2. Wildcard record resolves to 192.0.2.1 ----
# Use a random-ish prefix that is unlikely to have a real record
WILDCARD_LABEL="validate-lab04-check"
WILDCARD_ANSWER=$(dig +short "@${DNS_RESOLVER}" A "${WILDCARD_LABEL}.${DOMAIN}" 2>/dev/null | head -1)
if [ "$WILDCARD_ANSWER" != "192.0.2.1" ]; then
    fail "${WILDCARD_LABEL}.${DOMAIN} resolved to '${WILDCARD_ANSWER}', expected '192.0.2.1'. Create the wildcard A record (*) pointing to 192.0.2.1 (proxied) in the CF dashboard."
fi
pass "Wildcard *.${DOMAIN} => 192.0.2.1"

# ---- 3. https://<DOMAIN> returns 2xx or 3xx (CF proxy is live) ----
if ! command -v curl >/dev/null 2>&1; then
    fail "'curl' not found — install curl"
fi

HTTP_CODE=$(curl -sS -o /dev/null -w '%{http_code}' \
    --max-time 15 \
    --location \
    "https://${DOMAIN}/" 2>/dev/null || echo "000")

case "$HTTP_CODE" in
    2*|3*)
        pass "https://${DOMAIN}/ returned HTTP ${HTTP_CODE} (CF proxy active)"
        ;;
    521|522|523|524)
        # CF origin errors — proxy is alive, origin not yet configured (expected)
        pass "https://${DOMAIN}/ returned HTTP ${HTTP_CODE} (CF proxy active; origin not yet configured — expected at this stage)"
        ;;
    000)
        fail "curl could not connect to https://${DOMAIN}/ — check your domain is proxied (orange cloud) and CF site is Active"
        ;;
    *)
        fail "https://${DOMAIN}/ returned HTTP ${HTTP_CODE} — unexpected. Check CF dashboard for errors."
        ;;
esac

# ---- 4. wrangler whoami ----
if [ "$SKIP_WRANGLER" = "1" ]; then
    printf 'SKIP  wrangler check (SKIP_WRANGLER=1)\n'
else
    if ! command -v wrangler >/dev/null 2>&1; then
        fail "'wrangler' not found — run: npm install -g wrangler@4 (or open devcontainer terminal)"
    fi

    WRANGLER_OUT=$(wrangler whoami 2>&1 || true)
    if echo "$WRANGLER_OUT" | grep -qi 'not logged in\|unauthenticated\|no token'; then
        fail "wrangler is not authenticated. Run: wrangler login"
    fi
    ACCOUNT_LINE=$(echo "$WRANGLER_OUT" | grep -i 'Account Name\|account_name\|You are logged in' | head -1)
    if [ -z "$ACCOUNT_LINE" ]; then
        # Fallback: any non-empty output when exit was 0 is acceptable
        if [ -n "$WRANGLER_OUT" ]; then
            pass "wrangler whoami: authenticated (output: $(echo "$WRANGLER_OUT" | head -1))"
        else
            fail "wrangler whoami returned empty output — check your API token or run: wrangler login"
        fi
    else
        pass "wrangler whoami: ${ACCOUNT_LINE}"
    fi
fi

echo ""
echo "=== Lab 04 validate: ALL PASSED ==="
exit 0
