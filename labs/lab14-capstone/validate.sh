#!/bin/sh
# lab14-capstone/validate.sh
#
# Orchestrates the full capstone round-trip from the operator side and asserts:
#   (1) SSH-reachable Mango at drop-${STUDENT_SLOT} (tailnet hostname)
#   (2) Encode and dispatch "capture 30" emoji command to the Worker chatops/github endpoint
#   (3) Dispatch the capture to the Mango via tailscale ssh (operator bridge)
#   (4) Poll /v1/jobs/<id> until status=complete (timeout 120s)
#   (5) GET signed artifact URL from job result; HEAD returns 200
#   (6) Download the pcap via the signed URL; assert non-zero and pcap magic bytes
#   (7) Poll the GitHub issue comments for [eplabs:result] @${STUDENT_SLOT} with download: line
#   (8) Assert D1 audit_log has 5+ rows for this job_id
#
# Required env vars:
#   DOMAIN               — e.g. a00f3f13.eplabs.cloud
#   STUDENT_SLOT         — slot name, e.g. alpha
#   SERVICE_TOKEN_ID     — CF Access service token id
#   SERVICE_TOKEN_SECRET — CF Access service token secret
#   GITHUB_TOKEN         — personal access token (repo scope or issues: write)
#   GITHUB_OWNER         — repository owner
#   GITHUB_REPO          — repository name
#   GITHUB_ISSUE_NUMBER  — issue number for the command queue (typically 1)
#
# Optional:
#   WORKER_URL           — defaults to https://api.${DOMAIN}
#   MANGO_HOST           — defaults to drop-${STUDENT_SLOT}
#   SKIP_DISPATCH        — set to "1" to skip the tailscale ssh dispatch step
#                          (use if you have already dispatched manually)
#   GITHUB_WEBHOOK_SECRET — required for option B (devcontainer simulation)
#                            if not set, validate.sh uses option A (real webhook assumed)

set -eu

WORKER_URL="${WORKER_URL:-https://api.${DOMAIN}}"
MANGO_HOST="${MANGO_HOST:-drop-${STUDENT_SLOT}}"
SKIP_DISPATCH="${SKIP_DISPATCH:-0}"
JOB_POLL_TIMEOUT=120
COMMENT_POLL_TIMEOUT=60

# ---------------------------------------------------------------------------
die() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

pass() {
    printf 'ok   %s\n' "$*"
}

require_env() {
    eval "_val=\${$1:-}"
    [ -n "$_val" ] || die "Required env var \$$1 is not set."
}

# ---------------------------------------------------------------------------
require_env DOMAIN
require_env STUDENT_SLOT
require_env SERVICE_TOKEN_ID
require_env SERVICE_TOKEN_SECRET
require_env GITHUB_TOKEN
require_env GITHUB_OWNER
require_env GITHUB_REPO
require_env GITHUB_ISSUE_NUMBER

# ---------------------------------------------------------------------------
# (1) SSH-reachable Mango
# ---------------------------------------------------------------------------
printf '\n[1] Verifying Mango SSH reachability (%s)...\n' "$MANGO_HOST"

if ! tailscale ping "$MANGO_HOST" >/dev/null 2>&1; then
    die "tailscale ping to ${MANGO_HOST} failed.
  Check that the Mango is powered on, USB ExtRoot is mounted, and tailscaled is running:
    ssh root@192.168.8.1 '/etc/init.d/tailscale status'"
fi
pass "tailscale ping ${MANGO_HOST} succeeded"

# Verify run-capture.sh is deployed
if ! tailscale ssh "root@${MANGO_HOST}" 'test -f /tmp/run-capture.sh' 2>/dev/null; then
    die "run-capture.sh not found on ${MANGO_HOST}:/tmp/run-capture.sh
  Deploy it first:
    scp courses/engagement-platform-labs/labs/lab14-capstone/run-capture.sh \\
        root@${MANGO_HOST}:/tmp/run-capture.sh"
fi
pass "run-capture.sh present on ${MANGO_HOST}"

# ---------------------------------------------------------------------------
# (2) Encode "capture 30" and dispatch to the Worker chatops/github endpoint
# ---------------------------------------------------------------------------
printf '\n[2] Encoding and dispatching capture command...\n'

if command -v node >/dev/null 2>&1; then
    EMOJI_CMD=$(node -e "
const base = 0x1F345;
const bits = 6;
const text = 'capture 30';
const bin = [...text].map(c => c.charCodeAt(0).toString(2).padStart(8,'0')).join('');
const emojis = [];
for (let i = 0; i+bits <= bin.length; i += bits) {
    emojis.push(String.fromCodePoint(base + parseInt(bin.substr(i,bits),2)));
}
process.stdout.write(emojis.join(''));
")
elif command -v python3 >/dev/null 2>&1; then
    EMOJI_CMD=$(python3 -c "
base = 0x1F345
text = 'capture 30'
binary = ''.join(format(ord(c), '08b') for c in text)
result = ''.join(chr(base + int(binary[i:i+6], 2)) for i in range(0, len(binary)-5, 6))
print(result, end='')
")
else
    die "node or python3 required to encode emoji command. Install one in the devcontainer."
fi

[ -n "$EMOJI_CMD" ] || die "Failed to encode 'capture 30' to emoji"
pass "encoded 'capture 30' to emoji (${#EMOJI_CMD} codepoints)"

# Build GitHub issue_comment webhook payload
COMMENT_BODY="@${STUDENT_SLOT} ${EMOJI_CMD}"
PAYLOAD=$(python3 -c "
import json, sys
body = sys.argv[1]
owner = sys.argv[2]
repo  = sys.argv[3]
issue = int(sys.argv[4])
payload = {
    'action': 'created',
    'issue': {'number': issue},
    'comment': {'body': body, 'user': {'login': owner, 'type': 'User'}},
    'repository': {'name': repo, 'owner': {'login': owner}}
}
print(json.dumps(payload))
" "$COMMENT_BODY" "$GITHUB_OWNER" "$GITHUB_REPO" "$GITHUB_ISSUE_NUMBER")

# Compute HMAC-SHA256 signature if GITHUB_WEBHOOK_SECRET is set
if [ -n "${GITHUB_WEBHOOK_SECRET:-}" ]; then
    SIG=$(printf '%s' "$PAYLOAD" | openssl dgst -sha256 -hmac "$GITHUB_WEBHOOK_SECRET" -hex | sed 's/.*= //')
    SIG_HEADER="sha256=${SIG}"
else
    # No secret: send a zeroed placeholder; Worker must be configured to skip
    # signature verification for local testing (SKIP_SIG_VERIFY=1 wrangler.toml var)
    SIG_HEADER="sha256=$(printf '%064d' 0)"
    printf 'WARN: GITHUB_WEBHOOK_SECRET not set — sending zeroed signature\n' >&2
fi

JOB_RESPONSE=$(curl -sf \
    -X POST "${WORKER_URL}/v1/chatops/github" \
    -H "Content-Type: application/json" \
    -H "X-GitHub-Event: issue_comment" \
    -H "X-Hub-Signature-256: ${SIG_HEADER}" \
    -H "CF-Access-Client-Id: ${SERVICE_TOKEN_ID}" \
    -H "CF-Access-Client-Secret: ${SERVICE_TOKEN_SECRET}" \
    -d "$PAYLOAD" \
    2>/dev/null) || die "POST to /v1/chatops/github failed"

printf 'chatops response: %s\n' "$JOB_RESPONSE"

JOB_ID=$(printf '%s' "$JOB_RESPONSE" | grep -o '"job_id":"[^"]*"' | sed 's/"job_id":"//;s/"//')
[ -n "$JOB_ID" ] || die "Could not extract job_id from chatops response"
pass "job enqueued with job_id=${JOB_ID}"

DECODED=$(printf '%s' "$JOB_RESPONSE" | grep -o '"decoded":"[^"]*"' | sed 's/"decoded":"//;s/"//')
if ! printf '%s' "$DECODED" | grep -q '^capture'; then
    die "Decoded command '${DECODED}' does not start with 'capture'"
fi
pass "decoded command = '${DECODED}'"

# ---------------------------------------------------------------------------
# (3) Dispatch to Mango if not skipped
# ---------------------------------------------------------------------------
if [ "$SKIP_DISPATCH" != "1" ]; then
    printf '\n[3] Dispatching to Mango via tailscale ssh...\n'

    DISPATCH_START=$(date +%s)
    tailscale ssh "root@${MANGO_HOST}" \
        "GITHUB_TOKEN='${GITHUB_TOKEN}' \
         GITHUB_OWNER='${GITHUB_OWNER}' \
         GITHUB_REPO='${GITHUB_REPO}' \
         GITHUB_ISSUE_NUMBER='${GITHUB_ISSUE_NUMBER}' \
         STUDENT_SLOT='${STUDENT_SLOT}' \
         sh /tmp/run-capture.sh ${JOB_ID} 30 \
             ${WORKER_URL} ${SERVICE_TOKEN_ID} ${SERVICE_TOKEN_SECRET}"
    DISPATCH_END=$(date +%s)
    DISPATCH_DURATION=$(( DISPATCH_END - DISPATCH_START ))
    pass "dispatch completed in ${DISPATCH_DURATION}s"
else
    printf '[3] Skipping dispatch (SKIP_DISPATCH=1) — polling for completion...\n'
fi

# ---------------------------------------------------------------------------
# (4) Poll /v1/jobs/<id> until status=complete
# ---------------------------------------------------------------------------
printf '\n[4] Polling for job completion (timeout %ss)...\n' "$JOB_POLL_TIMEOUT"

elapsed=0
STATUS="queued"
JOB_STATE=""
while [ "$elapsed" -lt "$JOB_POLL_TIMEOUT" ]; do
    JOB_STATE=$(curl -sf \
        -H "CF-Access-Client-Id: ${SERVICE_TOKEN_ID}" \
        -H "CF-Access-Client-Secret: ${SERVICE_TOKEN_SECRET}" \
        "${WORKER_URL}/v1/jobs/${JOB_ID}" 2>/dev/null) || true

    STATUS=$(printf '%s' "$JOB_STATE" | grep -o '"status":"[^"]*"' | sed 's/"status":"//;s/"//' | head -1)
    printf 'status=%s (elapsed=%ss)\n' "${STATUS:-unknown}" "$elapsed"

    case "$STATUS" in
        complete) break ;;
        failed)
            die "Job ${JOB_ID} reported status=failed.
  Check Worker logs: npx wrangler tail
  Check Mango logs: tailscale ssh root@${MANGO_HOST} 'logread | tail -30'" ;;
    esac

    sleep 5
    elapsed=$((elapsed + 5))
done

if [ "$STATUS" != "complete" ]; then
    die "Job ${JOB_ID} did not reach status=complete within ${JOB_POLL_TIMEOUT}s (last: ${STATUS})"
fi
pass "job status=complete"

# ---------------------------------------------------------------------------
# (5) Extract artifact_id and HEAD the signed download URL
# ---------------------------------------------------------------------------
printf '\n[5] Fetching signed download URL and verifying reachability...\n'

ARTIFACT_ID=$(printf '%s' "$JOB_STATE" | grep -o '"artifact_id":"[^"]*"' | sed 's/"artifact_id":"//;s/"//' | head -1)
[ -n "$ARTIFACT_ID" ] || die "No artifact_id in completed job state: ${JOB_STATE}"
pass "artifact_id=${ARTIFACT_ID}"

ARTIFACT_RESPONSE=$(curl -sf \
    -H "CF-Access-Client-Id: ${SERVICE_TOKEN_ID}" \
    -H "CF-Access-Client-Secret: ${SERVICE_TOKEN_SECRET}" \
    "${WORKER_URL}/v1/artifacts/${ARTIFACT_ID}" 2>/dev/null) || \
    die "GET /v1/artifacts/${ARTIFACT_ID} failed"

DOWNLOAD_URL=$(printf '%s' "$ARTIFACT_RESPONSE" | grep -o '"download_url":"[^"]*"' | sed 's/"download_url":"//;s/"//')
[ -n "$DOWNLOAD_URL" ] || die "No download_url in artifact response: ${ARTIFACT_RESPONSE}"
pass "download URL minted"

# HEAD the signed URL — must return 200
HEAD_STATUS=$(curl -sS -o /dev/null -w '%{http_code}' --head --max-time 15 "$DOWNLOAD_URL" 2>/dev/null) || true
if [ "$HEAD_STATUS" != "200" ]; then
    die "HEAD on signed R2 URL returned HTTP ${HEAD_STATUS} (expected 200). URL may be expired or R2 binding broken."
fi
pass "signed R2 URL is reachable (HEAD 200)"

# ---------------------------------------------------------------------------
# (6) Download pcap and verify magic bytes
# ---------------------------------------------------------------------------
printf '\n[6] Downloading and verifying pcap...\n'

PCAP_FILE="/tmp/capstone-validate-$$.pcap"
HTTP_STATUS=$(curl -s -o "$PCAP_FILE" -w '%{http_code}' "$DOWNLOAD_URL") || \
    die "curl download failed"

if [ "$HTTP_STATUS" != "200" ]; then
    rm -f "$PCAP_FILE"
    die "Signed URL GET returned HTTP ${HTTP_STATUS} (expected 200). URL may be expired."
fi
pass "download returned HTTP 200"

PCAP_SIZE=$(wc -c < "$PCAP_FILE")
if [ "$PCAP_SIZE" -lt 24 ]; then
    rm -f "$PCAP_FILE"
    die "Downloaded file is only ${PCAP_SIZE} bytes — too small to be a valid pcap"
fi
pass "pcap size=${PCAP_SIZE} bytes (non-empty)"

MAGIC=$(od -A n -t x1 -N 4 "$PCAP_FILE" | tr -d ' \n')
rm -f "$PCAP_FILE"

case "$MAGIC" in
    d4c3b2a1|a1b2c3d4)
        pass "pcap magic bytes valid (${MAGIC} = $([ "$MAGIC" = d4c3b2a1 ] && printf 'LE' || printf 'BE'))"
        ;;
    *)
        die "First 4 bytes (${MAGIC}) do not match pcap magic. File may be corrupt or wrong format."
        ;;
esac

# ---------------------------------------------------------------------------
# (7) Poll GitHub issue comments for [eplabs:result] @${STUDENT_SLOT}
# ---------------------------------------------------------------------------
printf '\n[7] Polling GitHub issue #%s for result comment (timeout %ss)...\n' \
    "$GITHUB_ISSUE_NUMBER" "$COMMENT_POLL_TIMEOUT"

elapsed=0
RESULT_COMMENT=""
while [ "$elapsed" -lt "$COMMENT_POLL_TIMEOUT" ]; do
    COMMENTS=$(curl -sf \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/issues/${GITHUB_ISSUE_NUMBER}/comments" \
        2>/dev/null) || true

    RESULT_COMMENT=$(printf '%s' "$COMMENTS" | python3 -c "
import json, sys
try:
    comments = json.load(sys.stdin)
except Exception:
    sys.exit(0)
prefix = '[eplabs:result] @${STUDENT_SLOT}'
for c in reversed(comments):
    if c.get('body','').startswith(prefix):
        print(c['body'][:400])
        break
" 2>/dev/null) || true

    if [ -n "$RESULT_COMMENT" ]; then
        break
    fi

    printf 'waiting for result comment... (elapsed=%ss)\n' "$elapsed"
    sleep 5
    elapsed=$((elapsed + 5))
done

if [ -z "$RESULT_COMMENT" ]; then
    die "No result comment starting with '[eplabs:result] @${STUDENT_SLOT}' found on issue #${GITHUB_ISSUE_NUMBER} after ${COMMENT_POLL_TIMEOUT}s.
  Check run-capture.sh output on the Mango for GitHub API errors.
  Verify GITHUB_TOKEN has issues:write permission on ${GITHUB_OWNER}/${GITHUB_REPO}."
fi

# Assert the comment contains a download: line
if ! printf '%s' "$RESULT_COMMENT" | grep -q '^download:'; then
    die "Result comment found but missing 'download:' line. Comment body:
${RESULT_COMMENT}"
fi
pass "result comment found on issue #${GITHUB_ISSUE_NUMBER} with download: line"

# ---------------------------------------------------------------------------
# (8) Assert D1 audit_log has 5+ rows for this job_id
# ---------------------------------------------------------------------------
printf '\n[8] Checking D1 audit_log for full chain...\n'

AUDIT_ROWS=$(wrangler d1 execute fleet-database \
    --command "SELECT count(*) as cnt FROM audit_log WHERE details LIKE '%${JOB_ID}%'" \
    --json 2>/dev/null) || die "wrangler d1 execute failed"

ROW_COUNT=$(printf '%s' "$AUDIT_ROWS" | grep -o '"cnt":[0-9]*' | grep -o '[0-9]*' | head -1)
ROW_COUNT="${ROW_COUNT:-0}"

if [ "$ROW_COUNT" -lt 5 ]; then
    wrangler d1 execute fleet-database \
        --command "SELECT action, created_at FROM audit_log WHERE details LIKE '%${JOB_ID}%' ORDER BY created_at ASC" 2>/dev/null || true
    die "Expected 5+ audit_log rows for job ${JOB_ID}, found ${ROW_COUNT}.
  The full chain: chatops_dispatch, command_dispatch, exec_finished (minimum).
  Check that D1 FLEET_DB binding is active in wrangler.toml."
fi
pass "audit_log has ${ROW_COUNT} rows for job_id=${JOB_ID} (minimum 5 required)"

# ---------------------------------------------------------------------------
printf '\nlab14 capstone validation passed.\n'
printf 'Round-trip complete: emoji dispatch → GitHub result comment → pcap downloaded.\n'
printf 'job_id = %s\n' "$JOB_ID"
