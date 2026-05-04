# Lab 10 — KV and R2 Storage

**Duration: 75 minutes**
**Day:** 2, Session 3

The enrollment and device-list endpoints from Lab 09 run the relational spine of the
platform. This lab adds the operational layer: a KV-backed job queue for command dispatch
and an R2-backed artifact store with signed URL delivery. When this lab is done, an
operator can enqueue a command to a specific device (the Mango sees it next time it polls),
and a device can upload a pcap or other artifact and the operator can retrieve it via a
time-limited signed URL.

These two patterns — KV job queue and R2 signed-URL handoff — are the core of the Lab 14
capstone. Understand them here.

---

## Learning objectives

- Provision a KV namespace with `wrangler kv:namespace create` and understand namespace IDs.
- Provision an R2 bucket with `wrangler r2 bucket create`.
- Wire both bindings in `wrangler.toml` and redeploy.
- Use KV for a job queue: write with `put(key, value, {expirationTtl})`, read with `get(key)`.
- Use R2 presigned URLs for secure, time-limited PUT and GET operations.
- Understand the Workers KV data model: key-value pairs with optional TTL, no indexes.
- Understand R2 as an object store: bucket/key model, HTTP API, access via signed URLs.

---

## Pre-state

Before starting, confirm:

```sh
# Lab 09 validation passes
bash courses/engagement-platform-labs/labs/lab09-d1-database/validate.sh

# wrangler is authenticated
wrangler whoami

# DOMAIN is exported
echo "${DOMAIN}"
```

The Worker currently returns 501 for `/v1/commands/<id>` — that changes in this lab.

---

## Walkthrough

### 1. Create the KV namespace

```sh
cd courses/engagement-platform-labs/labs/lab07-first-worker/worker
npx wrangler kv:namespace create RATE_LIMITS
```

Expected output:

```
Add the following to your configuration file in your kv_namespaces array:
{ binding = "RATE_LIMITS", id = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" }
```

Copy the `id` value.

### 2. Create the R2 bucket

```sh
npx wrangler r2 bucket create artifacts-bucket
```

Expected output:

```
Created bucket 'artifacts-bucket'
```

### 3. Update wrangler.toml

Open `worker/wrangler.toml`. The `[[kv_namespaces]]` and `[[r2_buckets]]` blocks are
already present. Replace the placeholder IDs:

```toml
[[kv_namespaces]]
binding = "RATE_LIMITS"
id      = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

[[r2_buckets]]
binding     = "ARTIFACTS"
bucket_name = "artifacts-bucket"
```

Using sed:

```sh
KV_ID="paste-your-namespace-id-here"
sed -i "s/YOUR_KV_NAMESPACE_ID/${KV_ID}/" wrangler.toml
```

Verify both blocks are populated:

```sh
grep -A2 "kv_namespaces" wrangler.toml
grep -A2 "r2_buckets" wrangler.toml
```

### 4. Review the new Worker endpoints

Open `labs/lab07-first-worker/worker/src/index.js` and read the four new functions
before deploying:

**handleCommand (updated from Lab 07 stub):**
- Accepts `POST /v1/commands/<device_id>` with body `{ command, params?, timeout? }`.
- Generates a UUID job_id.
- Calls `enqueueJob()` — a shared utility that writes to KV under key `job:<uuid>`.
- KV TTL = `timeout + 300` seconds (5-minute grace period after job deadline).
- Writes an `audit_log` row with action `"command_dispatch"`.
- Returns `{ job_id, status: "queued", device_id }`.

**handleJobStatus:**
- Accepts `GET /v1/jobs/<job_id>`.
- Reads `job:<job_id>` from KV; returns 404 if missing or expired.
- The Mango (Lab 12) polls this endpoint to receive its next command.

**handleArtifactUpload:**
- Accepts `POST /v1/artifacts/upload` with optional body `{ artifact_id?, content_type? }`.
- Mints a presigned PUT URL against the R2 `ARTIFACTS` bucket, valid for 15 minutes.
- Returns `{ artifact_id, upload_url, expires_in, content_type }`.
- The caller (Mango, devcontainer) uses the `upload_url` to PUT the artifact directly
  to R2 — the Worker is never in the data path for the upload itself.

**handleArtifactGet:**
- Accepts `GET /v1/artifacts/<artifact_id>` (supports nested paths: `/v1/artifacts/captures/foo.pcap`).
- Verifies the object exists in R2 with `env.ARTIFACTS.head()` before minting a URL.
- Mints a presigned GET URL valid for 1 hour.
- Returns `{ artifact_id, download_url, expires_in, size, content_type }`.

The `enqueueJob()` utility is also used by `handleDiscordChatops()` in Lab 11 — this
is the integration point. Any caller that enqueues a job produces a job object that
`handleJobStatus()` can read back. The shape is stable; do not change it.

### 5. Redeploy the Worker

```sh
cd courses/engagement-platform-labs/labs/lab07-first-worker/worker
npx wrangler deploy
```

Confirm the deploy output shows the same route. Check the bindings are listed:

```sh
npx wrangler deployments list | head -5
```

### 6. Test command enqueue

```sh
DEVICE_ID="lab09-test-device"   # device you enrolled in Lab 09

ENQUEUE_RESP=$(curl -s \
    -X POST "https://api.${DOMAIN}/v1/commands/${DEVICE_ID}" \
    -H "Content-Type: application/json" \
    -d '{"command": "status", "timeout": 30}')

echo "$ENQUEUE_RESP" | jq .
```

Expected response:

```json
{
  "job_id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "status": "queued",
  "device_id": "lab09-test-device"
}
```

Store the job_id:

```sh
JOB_ID=$(echo "$ENQUEUE_RESP" | jq -r '.job_id')
echo "JOB_ID: ${JOB_ID}"
```

### 7. Read the job back from KV via /v1/jobs

```sh
curl -s "https://api.${DOMAIN}/v1/jobs/${JOB_ID}" | jq .
```

Expected response:

```json
{
  "job_id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "device_id": "lab09-test-device",
  "command": "status",
  "params": {},
  "status": "queued",
  "created_at": "2024-09-23T10:00:00.000Z",
  "timeout": 30
}
```

### 8. Test artifact upload via signed URL

First, request a signed PUT URL from the Worker:

```sh
UPLOAD_RESP=$(curl -s \
    -X POST "https://api.${DOMAIN}/v1/artifacts/upload" \
    -H "Content-Type: application/json" \
    -d '{"content_type": "application/octet-stream"}')

echo "$UPLOAD_RESP" | jq .
```

Expected response:

```json
{
  "artifact_id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "upload_url": "https://...",
  "expires_in": 900,
  "content_type": "application/octet-stream"
}
```

Create a fixture file and upload it using the signed URL:

```sh
ARTIFACT_ID=$(echo "$UPLOAD_RESP" | jq -r '.artifact_id')
UPLOAD_URL=$(echo "$UPLOAD_RESP" | jq -r '.upload_url')

# Create a deterministic test fixture
printf 'lab10-artifact-test-data\n' > /tmp/lab10-fixture.bin
FIXTURE_SHA=$(sha256sum /tmp/lab10-fixture.bin | cut -d' ' -f1)
echo "Fixture SHA256: ${FIXTURE_SHA}"

# PUT directly to R2 via the signed URL
curl -s -o /dev/null -w "%{http_code}\n" \
    -X PUT "${UPLOAD_URL}" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @/tmp/lab10-fixture.bin
# Expected: 200
```

### 9. Retrieve the artifact via signed GET URL

```sh
DOWNLOAD_RESP=$(curl -s "https://api.${DOMAIN}/v1/artifacts/${ARTIFACT_ID}")
echo "$DOWNLOAD_RESP" | jq .

DOWNLOAD_URL=$(echo "$DOWNLOAD_RESP" | jq -r '.download_url')

# Download and verify SHA
curl -s "${DOWNLOAD_URL}" -o /tmp/lab10-retrieved.bin
RETRIEVED_SHA=$(sha256sum /tmp/lab10-retrieved.bin | cut -d' ' -f1)

echo "Original SHA:  ${FIXTURE_SHA}"
echo "Retrieved SHA: ${RETRIEVED_SHA}"

if [ "$FIXTURE_SHA" = "$RETRIEVED_SHA" ]; then
    echo "SHA match — artifact round-trip verified."
else
    echo "SHA MISMATCH — something changed in transit."
fi
```

### 10. Verify KV directly with wrangler

```sh
# List keys matching job: prefix
npx wrangler kv:key list --binding=RATE_LIMITS --prefix="job:"
```

You should see the job_id you created in step 6. After the TTL expires the key
disappears — this is the intended behavior (completed jobs expire automatically).

---

## Post-state

When this lab is complete:

- [ ] KV namespace `RATE_LIMITS` exists; `wrangler.toml` has the namespace ID.
- [ ] R2 bucket `artifacts-bucket` exists.
- [ ] `/v1/commands/<device_id>` returns `{ job_id, status: "queued" }`.
- [ ] `/v1/jobs/<job_id>` returns the job object read from KV.
- [ ] `/v1/artifacts/upload` returns a signed PUT URL.
- [ ] Uploading to the signed URL stores the artifact in R2.
- [ ] `/v1/artifacts/<id>` returns a signed GET URL.
- [ ] Downloading via the signed GET URL reproduces the original SHA256.

---

## Validation

```sh
chmod +x courses/engagement-platform-labs/labs/lab10-kv-r2-storage/validate.sh
export DOMAIN="<your-domain>"
courses/engagement-platform-labs/labs/lab10-kv-r2-storage/validate.sh
```

The script performs the full round-trip: enqueue command, read from KV, upload fixture
via signed URL, download via signed URL, assert SHA match.

---

## Troubleshooting

<details>
<summary>/v1/commands returns 500 "RATE_LIMITS is not defined"</summary>

- The KV namespace ID placeholder was not substituted. Check `wrangler.toml` for
  `YOUR_KV_NAMESPACE_ID` and substitute your real ID.
- Redeploy after editing `wrangler.toml`.

</details>

<details>
<summary>/v1/artifacts/upload returns 500 "ARTIFACTS is not defined"</summary>

- Same issue as above but for the R2 binding. Confirm `[[r2_buckets]]` is uncommented
  and `bucket_name = "artifacts-bucket"` matches the bucket you created.

</details>

<details>
<summary>Signed URL PUT returns 403 Forbidden</summary>

- The signed URL is single-use and time-limited. If more than 15 minutes have passed
  since calling `/v1/artifacts/upload`, the URL has expired. Request a new one.
- Ensure the `Content-Type` in your PUT request matches the `content_type` you passed
  to the upload endpoint. Some R2 signed URL implementations bind the content-type
  into the signature.

</details>

<details>
<summary>/v1/artifacts/<id> returns 404 "Artifact not found"</summary>

- The upload may not have completed before you called the GET endpoint.
- Verify the upload returned HTTP 200. If not, the artifact does not exist in R2.
- Check `wrangler r2 object get artifacts-bucket <artifact_id>` to confirm the object
  exists from the wrangler side.

</details>

<details>
<summary>KV key list shows no results after enqueue</summary>

- `wrangler kv:key list` requires the namespace ID, not just the binding name.
  Use `--binding=RATE_LIMITS` (not `--namespace-id`) when running from the worker
  directory where `wrangler.toml` is present.
- Keys with a short TTL may have already expired. The default job TTL is
  `timeout + 300` seconds. For a 30-second timeout job, the key expires in 330s.

</details>

---

## Take-home extension

The `enqueueJob()` utility sets `status: "queued"` but never updates it to `"running"`
or `"completed"`. For a production deployment, the Mango would need to write back a
status update after executing the command. Add a `/v1/jobs/<id>/update` endpoint to
the Worker that:

1. Reads the current job from KV.
2. Accepts a body `{ status, result?, error? }`.
3. Writes the updated job back to KV with the same TTL.
4. Writes an `audit_log` row with action `"job_update"`.

This is the pattern the Lab 14 capstone uses — but the capstone currently short-circuits
by observing R2 directly. The full job lifecycle (queued → running → completed) is
useful for monitoring long-running commands.

See `take-home/lab10-job-lifecycle/` for the skeleton.
