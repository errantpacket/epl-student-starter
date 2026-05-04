#!/bin/sh
# lab14-capstone/validate.sh
#
# Orchestrates the full capstone round-trip from the operator side and asserts:
#   (a) Encode and dispatch "capture 30" emoji command to the Worker
#   (b) Poll /v1/jobs/<id> until status=complete (timeout 120s)
#   (c) GET signed artifact URL from job result
#   (d) Download the pcap via the signed URL; assert non-zero and pcap magic bytes
#   (e) Assert D1 audit_log has 5+ rows for this job_id
#
# Required env vars:
#   DOMAIN               — e.g. a00f3f13.eplabs.cloud
#   STUDENT              — slot name, e.g. alpha
#   SERVICE_TOKEN_ID     — CF Access service token id
#   SERVICE_TOKEN_SECRET — CF Access service token secret
#
# Optional:
#   WORKER_URL           — defaults to https://api.${DOMAIN}
#   SKIP_DISPATCH        — set to "1" to skip the tailscale ssh dispatch step
#                          (use if you have already dispatched manually or the Mango
#                          is running the capture independently)
#   SKIP_DISCORD_CHECK   — set to "1" to skip the Discord webhook verification

set -eu

WORKER_URL="${WORKER_URL:-https://api.${DOMAIN}}"
SKIP_DISPATCH="${SKIP_DISPATCH:-0}"
SKIP_DISCORD_CHECK="${SKIP_DISCORD_CHECK:-0}"
JOB_POLL_TIMEOUT=120

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
require_env STUDENT
require_env SERVICE_TOKEN_ID
require_env SERVICE_TOKEN_SECRET

# ---------------------------------------------------------------------------
# (a) Encode "capture 30" and dispatch to the Worker chatops endpoint
# ---------------------------------------------------------------------------
printf '\n[1] Encoding and dispatching capture command...\n'

# EmojiChef encode "capture 30" — pure sh + od (POSIX, no node required)
encode_emoji() {
    text="$1"
    base=0x1F345
    binary=""
    # Build binary string from text
    i=0
    while [ $i -lt ${#text} ]; do
        char=$(printf '%s' "$text" | cut -c$((i+1)))
        # Get ASCII code via printf/od
        code=$(printf '%s' "$char" | od -A n -t u1 | awk '{print $1}')
        # Convert to 8-bit binary
        bits=""
        val=$code
        j=7
        while [ $j -ge 0 ]; do
            bit=$(( (val >> j) & 1 ))
            bits="${bits}${bit}"
            j=$((j - 1))
        done
        binary="${binary}${bits}"
        i=$((i + 1))
    done

    # Group into 6-bit values and convert to emoji codepoints
    emojis=""
    len=${#binary}
    k=0
    while [ $((k + 6)) -le $len ]; do
        chunk=$(printf '%s' "$binary" | cut -c$((k+1))-$((k+6)))
        # Binary string to decimal
        val=0
        for b in $(printf '%s' "$chunk" | fold -w1); do
            val=$(( (val << 1) | b ))
        done
        # Convert to emoji using Python (more reliable than pure sh for unicode)
        emoji=$(python3 -c "import sys; sys.stdout.write(chr($base + $val))" 2>/dev/null || \
                node -e "process.stdout.write(String.fromCodePoint($base + $val))" 2>/dev/null || \
                printf '?')
        emojis="${emojis}${emoji}"
        k=$((k + 6))
    done
    printf '%s' "$emojis"
}

# Prefer Node.js encoder (faster, more reliable unicode output)
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

# Dispatch to Worker
JOB_RESPONSE=$(curl -sf \
    -X POST "${WORKER_URL}/v1/chatops/discord" \
    -H "Content-Type: application/json" \
    -H "CF-Access-Client-Id: ${SERVICE_TOKEN_ID}" \
    -H "CF-Access-Client-Secret: ${SERVICE_TOKEN_SECRET}" \
    -H "X-Signature-Ed25519: $(printf '%064d' 0)" \
    -H "X-Signature-Timestamp: $(date +%s)" \
    -d "{\"content\": \"${EMOJI_CMD}\", \"device_id\": \"drop-${STUDENT}\"}" \
    2>/dev/null) || die "POST to /v1/chatops/discord failed"

printf 'chatops response: %s\n' "$JOB_RESPONSE"

JOB_ID=$(printf '%s' "$JOB_RESPONSE" | grep -o '"job_id":"[^"]*"' | sed 's/"job_id":"//;s/"//')
[ -n "$JOB_ID" ] || die "Could not extract job_id from chatops response"
pass "job enqueued with job_id=${JOB_ID}"

# Verify decoded command
DECODED=$(printf '%s' "$JOB_RESPONSE" | grep -o '"decoded":"[^"]*"' | sed 's/"decoded":"//;s/"//')
if ! printf '%s' "$DECODED" | grep -q '^capture'; then
    die "Decoded command '${DECODED}' does not start with 'capture'"
fi
pass "decoded command = '${DECODED}'"

# ---------------------------------------------------------------------------
# Dispatch to Mango if not skipped
# ---------------------------------------------------------------------------
if [ "$SKIP_DISPATCH" != "1" ]; then
    printf '\n[2] Dispatching to Mango via tailscale ssh...\n'

    MANGO_HOST="drop-${STUDENT}"
    DURATION="30"

    # Verify Mango is reachable
    if ! tailscale ping "$MANGO_HOST" >/dev/null 2>&1; then
        printf 'WARN: tailscale ping to %s failed — attempting dispatch anyway\n' "$MANGO_HOST" >&2
    fi

    # Verify run-capture.sh is deployed
    if ! tailscale ssh "root@${MANGO_HOST}" 'test -f /tmp/run-capture.sh' 2>/dev/null; then
        die "run-capture.sh not found on ${MANGO_HOST}:/tmp/run-capture.sh
  Deploy it first:
    scp courses/engagement-platform-labs/labs/lab14-capstone/run-capture.sh \\
        root@${MANGO_HOST}:/tmp/run-capture.sh"
    fi

    pass "run-capture.sh is present on ${MANGO_HOST}"

    # Dispatch the capture (runs synchronously over ssh; blocks until done)
    DISPATCH_START=$(date +%s)
    tailscale ssh "root@${MANGO_HOST}" \
        "sh /tmp/run-capture.sh ${JOB_ID} ${DURATION} ${WORKER_URL} ${SERVICE_TOKEN_ID} ${SERVICE_TOKEN_SECRET}"
    DISPATCH_END=$(date +%s)
    DISPATCH_DURATION=$(( DISPATCH_END - DISPATCH_START ))
    pass "dispatch completed in ${DISPATCH_DURATION}s"
else
    printf '[2] Skipping dispatch (SKIP_DISPATCH=1) — polling for completion...\n'
fi

# ---------------------------------------------------------------------------
# (b) Poll /v1/jobs/<id> until status=complete
# ---------------------------------------------------------------------------
printf '\n[3] Polling for job completion (timeout %ss)...\n' "$JOB_POLL_TIMEOUT"

elapsed=0
STATUS="queued"
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
  Check Mango logs: tailscale ssh root@drop-${STUDENT} 'cat /tmp/*.log 2>/dev/null || logread'" ;;
    esac

    sleep 5
    elapsed=$((elapsed + 5))
done

if [ "$STATUS" != "complete" ]; then
    die "Job ${JOB_ID} did not reach status=complete within ${JOB_POLL_TIMEOUT}s (last status: ${STATUS})"
fi
pass "job status=complete"

# ---------------------------------------------------------------------------
# (c) Extract artifact_id and get signed download URL
# ---------------------------------------------------------------------------
printf '\n[4] Fetching signed download URL...\n'

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

# ---------------------------------------------------------------------------
# (d) Download pcap and verify magic bytes
# ---------------------------------------------------------------------------
printf '\n[5] Downloading and verifying pcap...\n'

PCAP_FILE="/tmp/capstone-validate-$$.pcap"
HTTP_STATUS=$(curl -s -o "$PCAP_FILE" -w '%{http_code}' "$DOWNLOAD_URL") || \
    die "curl download failed"

if [ "$HTTP_STATUS" != "200" ]; then
    rm -f "$PCAP_FILE"
    die "Signed URL returned HTTP ${HTTP_STATUS} (expected 200). URL may be expired."
fi
pass "download returned HTTP 200"

PCAP_SIZE=$(wc -c < "$PCAP_FILE")
if [ "$PCAP_SIZE" -lt 24 ]; then
    rm -f "$PCAP_FILE"
    die "Downloaded file is only ${PCAP_SIZE} bytes — too small to be a valid pcap"
fi
pass "pcap size=${PCAP_SIZE} bytes (non-empty)"

# Check magic bytes: pcap LE (d4 c3 b2 a1) or pcap BE (a1 b2 c3 d4)
MAGIC=$(od -A n -t x1 -N 4 "$PCAP_FILE" | tr -d ' \n')
rm -f "$PCAP_FILE"

case "$MAGIC" in
    d4c3b2a1|a1b2c3d4)
        pass "pcap magic bytes valid (${MAGIC} = $([ "$MAGIC" = d4c3b2a1 ] && echo 'LE' || echo 'BE'))"
        ;;
    *)
        die "First 4 bytes (${MAGIC}) do not match pcap magic. File may be corrupt or wrong format."
        ;;
esac

# ---------------------------------------------------------------------------
# (e) Assert D1 audit_log has 5+ rows for this job_id
# ---------------------------------------------------------------------------
printf '\n[6] Checking D1 audit_log for full chain...\n'

AUDIT_ROWS=$(wrangler d1 execute fleet-database \
    --command "SELECT count(*) as cnt FROM audit_log WHERE details LIKE '%${JOB_ID}%'" \
    --json 2>/dev/null) || die "wrangler d1 execute failed"

ROW_COUNT=$(printf '%s' "$AUDIT_ROWS" | grep -o '"cnt":[0-9]*' | grep -o '[0-9]*' | head -1)
ROW_COUNT="${ROW_COUNT:-0}"

if [ "$ROW_COUNT" -lt 5 ]; then
    # Print the actual rows for debugging
    wrangler d1 execute fleet-database \
        --command "SELECT action, created_at FROM audit_log WHERE details LIKE '%${JOB_ID}%' ORDER BY created_at ASC" 2>/dev/null || true
    die "Expected 5+ audit_log rows for job ${JOB_ID}, found ${ROW_COUNT}.
  The full chain: chatops_dispatch, command_dispatch, exec_finished (minimum).
  Check that D1 FLEET_DB binding is active in wrangler.toml."
fi
pass "audit_log has ${ROW_COUNT} rows for job_id=${JOB_ID} (minimum 5 required)"

# ---------------------------------------------------------------------------
printf '\nlab14 capstone validation passed.\n'
printf 'Round-trip complete: emoji dispatch → pcap downloaded.\n'
printf 'job_id = %s\n' "$JOB_ID"
