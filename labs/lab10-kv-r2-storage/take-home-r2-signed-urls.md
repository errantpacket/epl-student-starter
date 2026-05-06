# Take-home: real R2 signed URLs

The in-class Lab 10 path uses **Worker-proxy** mode for artifact uploads
and downloads — every byte transits the Worker. That keeps the worker
code small and avoids per-cohort credential management, but it pushes
all artifact traffic through the Worker request path (subject to the
free-plan 100 MB request body limit and Worker CPU time).

This take-home shows the production-ops pattern: short-lived, S3 v4
signed URLs that let the client (the Mango, an operator console, or a
browser) PUT and GET R2 objects **directly** against R2's S3-compatible
endpoint. The Worker becomes a URL mint, not a bytes proxy.

## Prerequisites

- Lab 10 in-class flow complete (KV + R2 binding + Lab 07 worker
  deployed).
- Cloudflare dashboard access on your account.

## 1. Mint an R2 access key

Cloudflare R2 access keys are minted under **R2 → Manage R2 API tokens**
in the dashboard (they are distinct from CF API tokens; the latter
manage Cloudflare resources, the former authenticate against R2's
S3-compatible endpoint).

1. Open `https://dash.cloudflare.com/<your-account-id>/r2/api-tokens`.
2. Click **Create API token**.
3. Token name: `epl-r2-presign-<your-slot>`.
4. Permissions: **Object Read & Write**.
5. Specify bucket: pick `artifacts-bucket` from the list. Limiting
   the token's bucket scope is the principle-of-least-privilege move
   here; never issue an account-wide R2 key for one bucket.
6. TTL: 90 days (or whatever fits your retention story).
7. Click **Create API token**.
8. Save the **Access Key ID** and **Secret Access Key** that the
   dashboard shows. The secret is shown **once**.

You also need:

- Your account's R2 endpoint:
  `https://<account-id>.r2.cloudflarestorage.com` (the dashboard
  prints it next to the bucket).

## 2. Set Worker secrets

```sh
cd courses/engagement-platform-labs/labs/lab07-first-worker/worker

npx wrangler secret put R2_ACCESS_KEY_ID
# paste the Access Key ID

npx wrangler secret put R2_SECRET_ACCESS_KEY
# paste the Secret Access Key

npx wrangler secret put R2_ACCOUNT_ID
# paste your CF account id

npx wrangler secret put R2_BUCKET_NAME
# paste: artifacts-bucket
```

## 3. Add `aws4fetch`

```sh
cd courses/engagement-platform-labs/labs/lab07-first-worker/worker
npm install aws4fetch
```

`aws4fetch` is ~5 kB after tree-shaking, has no native deps, and does
exactly one thing: SigV4-sign a `Request`.

## 4. Replace the proxy-mode handlers

Open `src/index.js`. Replace `handleArtifactUpload`, `handleArtifactPut`,
and `handleArtifactGet` with the SigV4 versions below. Keep the
dispatcher unchanged.

```js
import { AwsClient } from 'aws4fetch';

function r2Client(env) {
    return new AwsClient({
        accessKeyId:     env.R2_ACCESS_KEY_ID,
        secretAccessKey: env.R2_SECRET_ACCESS_KEY,
        service:         's3',
        region:          'auto',
    });
}

function r2Url(env, key) {
    return `https://${env.R2_ACCOUNT_ID}.r2.cloudflarestorage.com/${env.R2_BUCKET_NAME}/${encodeURIComponent(key)}`;
}

async function handleArtifactUpload(request, env) {
    if (request.method !== 'POST') {
        return new Response('Method Not Allowed', { status: 405 });
    }

    let body = {};
    try { body = await request.json(); } catch {}

    const artifactId  = body.artifact_id  || crypto.randomUUID();
    const contentType = body.content_type || 'application/octet-stream';
    const expiresIn   = 900; // 15 minutes

    const aws = r2Client(env);
    const target = new URL(r2Url(env, artifactId));
    target.searchParams.set('X-Amz-Expires', String(expiresIn));

    const signed = await aws.sign(
        new Request(target, { method: 'PUT', headers: { 'Content-Type': contentType } }),
        { aws: { signQuery: true } }
    );

    return Response.json({
        artifact_id: artifactId,
        upload_url:  signed.url,
        expires_in:  expiresIn,
        content_type: contentType,
    });
}

async function handleArtifactGet(pathname, request, env) {
    if (request.method !== 'GET') {
        return new Response('Method Not Allowed', { status: 405 });
    }

    const artifactId = pathname.replace(/^\/v1\/artifacts\//, '');
    if (!artifactId) {
        return Response.json({ error: 'Missing artifact ID in path' }, { status: 400 });
    }

    const expiresIn = 3600;
    const aws = r2Client(env);
    const target = new URL(r2Url(env, artifactId));
    target.searchParams.set('X-Amz-Expires', String(expiresIn));

    const signed = await aws.sign(
        new Request(target, { method: 'GET' }),
        { aws: { signQuery: true } }
    );

    // Optional metadata fetch via the binding
    const head = await env.ARTIFACTS.head(artifactId);
    if (!head) {
        return Response.json({ error: 'Artifact not found' }, { status: 404 });
    }

    return Response.json({
        artifact_id:  artifactId,
        download_url: signed.url,
        expires_in:   expiresIn,
        size:         head.size,
        content_type: head.httpMetadata?.contentType || 'application/octet-stream',
    });
}

// Drop handleArtifactPut entirely — the S3 PUT signed URL is what the
// client uploads to, no Worker round-trip needed.
```

Also drop the `handleArtifactPut` dispatch branch from the route table
since clients will PUT to R2 directly now.

## 5. Redeploy and verify

```sh
npx wrangler deploy
```

Then re-run `validate.sh` (the in-class proxy version) — it will
**fail** the §3 PUT step because the signed URL points at R2, not the
Worker, and the test sends Access service-token headers that R2 won't
accept. Update `validate.sh` so the PUT/GET to R2 omit the Access
headers (R2 honours its own SigV4 signature in the URL):

```sh
# In validate.sh, the two curls that hit $UPLOAD_URL / $DOWNLOAD_URL:
#   - DROP: -H "CF-Access-Client-Id: ..."
#   - DROP: -H "CF-Access-Client-Secret: ..."
# The two curls that hit $WORKER_URL keep their Access headers.
```

## 6. Tradeoffs

| | Worker-proxy (in-class) | Signed URL (this take-home) |
|---|---|---|
| R2 access key required | no | yes (per-cohort dashboard work) |
| Bytes flow path | client → Worker → R2 | client ↔ R2 directly |
| Free-plan body limit (100 MB) | applies | does not |
| Worker CPU per upload | proportional to bytes | constant |
| Auth gate | CF Access | URL signature |
| URL bearer token | Access service token (long-lived) | URL embeds time-limited signature |
| Suitable for large pcaps (>100 MB) | no | yes |

For the workshop's pcap sizes (typical 10–50 MB) the in-class proxy
mode is fine. If you push the platform into ops where individual
artifacts can be hundreds of MB, the signed-URL pattern is the only
way to get there on the free plan.
