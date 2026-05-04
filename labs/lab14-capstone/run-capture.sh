#!/bin/sh
# lab14-capstone/run-capture.sh
#
# Executes on the Mango (GL-MT300N-V2) when the operator dispatches a
# "capture" command via tailscale ssh.
#
# Usage:
#   sh /tmp/run-capture.sh <job_id> <duration_s> <worker_url> \
#       <service_token_id> <service_token_secret>
#
# Arguments:
#   job_id              — UUID from the Worker KV job queue
#   duration_s          — capture duration in seconds (default: 30)
#   worker_url          — https://api.<student>.eplabs.cloud
#   service_token_id    — CF Access service token id
#   service_token_secret — CF Access service token secret
#
# Environment variables (alternative to positional args):
#   JOB_ID, DURATION, WORKER_URL, SERVICE_TOKEN_ID, SERVICE_TOKEN_SECRET
#
# Requirements on the Mango:
#   - tcpdump-mini (in NOR image, Lab 02 package list)
#   - curl (in NOR image, Lab 02 package list)
#   - jsonfilter (in NOR image, Lab 02 package list)
#   - Upstream internet via WAN (for Worker POST)
#   - /tmp filesystem available (tmpfs, available without ExtRoot)

set -eu

# ---------------------------------------------------------------------------
# Arguments / environment
# ---------------------------------------------------------------------------
JOB_ID="${1:-${JOB_ID:-}}"
DURATION="${2:-${DURATION:-30}}"
WORKER_URL="${3:-${WORKER_URL:-}}"
SERVICE_TOKEN_ID="${4:-${SERVICE_TOKEN_ID:-}}"
SERVICE_TOKEN_SECRET="${5:-${SERVICE_TOKEN_SECRET:-}}"

# Validate required inputs
[ -n "$JOB_ID" ]              || { printf 'ERROR: JOB_ID is required\n' >&2; exit 1; }
[ -n "$WORKER_URL" ]          || { printf 'ERROR: WORKER_URL is required\n' >&2; exit 1; }
[ -n "$SERVICE_TOKEN_ID" ]    || { printf 'ERROR: SERVICE_TOKEN_ID is required\n' >&2; exit 1; }
[ -n "$SERVICE_TOKEN_SECRET" ] || { printf 'ERROR: SERVICE_TOKEN_SECRET is required\n' >&2; exit 1; }

# Validate duration is a positive integer
case "$DURATION" in
    [0-9]*) : ;;
    *) printf 'ERROR: DURATION must be a positive integer, got: %s\n' "$DURATION" >&2; exit 1 ;;
esac

PCAP_FILE="/tmp/${JOB_ID}.pcap"
LOG_TAG="[run-capture.sh]"

log() { printf '%s %s\n' "$LOG_TAG" "$*"; }

# ---------------------------------------------------------------------------
# Step 1: Run tcpdump-mini for DURATION seconds
# ---------------------------------------------------------------------------
log "starting tcpdump-mini for ${DURATION}s, job=${JOB_ID}"

# -G <duration>  rotate after N seconds
# -W 1           write only 1 rotation file (captures exactly <duration> seconds)
# -w <path>      output file
# -i any         capture on all interfaces
# Run with timeout in case tcpdump hangs (DURATION + 10s safety margin)
CAPTURE_START=$(date +%s)

tcpdump-mini -i any -G "$DURATION" -W 1 -w "$PCAP_FILE" 2>/dev/null &
TCPDUMP_PID=$!

# Wait for the capture to finish (duration + 2s grace)
WAIT=$(( DURATION + 2 ))
i=0
while [ "$i" -lt "$WAIT" ]; do
    sleep 1
    i=$((i + 1))
    if ! kill -0 "$TCPDUMP_PID" 2>/dev/null; then
        break  # tcpdump exited (rotation complete)
    fi
done

# Ensure it is done
kill "$TCPDUMP_PID" 2>/dev/null || true
wait "$TCPDUMP_PID" 2>/dev/null || true

CAPTURE_END=$(date +%s)
ACTUAL_DURATION=$(( CAPTURE_END - CAPTURE_START ))

# Verify capture file exists and is non-empty
if [ ! -f "$PCAP_FILE" ]; then
    log "ERROR: pcap file not created: ${PCAP_FILE}"
    exit 1
fi

PCAP_SIZE=$(wc -c < "$PCAP_FILE")
if [ "$PCAP_SIZE" -lt 24 ]; then
    # pcap global header is 24 bytes; anything smaller is corrupt
    log "ERROR: pcap file is too small (${PCAP_SIZE} bytes) — capture may have failed"
    exit 1
fi

log "capture complete, size=${PCAP_SIZE} bytes, duration=${ACTUAL_DURATION}s"

# ---------------------------------------------------------------------------
# Step 2: Mint a signed R2 PUT URL from the Worker
# ---------------------------------------------------------------------------
log "minting upload URL..."

ARTIFACT_ID="${JOB_ID}.pcap"

UPLOAD_RESPONSE=$(curl -sS \
    -X POST "${WORKER_URL}/v1/artifacts/upload" \
    -H "CF-Access-Client-Id: ${SERVICE_TOKEN_ID}" \
    -H "CF-Access-Client-Secret: ${SERVICE_TOKEN_SECRET}" \
    -H "Content-Type: application/json" \
    --connect-timeout 10 --max-time 30 \
    -d "{\"artifact_id\":\"${ARTIFACT_ID}\",\"content_type\":\"application/vnd.tcpdump.pcap\"}" \
    2>/dev/null) || { log "ERROR: failed to reach Worker /v1/artifacts/upload"; exit 1; }

UPLOAD_URL=$(printf '%s' "$UPLOAD_RESPONSE" \
    | jsonfilter -e '@.upload_url' 2>/dev/null)

if [ -z "$UPLOAD_URL" ]; then
    log "ERROR: could not extract upload_url from response: $(printf '%s' "$UPLOAD_RESPONSE" | head -c 256)"
    exit 1
fi

log "upload URL minted"

# ---------------------------------------------------------------------------
# Step 3: PUT the pcap to R2 via the signed URL
# ---------------------------------------------------------------------------
log "uploading pcap (${PCAP_SIZE} bytes)..."

HTTP_STATUS=$(curl -sS -o /dev/null -w '%{http_code}' \
    -X PUT "$UPLOAD_URL" \
    -H "Content-Type: application/vnd.tcpdump.pcap" \
    --data-binary "@${PCAP_FILE}" \
    --connect-timeout 10 --max-time 120 \
    2>/dev/null) || { log "ERROR: curl PUT failed"; exit 1; }

case "$HTTP_STATUS" in
    200|201|204)
        log "upload complete (HTTP ${HTTP_STATUS})"
        ;;
    *)
        log "ERROR: upload failed with HTTP ${HTTP_STATUS}"
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# Step 4: Report completion to the Worker
# ---------------------------------------------------------------------------
log "reporting completion..."

COMPLETE_PAYLOAD=$(cat <<EOF
{
  "artifact_id": "${ARTIFACT_ID}",
  "device_id":   "$(uci get system.@system[0].hostname 2>/dev/null || hostname)",
  "exit_code":   0,
  "duration_s":  ${ACTUAL_DURATION}
}
EOF
)

COMPLETE_STATUS=$(curl -sS -o /tmp/complete.body -w '%{http_code}' \
    -X PATCH "${WORKER_URL}/v1/jobs/${JOB_ID}/complete" \
    -H "CF-Access-Client-Id: ${SERVICE_TOKEN_ID}" \
    -H "CF-Access-Client-Secret: ${SERVICE_TOKEN_SECRET}" \
    -H "Content-Type: application/json" \
    --connect-timeout 10 --max-time 30 \
    -d "$COMPLETE_PAYLOAD" \
    2>/dev/null) || { log "ERROR: completion report failed (curl error)"; exit 1; }

case "$COMPLETE_STATUS" in
    200|201)
        DOWNLOAD_URL=$(jsonfilter -i /tmp/complete.body -e '@.download_url' 2>/dev/null || echo "")
        log "completion reported (HTTP ${COMPLETE_STATUS})"
        if [ -n "$DOWNLOAD_URL" ]; then
            log "download URL: ${DOWNLOAD_URL}"
        fi
        ;;
    *)
        log "WARN: completion report returned HTTP ${COMPLETE_STATUS}"
        log "      body: $(head -c 256 /tmp/complete.body)"
        ;;
esac

rm -f /tmp/complete.body

# ---------------------------------------------------------------------------
# Cleanup: remove pcap from /tmp to free RAM
# ---------------------------------------------------------------------------
rm -f "$PCAP_FILE"
log "done — pcap removed from /tmp"
