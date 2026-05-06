#!/bin/sh
# validate.sh — Lab 11: ChatOps EmojiChef (GitHub issue primary path)
#
# Posts a fresh "@<slot> 🥘🥫🥩🌯🥙🥘" (status command) comment to the
# configured GitHub issue using GITHUB_TOKEN, then polls the issue for the
# Worker's reply for up to 30 seconds. Asserts that the reply body starts
# with "[eplabs:result] @<slot>" and that it contains the expected decoded
# command ("status").
#
# Required environment variables (all can be overridden from the shell):
#   DOMAIN                — Worker domain (e.g. a00f3f13.eplabs.cloud)
#   GITHUB_TOKEN          — fine-grained PAT with Issues: read+write
#   GITHUB_OWNER          — GitHub username or org
#   GITHUB_REPO           — repository name
#   GITHUB_ISSUE_NUMBER   — issue number (default: 1)
#   STUDENT_SLOT          — the @-prefix for this student (e.g. alpha)
#
# Usage:
#   export DOMAIN="<your-domain>"
#   export GITHUB_TOKEN="<pat>"
#   export GITHUB_OWNER="<owner>"
#   export GITHUB_REPO="<repo>"
#   export STUDENT_SLOT="alpha"
#   ./validate.sh

set -eu

# ---------------------------------------------------------------------------
# Configuration — read from environment; fall back to sensible defaults
# ---------------------------------------------------------------------------
DOMAIN="${DOMAIN:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GITHUB_OWNER="${GITHUB_OWNER:-}"
GITHUB_REPO="${GITHUB_REPO:-}"
GITHUB_ISSUE_NUMBER="${GITHUB_ISSUE_NUMBER:-1}"
STUDENT_SLOT="${STUDENT_SLOT:-alpha}"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
echo ""
echo "=== Pre-flight ==="

if [ -z "$DOMAIN" ]; then
    echo "ERROR: DOMAIN is not set."
    echo "  export DOMAIN=\"<your-8-char-hex>.eplabs.cloud\""
    exit 1
fi

if [ -z "$GITHUB_TOKEN" ]; then
    echo "ERROR: GITHUB_TOKEN is not set."
    echo "  export GITHUB_TOKEN=\"<your-fine-grained-pat>\""
    exit 1
fi

if [ -z "$GITHUB_OWNER" ]; then
    echo "ERROR: GITHUB_OWNER is not set."
    echo "  export GITHUB_OWNER=\"<your-github-username>\""
    exit 1
fi

if [ -z "$GITHUB_REPO" ]; then
    echo "ERROR: GITHUB_REPO is not set."
    echo "  export GITHUB_REPO=\"<your-repo-name>\""
    exit 1
fi

echo "  DOMAIN              = ${DOMAIN}"
echo "  GITHUB_OWNER        = ${GITHUB_OWNER}"
echo "  GITHUB_REPO         = ${GITHUB_REPO}"
echo "  GITHUB_ISSUE_NUMBER = ${GITHUB_ISSUE_NUMBER}"
echo "  STUDENT_SLOT        = ${STUDENT_SLOT}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
WORKER_URL="https://api.${DOMAIN}"
API_BASE="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/issues/${GITHUB_ISSUE_NUMBER}"

gh_get_comments() {
    curl -s \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        "${API_BASE}/comments?per_page=30&sort=updated&direction=desc"
}

gh_post_comment() {
    _body="$1"
    curl -s -X POST \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        "${API_BASE}/comments" \
        -d "{\"body\":\"${_body}\"}"
}

# ---------------------------------------------------------------------------
# 1. Verify the Worker health endpoint responds
# ---------------------------------------------------------------------------
echo ""
echo "=== 1. Worker reachability ==="

HEALTH_HTTP=$(curl -s -o /dev/null -w "%{http_code}" "${WORKER_URL}/v1/health")
if [ "$HEALTH_HTTP" = "200" ]; then
    pass "GET /v1/health returned HTTP 200"
else
    fail "GET /v1/health returned HTTP ${HEALTH_HTTP} (expected 200)"
fi

# ---------------------------------------------------------------------------
# 2. Record comment count before posting so we can find the new reply
# ---------------------------------------------------------------------------
echo ""
echo "=== 2. Baseline comment count ==="

BEFORE_COUNT=$(gh_get_comments | jq 'length // 0')
echo "  Comments before test post: ${BEFORE_COUNT}"

# Record the current timestamp (seconds since epoch) to narrow the poll window
TS_BEFORE=$(date +%s)

# ---------------------------------------------------------------------------
# 3. Post the status command comment
# ---------------------------------------------------------------------------
echo ""
echo "=== 3. Post status command ==="

# EmojiChef encoding of "status" is 🥘🥫🥩🌯🥙🥘 (6 emoji)
# We encode as unicode escapes to avoid shell encoding issues.
EMOJI_STATUS='\U0001F958\U0001F96B\U0001F969\U0001F32F\U0001F959\U0001F958'
COMMENT_BODY="@${STUDENT_SLOT} ${EMOJI_STATUS}"

# Use printf to expand the unicode escapes
COMMENT_BODY_EXPANDED=$(printf "@${STUDENT_SLOT} \U0001F958\U0001F96B\U0001F969\U0001F32F\U0001F959\U0001F958")

POST_RESP=$(gh_post_comment "$(printf '@%s \U0001F958\U0001F96B\U0001F969\U0001F32F\U0001F959\U0001F958' "${STUDENT_SLOT}")")
POST_ID=$(printf '%s' "$POST_RESP" | jq -r '.id // empty')

if [ -n "$POST_ID" ]; then
    pass "Test comment posted (comment id: ${POST_ID})"
else
    fail "Failed to post test comment (response: ${POST_RESP})"
    echo ""
    echo "=== SUMMARY ==="
    echo "  Passed: ${PASS}"
    echo "  Failed: ${FAIL}"
    exit 1
fi

# ---------------------------------------------------------------------------
# 4. Poll for the bot reply (max 30 seconds)
# ---------------------------------------------------------------------------
echo ""
echo "=== 4. Waiting for bot reply (max 30s) ==="

EXPECTED_PREFIX="[eplabs:result] @${STUDENT_SLOT}"
REPLY_BODY=""
DEADLINE=$(($(date +%s) + 30))

while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    COMMENTS=$(gh_get_comments)
    # Find the most recent comment starting with the sentinel
    REPLY_BODY=$(printf '%s' "$COMMENTS" | jq -r \
        --arg prefix "[eplabs:result] @${STUDENT_SLOT}" \
        '[.[] | select(.body | startswith($prefix))] | sort_by(.id) | last | .body // ""')

    if [ -n "$REPLY_BODY" ] && [ "$REPLY_BODY" != "null" ]; then
        echo "  Bot reply found."
        break
    fi
    sleep 3
done

if [ -z "$REPLY_BODY" ] || [ "$REPLY_BODY" = "null" ]; then
    fail "No bot reply found within 30 seconds"
    echo ""
    echo "=== SUMMARY ==="
    echo "  Passed: ${PASS}"
    echo "  Failed: ${FAIL}"
    echo ""
    echo "Lab 11 validation FAILED. Address the failures above and re-run."
    exit 1
fi

pass "Bot reply received"

# ---------------------------------------------------------------------------
# 5. Assert the reply structure
# ---------------------------------------------------------------------------
echo ""
echo "=== 5. Reply structure assertions ==="

# Assert starts with the sentinel prefix
STARTS_OK=$(printf '%s' "$REPLY_BODY" | grep -c "^\[eplabs:result\] @${STUDENT_SLOT}" || true)
if [ "$STARTS_OK" -ge "1" ]; then
    pass "Reply starts with '[eplabs:result] @${STUDENT_SLOT}'"
else
    fail "Reply does not start with expected prefix (got: ${REPLY_BODY})"
fi

# Assert contains the decoded command "status"
STATUS_PRESENT=$(printf '%s' "$REPLY_BODY" | grep -ci "status" || true)
if [ "$STATUS_PRESENT" -ge "1" ]; then
    pass "Reply body contains 'status'"
else
    fail "Reply body does not mention 'status' (got: ${REPLY_BODY})"
fi

# Assert a job_id is present (UUID-shaped)
JOB_ID=$(printf '%s' "$REPLY_BODY" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1 || true)
if [ -n "$JOB_ID" ]; then
    pass "Reply contains job_id: ${JOB_ID}"
else
    fail "Reply does not contain a UUID job_id (reply: ${REPLY_BODY})"
    echo ""
    echo "=== SUMMARY ==="
    echo "  Passed: ${PASS}"
    echo "  Failed: ${FAIL}"
    exit 1
fi

# ---------------------------------------------------------------------------
# 6. Verify the KV job record
# ---------------------------------------------------------------------------
echo ""
echo "=== 6. KV job verification ==="

JOB_RESP=$(curl -s "${WORKER_URL}/v1/jobs/${JOB_ID}")
JOB_CMD=$(printf '%s' "$JOB_RESP" | jq -r '.command // empty')
JOB_SOURCE=$(printf '%s' "$JOB_RESP" | jq -r '.source // empty')
JOB_STATUS=$(printf '%s' "$JOB_RESP" | jq -r '.status // empty')

if [ "$JOB_CMD" = "status" ]; then
    pass "KV job command = status"
else
    fail "KV job command expected 'status', got '${JOB_CMD}'"
fi

if [ "$JOB_SOURCE" = "github_chatops" ]; then
    pass "KV job source = github_chatops"
else
    fail "KV job source expected 'github_chatops', got '${JOB_SOURCE}'"
fi

if [ "$JOB_STATUS" = "queued" ] || [ "$JOB_STATUS" = "pending" ]; then
    pass "KV job status = ${JOB_STATUS}"
else
    fail "KV job status expected 'queued' or 'pending', got '${JOB_STATUS}'"
fi

# ---------------------------------------------------------------------------
# 7. Audit log check
# ---------------------------------------------------------------------------
echo ""
echo "=== 7. Audit log ==="

AUDIT_COUNT=$(npx wrangler d1 execute fleet-database \
    --command="SELECT COUNT(*) AS cnt FROM audit_log WHERE action='chatops_dispatch';" \
    --remote --json 2>/dev/null \
    | jq -r '.[0].results[0].cnt // .[0].cnt // empty' 2>/dev/null || echo "")

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
