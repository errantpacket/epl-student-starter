# Lab 14 — Capstone: emoji to drop exec to R2 to Discord

**Duration: 75 minutes**
**Day:** 2, Session 6

This is the lab you have been building toward for two days. A Discord message containing an
emoji-encoded "capture 30" command triggers a chain of events that ends with a pcap file
landing in your Discord channel as a signed R2 URL — delivered by the Mango drop device
you flashed and deployed in Lab 12, routed through the Worker you have been incrementally
building since Lab 07.

Nothing in this lab is new infrastructure. Everything uses endpoints and scripts that
already exist. The capstone is integration: making the full chain run reliably under a
time constraint.

---

## Learning objectives

- Understand the complete EPL stack end-to-end: ChatOps decode, job queue, device dispatch,
  artifact upload, signed URL delivery.
- Internalize the operator-bridge dispatch model: the Worker cannot initiate Tailscale
  connections; the operator (devcontainer) is the physical bridge between the Worker's KV
  job queue and the Mango's execution environment.
- Execute the round-trip in under 60 seconds.
- Read and verify the D1 audit_log chain for the full job lifecycle.

---

## Pre-state

All Labs 01-13 must be complete and validated.

```sh
# Mango is enrolled and reachable
tailscale ping drop-${STUDENT}   # should succeed

# Worker health check
curl -sf https://api.${DOMAIN}/v1/health | grep '"ok":true'

# D1 has at least one device row from Lab 12
curl -sf \
    -H "CF-Access-Client-Id: ${SERVICE_TOKEN_ID}" \
    -H "CF-Access-Client-Secret: ${SERVICE_TOKEN_SECRET}" \
    "https://api.${DOMAIN}/v1/devices" | grep "drop-${STUDENT}"

# KV relay_profile is set (Lab 13)
wrangler kv:key get --binding RATE_LIMITS relay_profile | grep user_agent_pattern

# DISCORD_WEBHOOK_URL is set as a Worker secret (Lab 14 setup step below)
wrangler secret list | grep DISCORD_WEBHOOK_URL || echo "set this secret before proceeding"
```

---

## Setup: configure the Discord webhook

The Worker uses `DISCORD_WEBHOOK_URL` to post the signed pcap URL back to Discord after the
Mango finishes the capture. Set it once:

1. In your Discord server, open the channel you want the bot to post in.
2. Channel Settings > Integrations > Webhooks > New Webhook.
3. Copy the webhook URL.
4. Set it as a Worker secret:

```sh
cd courses/engagement-platform-labs/labs/lab07-first-worker/worker
npx wrangler secret put DISCORD_WEBHOOK_URL
# Paste the webhook URL at the prompt
```

Verify:

```sh
npx wrangler secret list
# DISCORD_WEBHOOK_URL  should appear
```

Redeploy the Worker after setting the secret:

```sh
npx wrangler deploy
```

---

## Walkthrough

### 1. Deploy run-capture.sh to the Mango

`run-capture.sh` is the script that the Mango executes when the operator dispatches a
"capture" command. Copy it to the Mango over the tailnet:

```sh
SCRIPT="courses/engagement-platform-labs/labs/lab14-capstone/run-capture.sh"
tailscale ssh root@drop-${STUDENT} 'mkdir -p /tmp'
scp -o StrictHostKeyChecking=no \
    "$SCRIPT" \
    root@drop-${STUDENT}:/tmp/run-capture.sh
tailscale ssh root@drop-${STUDENT} 'chmod +x /tmp/run-capture.sh'
```

Verify the script is in place:

```sh
tailscale ssh root@drop-${STUDENT} 'ls -la /tmp/run-capture.sh && head -3 /tmp/run-capture.sh'
```

Note: `/tmp` is lost on Mango reboot. Re-deploy the script if the Mango restarts between
sessions. A production deployment would bake the script into the firmware overlay.

### 2. Encode the capture command with EmojiChef

The command to encode is `capture 30` (30-second pcap). Use the EmojiChef encoder from
the Worker's test harness or from the devcontainer:

```sh
# Quick Node.js one-liner using the EmojiChef class from the Worker source
node -e "
const base = 0x1F345;
const bits = 6;
const text = 'capture 30';
const bin = [...text].map(c => c.charCodeAt(0).toString(2).padStart(8,'0')).join('');
const emojis = [];
for (let i = 0; i+bits <= bin.length; i += bits) {
    emojis.push(String.fromCodePoint(base + parseInt(bin.substr(i,bits),2)));
}
console.log(emojis.join(''));
"
```

Copy the emoji string. You will paste it into Discord in the next step.

Alternatively, use the pre-encoded test vector from the workshop spec:

```
Test decode check: the Chef decodes 🍡🍼🍖🍦🍢🍌🍚🍸 → "status"
```

Encode `capture 30` yourself using the encoder above and verify by decoding it back.

### 3. Send the emoji command from Discord

In your Discord channel, send a message containing only the emoji string you just encoded.

The Discord webhook is configured in the opposite direction from what you might expect:
the Cloudflare Worker is the *receiver* (an interactions endpoint or outbound webhook
target), not the sender. The Workshop uses an **outbound webhook** (Discord's Webhooks
v2 with event subscriptions) or a simple bot that forwards messages to the Worker.

For the workshop, use the simplest approach: **POST directly to the Worker as if it were
Discord** — simulating the Discord → Worker call from your devcontainer:

```sh
# Encode the emoji string (replace with your actual encoded string)
EMOJI_CMD="<paste your emoji string here>"

# Post to the Worker chatops endpoint
JOB_RESPONSE=$(curl -sf \
    -X POST \
    -H "Content-Type: application/json" \
    -H "CF-Access-Client-Id: ${SERVICE_TOKEN_ID}" \
    -H "CF-Access-Client-Secret: ${SERVICE_TOKEN_SECRET}" \
    -H "X-Signature-Ed25519: $(printf '%064d' 0)" \
    -H "X-Signature-Timestamp: $(date +%s)" \
    -d "{\"content\": \"${EMOJI_CMD}\", \"device_id\": \"drop-${STUDENT}\"}" \
    "https://api.${DOMAIN}/v1/chatops/discord")

echo "$JOB_RESPONSE"
JOB_ID=$(printf '%s' "$JOB_RESPONSE" | grep -o '"job_id":"[^"]*"' | sed 's/"job_id":"//;s/"//')
echo "JOB_ID=${JOB_ID}"
```

Expected response:

```json
{
  "decoded": "capture 30",
  "command": "capture",
  "args": ["30"],
  "job_id": "<uuid>",
  "status": "queued",
  "device_id": "drop-alpha"
}
```

Note: The `X-Signature-Ed25519` header is required by the Worker's signature check.
In this test, we pass a zeroed value; the Worker skips full verification when
`DISCORD_PUBLIC_KEY` is not set, or you can temporarily unset it for the capstone demo.
In a real Discord integration the signature comes from Discord's system.

### 4. Verify the job is in the KV queue

```sh
curl -sf \
    -H "CF-Access-Client-Id: ${SERVICE_TOKEN_ID}" \
    -H "CF-Access-Client-Secret: ${SERVICE_TOKEN_SECRET}" \
    "https://api.${DOMAIN}/v1/jobs/${JOB_ID}"
```

Expected:

```json
{
  "job_id": "<uuid>",
  "device_id": "drop-alpha",
  "command": "capture",
  "params": { "args": ["30"], "raw": "capture 30" },
  "status": "queued",
  "created_at": "2024-...",
  "timeout": 60
}
```

### 5. Dispatch the capture to the Mango (operator bridge step)

The Worker cannot initiate Tailscale connections — Workers are stateless edge functions
running on Cloudflare's network with no persistent state and no access to the tailnet.
The operator (you, in the devcontainer) is the physical bridge.

Read the job, extract the duration, and dispatch via `tailscale ssh`:

```sh
DURATION=$(curl -sf \
    -H "CF-Access-Client-Id: ${SERVICE_TOKEN_ID}" \
    -H "CF-Access-Client-Secret: ${SERVICE_TOKEN_SECRET}" \
    "https://api.${DOMAIN}/v1/jobs/${JOB_ID}" \
    | grep -o '"args":\["[0-9]*"\]' | grep -o '[0-9]*')

DURATION="${DURATION:-30}"

echo "Dispatching: tailscale ssh root@drop-${STUDENT} 'sh /tmp/run-capture.sh ${JOB_ID} ${DURATION}'"
tailscale ssh root@drop-${STUDENT} \
    "sh /tmp/run-capture.sh ${JOB_ID} ${DURATION} https://api.${DOMAIN} ${SERVICE_TOKEN_ID} ${SERVICE_TOKEN_SECRET}"
```

The `run-capture.sh` script on the Mango will:

1. Run `tcpdump-mini -G ${DURATION} -W 1 -w /tmp/${JOB_ID}.pcap` (capture for N seconds).
2. POST to `/v1/artifacts/upload` to get a signed R2 PUT URL.
3. PUT the pcap file to R2 via the signed URL.
4. PATCH `/v1/jobs/${JOB_ID}/complete` to report the artifact_id and duration.

You should see output from the script streaming back over the SSH connection:

```
[run-capture.sh] starting tcpdump-mini for 30s, job=<uuid>
[run-capture.sh] capture complete, size=NNNN bytes
[run-capture.sh] minting upload URL...
[run-capture.sh] uploading pcap...
[run-capture.sh] reporting completion...
[run-capture.sh] done
```

### 6. Poll for job completion and retrieve the download URL

```sh
# Poll until status=complete (timeout 90s)
for i in $(seq 1 18); do
    RESULT=$(curl -sf \
        -H "CF-Access-Client-Id: ${SERVICE_TOKEN_ID}" \
        -H "CF-Access-Client-Secret: ${SERVICE_TOKEN_SECRET}" \
        "https://api.${DOMAIN}/v1/jobs/${JOB_ID}" 2>/dev/null)
    STATUS=$(printf '%s' "$RESULT" | grep -o '"status":"[^"]*"' | sed 's/"status":"//;s/"//')
    printf 'status=%s\n' "$STATUS"
    if [ "$STATUS" = "complete" ]; then
        printf '%s\n' "$RESULT"
        break
    fi
    sleep 5
done
```

Extract the download URL:

```sh
ARTIFACT_ID=$(printf '%s' "$RESULT" | grep -o '"artifact_id":"[^"]*"' | sed 's/"artifact_id":"//;s/"//')
DOWNLOAD_JSON=$(curl -sf \
    -H "CF-Access-Client-Id: ${SERVICE_TOKEN_ID}" \
    -H "CF-Access-Client-Secret: ${SERVICE_TOKEN_SECRET}" \
    "https://api.${DOMAIN}/v1/artifacts/${ARTIFACT_ID}")
DOWNLOAD_URL=$(printf '%s' "$DOWNLOAD_JSON" | grep -o '"download_url":"[^"]*"' | sed 's/"download_url":"//;s/"//')
echo "DOWNLOAD_URL=${DOWNLOAD_URL}"
```

### 7. Download and verify the pcap

```sh
curl -o /tmp/capstone-capture.pcap "$DOWNLOAD_URL"
ls -lh /tmp/capstone-capture.pcap
# Non-zero size expected

# Verify pcap magic bytes (0xd4c3b2a1 little-endian or 0xa1b2c3d4 big-endian)
xxd /tmp/capstone-capture.pcap | head -1
# Expected: d4c3 b2a1 ...  (pcap LE magic) or a1b2 c3d4 ... (pcap BE magic)
```

If `xxd` is not available:

```sh
od -A x -t x1z /tmp/capstone-capture.pcap | head -2
```

### 8. Check the Discord notification

The Worker posts a message to the Discord webhook when `PATCH /v1/jobs/<id>/complete` is
processed. Check your Discord channel for a message like:

```
Capture complete for job <uuid>
Device: drop-alpha
Duration: 30s
Download pcap (1 hour): https://...r2.cloudflarestorage.com/...
```

If the Discord message did not appear: verify `DISCORD_WEBHOOK_URL` is set
(`wrangler secret list`) and that the Worker was redeployed after setting the secret.

### 9. Verify the D1 audit chain

```sh
wrangler d1 execute fleet-database \
    --command "SELECT action, details, created_at FROM audit_log \
               WHERE details LIKE '%${JOB_ID}%' ORDER BY created_at ASC"
```

Expected chain (at least these rows, in order):

| action | details |
|---|---|
| `chatops_dispatch` | `{"emoji":"...","decoded":"capture 30","command":"capture","job_id":"<uuid>"}` |
| `command_dispatch` | `{"job_id":"<uuid>","command":"capture",...}` (if dispatched via /v1/commands) |
| `exec_finished` | `{"job_id":"<uuid>","artifact_id":"...","exit_code":0,...}` |

Five or more rows is the validation target (the validate.sh script checks for this).

---

## Post-state

When this lab is complete:

- [ ] Job created in KV with `status=complete`.
- [ ] pcap file is non-zero and starts with the pcap magic bytes.
- [ ] R2 artifact is reachable via the signed download URL.
- [ ] Discord channel received the signed URL message.
- [ ] D1 `audit_log` has 5+ rows for the job_id (chatops_dispatch through exec_finished).
- [ ] Round-trip completed in under 60 seconds (from sending the Discord emoji to receiving
      the download URL).

---

## Validation

```sh
export DOMAIN="<your-domain>"
export STUDENT="<your-slot>"
export SERVICE_TOKEN_ID="<from lab08>"
export SERVICE_TOKEN_SECRET="<from lab08>"
chmod +x courses/engagement-platform-labs/labs/lab14-capstone/validate.sh
courses/engagement-platform-labs/labs/lab14-capstone/validate.sh
```

The validate script orchestrates the full round-trip automatically. Watch the output — it
prints each assertion as it passes.

---

## Troubleshooting

<details>
<summary>EmojiChef decode returns garbage or fails</summary>

The emoji string must contain only codepoints in the range U+1F345-U+1F37F. If you typed
the emojis manually, verify them with:

```sh
node -e "const s='<your string>'; [...s].forEach(e => console.log(e, 'U+'+e.codePointAt(0).toString(16).toUpperCase()))"
```

Any codepoint outside the range will cause a decode error. Use the Node.js encoder from
Step 2 to generate the canonical string.

</details>

<details>
<summary>tailscale ssh fails to reach drop-${STUDENT}</summary>

Run `tailscale status` in the devcontainer. If `drop-${STUDENT}` is not listed, the Mango
may have lost its ExtRoot overlay (USB disconnected, or the Mango rebooted without USB
present). Re-plug the USB, then run:

```sh
ssh root@192.168.8.1 '/etc/init.d/tailscale restart'
sleep 10
tailscale status | grep drop-
```

</details>

<details>
<summary>run-capture.sh: "tcpdump-mini: command not found"</summary>

`tcpdump-mini` is in the NOR image (canonical package list from Lab 02). If it is missing,
the Mango firmware is not the sealed image from Lab 12. Flash the sealed image and retry.

</details>

<details>
<summary>pcap upload fails (curl error or HTTP 403)</summary>

The signed PUT URL from `/v1/artifacts/upload` has a 15-minute TTL. If more than 15 minutes
passed between minting the URL and the PUT, the URL is expired. Run `run-capture.sh` again
with the same job_id — it mints a fresh URL each time.

Also confirm the R2 binding is active: `wrangler r2 bucket list` should show `artifacts-bucket`.

</details>

<details>
<summary>PATCH /v1/jobs/<id>/complete returns 404</summary>

Check the Worker route for the `/relay/*` and `/v1/jobs/*/complete` paths. A 404 from the
Worker means the path did not match any route case. Verify the Worker was deployed after
Lab 14's changes to `src/index.js` were merged in.

```sh
npx wrangler deploy --dry-run  # verify the Worker parses cleanly
npx wrangler deploy
```

</details>

<details>
<summary>Discord webhook message never arrives</summary>

1. Confirm `DISCORD_WEBHOOK_URL` is set: `wrangler secret list`.
2. Test the webhook independently:

```sh
curl -X POST "$DISCORD_WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d '{"content":"webhook test from capstone"}'
# Expected: HTTP 204 No Content
```

3. Check `wrangler tail` output when the Mango calls PATCH /v1/jobs/<id>/complete — look for
   "Discord webhook error" log lines.

</details>

---

## Take-home extension

**Automate the operator-bridge step.** The manual `tailscale ssh ... run-capture.sh`
dispatch is intentionally explicit in the workshop — it exposes the architectural seam
between the Worker and the tailnet. As a take-home exercise, write a small polling daemon
(Python or shell, running persistently in the devcontainer) that:

1. Polls `GET /v1/jobs/<device_id>` every 5 seconds for queued jobs.
2. For each queued "capture" job, dispatches via `tailscale ssh` automatically.
3. Logs dispatched jobs to avoid re-dispatching on the next poll.

This makes the capstone round-trip fully autonomous — the operator only types in Discord
and the rest happens automatically.
