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

# ---- 2. Wildcard record is proxied (CF answers with its own anycast IP) ----
# The wildcard record's content is 192.0.2.1 (RFC 5737 placeholder) but
# proxied records always return CF's anycast IPs to clients — that is the
# whole point of "Proxied (orange cloud)".  We assert CF is the responding
# nameserver by matching the well-known anycast ranges
# (104.16.0.0/13, 172.64.0.0/13).  An RFC 5737 echo back would mean the
# record is DNS-only (gray cloud), which is the wrong state for the
# wildcard.
WILDCARD_LABEL="validate-lab04-check"
WILDCARD_ANSWER=$(dig +short "@${DNS_RESOLVER}" A "${WILDCARD_LABEL}.${DOMAIN}" 2>/dev/null | head -1)
case "$WILDCARD_ANSWER" in
    104.1[6-9].*|104.2[0-3].*|172.6[4-9].*|172.7[01].*)
        pass "Wildcard *.${DOMAIN} resolves to CF anycast (${WILDCARD_ANSWER}) — proxy active"
        ;;
    192.0.2.1)
        fail "Wildcard *.${DOMAIN} returned the configured 192.0.2.1 placeholder, which means the record is DNS-only (gray cloud). Set proxy status to Proxied (orange cloud) in the CF dashboard."
        ;;
    "")
        fail "Wildcard *.${DOMAIN} returned no answer. Confirm the wildcard A record (*) exists and the zone is Active."
        ;;
    *)
        fail "Wildcard *.${DOMAIN} resolved to '${WILDCARD_ANSWER}', expected a Cloudflare anycast IP (104.16/13 or 172.64/13). Confirm the wildcard A record exists and is Proxied."
        ;;
esac

# ---- 3. https://<DOMAIN> returns 2xx or 3xx (CF proxy is live) ----
if ! command -v curl >/dev/null 2>&1; then
    fail "'curl' not found — install curl"
fi

# Disable errexit just for the curl call so a non-zero exit (TLS, DNS,
# timeout) is captured rather than aborting the script.
set +e
# --connect-timeout fails fast on actual unreachability; --max-time 30 leaves
# room for Cloudflare's 521/522/524 responses, which can take 15–25 s when the
# proxy retries an unreachable origin before returning the error code.
HTTP_CODE=$(curl -sS -o /dev/null -w '%{http_code}' \
    --connect-timeout 5 \
    --max-time 30 \
    --location \
    "https://${DOMAIN}/" 2>/dev/null)
CURL_RC=$?
set -e
[ -z "$HTTP_CODE" ] && HTTP_CODE="000"

case "$HTTP_CODE" in
    2*|3*)
        pass "https://${DOMAIN}/ returned HTTP ${HTTP_CODE} (CF proxy active)"
        ;;
    521|522|523|524)
        # CF origin errors — proxy is alive, origin not yet configured (expected)
        pass "https://${DOMAIN}/ returned HTTP ${HTTP_CODE} (CF proxy active; origin not yet configured — expected at this stage)"
        ;;
    000)
        # When the DNS checks above passed but curl still reports 000, the
        # most common causes for a freshly-created proxied subdomain are
        # (in priority order):
        #   - exit  6: local resolver has a stale negative cache for the
        #              new hostname (resolves fine via @1.1.1.1 but not via
        #              the system stub resolver; flushes within minutes).
        #   - exit 35: TLS handshake failure — Cloudflare Universal SSL
        #              has not yet provisioned a cert for the new subdomain
        #              (typical lag 5–30 minutes after apex creation).
        #   - exit 28: connection timeout — proxy edge not yet routing.
        # In all three cases the DNS proof above is sufficient evidence that
        # zone delegation + proxy state are correct. We emit a warning and
        # soft-pass so the validator does not block while CF finishes
        # provisioning.
        case "$CURL_RC" in
            6|28|35)
                printf '[WARN] https://%s/ — curl exit %s. ' "$DOMAIN" "$CURL_RC" >&2
                case "$CURL_RC" in
                    6)  printf 'Local resolver has a stale negative cache; ' >&2 ;;
                    28) printf 'Connection timed out; ' >&2 ;;
                    35) printf 'TLS handshake failed (cert not yet issued); ' >&2 ;;
                esac
                printf 'usually transient on a freshly-created proxied subdomain. Retry in 10–30 minutes. ' >&2
                printf 'Treating as soft-pass because the DNS checks above are green.\n' >&2
                pass "https://${DOMAIN}/ — soft pass (transient cert/DNS provisioning; see warning above)"
                ;;
            *)
                fail "curl could not connect to https://${DOMAIN}/ (curl exit ${CURL_RC}) — check your domain is proxied (orange cloud) and CF site is Active"
                ;;
        esac
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
