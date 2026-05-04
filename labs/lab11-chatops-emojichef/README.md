# Lab 11 — ChatOps with EmojiChef

**Duration: 60 minutes**
**Day:** 2, Session 4

Operators do not type commands in plaintext. They post what looks like a food appreciation
thread in a Discord channel, and the Worker decodes it into an authenticated command that
gets dispatched to the correct device. This is EmojiChef: a steganographic encoding scheme
that uses Cloudflare's food emoji range (U+1F345 through U+1F37F) as a 6-bit-per-emoji
quasi-base64 alphabet.

In this lab you configure a Discord webhook that fires at your Worker, implement the
signature verification and decoder in the Worker, and wire the decoded command into the
KV job queue from Lab 10. When it works, typing "🥘🥫🥩🌯🥙🥘" in Discord silently
enqueues a `status` job for a device — and an entry appears in the D1 audit log.

---

## Learning objectives

- Understand the EmojiChef encoding scheme: base codepoint, 6-bit windows, byte assembly.
- Verify Discord webhook signatures using Ed25519 and the Web Crypto API.
- Handle Discord's PING/PONG interaction verification flow.
- Wire the decoded command into the Lab 10 job queue (`enqueueJob` / `RATE_LIMITS` KV).
- Configure a Discord outbound webhook to call a Worker route.
- Test known encoding vectors end-to-end.

---

## Pre-state

Before starting, confirm:

```sh
# Lab 10 validation passes (KV + R2 working)
bash courses/engagement-platform-labs/labs/lab10-kv-r2-storage/validate.sh

# DOMAIN is exported
echo "${DOMAIN}"
```

You also need:
- A Discord account.
- A Discord server where you have "Manage Webhooks" permission (create a test server for
  the workshop if needed — it takes 30 seconds).

---

## Walkthrough

### 1. Understand the EmojiChef encoding scheme

The encoder maps ASCII text to Cloudflare's food emoji block:

| ASCII | Binary (8 bits) | 6-bit chunks | Emojis |
|-------|-----------------|--------------|--------|
| `H`   | 01001000        | 010010 00    |        |
| `S`   | 01010011        | (carried)    |        |
| `C`   | 01000011        |              |        |

The binary stream is cut into 6-bit windows; each window value `n` maps to codepoint
`0x1F345 + n`. The last incomplete 6-bit window is dropped (so encoded length is always
`floor(len(ascii) * 8 / 6)` emoji characters).

Known test vectors (see also `test-vectors.txt`):

| Plaintext | Encoded |
|-----------|---------|
| `HSC`     | 🍗🍊🍒🍈   |
| `status`  | 🥘🥫🥩🌯🥙🥘 |
| `reboot`  | 🍱🥤🥩🥓🥨🥯🌯 |

Verify the vectors yourself using Node:

```sh
cd courses/engagement-platform-labs/labs/lab07-first-worker/worker
node -e "
const BASE = 0x1F345;
const encode = t => [...t].reduce((b, c) => b + c.charCodeAt(0).toString(2).padStart(8,'0'), '')
    .match(/.{6}/g).map(s => String.fromCodePoint(BASE + parseInt(s,2))).join('');
const decode = e => [...e].map(c => (c.codePointAt(0) - BASE).toString(2).padStart(6,'0')).join('')
    .match(/.{8}/g).map(s => String.fromCharCode(parseInt(s,2))).join('');
['HSC','status','reboot'].forEach(t => console.log(t, '->', encode(t), '-> decoded:', decode(encode(t))));
"
```

Expected output:

```
HSC -> 🍗🍊🍒🍈 -> decoded: HSC
status -> 🥘🥫🥩🌯🥙🥘 -> decoded: status
reboot -> 🍱🥤🥩🥓🥨🥯🌯 -> decoded: reboot
```

### 2. Review the Worker chatops endpoint

Open `labs/lab07-first-worker/worker/src/index.js` and read `handleDiscordChatops()`.
Key behaviors:

- **PING response:** Discord sends a `{ type: 1 }` payload when first configuring the
  webhook URL to verify the endpoint is live. The Worker responds immediately with
  `{ type: 1 }`. This must work before Discord will accept the URL.
- **Signature verification:** Discord signs every request with Ed25519 using your app's
  public key. The Worker verifies using `X-Signature-Ed25519` and `X-Signature-Timestamp`
  headers. Verification is skipped if `DISCORD_PUBLIC_KEY` is not set (dev mode only).
- **Emoji extraction:** The Worker looks for the emoji string in `payload.content` (simple
  messages) or `payload.data.options[0].value` (slash command interactions).
- **Decode and dispatch:** `EmojiChefQuick.decode()` converts the emoji string to ASCII.
  The first whitespace-delimited token is the command name; remaining tokens are args.
- **Command vocabulary:** `status`, `reboot`, `capture`, `list`, `ping`, `exec`, `fetch`,
  and `HSC` are valid commands. Unknown commands return 422 with a list of known commands.
- **Enqueue:** Uses `enqueueJob()` — the same function `handleCommand()` uses — so the
  resulting KV job is identical in shape and can be read via `/v1/jobs/<id>`.

### 3. Set the Discord public key as a Worker secret

You will create the Discord app in steps 4-5 and get the public key there. For now,
note the pattern for setting it:

```sh
cd courses/engagement-platform-labs/labs/lab07-first-worker/worker
# Run this after you have the public key from Discord (step 5)
npx wrangler secret put DISCORD_PUBLIC_KEY
# Paste the hex public key at the prompt
```

Worker secrets are encrypted at rest. Do not put the public key in `wrangler.toml`
`[vars]` — use `wrangler secret put` only.

### 4. Create a Discord application

1. Open [discord.com/developers/applications](https://discord.com/developers/applications).
2. Click **New Application**. Name it `eplabs-chatops-<your-student-id>`.
3. In the **General Information** tab, copy the **Public Key** (64-char hex string).
4. In the **Bot** tab (if present), you can leave it off — we use Outgoing Webhooks, not
   a bot for this lab.

See `discord-webhook-setup.md` in this lab directory for a click-by-click guide with
screenshots.

### 5. Configure the interactions endpoint URL

In your Discord application's **General Information** tab:

1. Find the **Interactions Endpoint URL** field.
2. Enter: `https://api.${DOMAIN}/v1/chatops/discord`
   (substitute your actual domain).
3. Click **Save Changes**.

Discord immediately sends a PING (`{ type: 1 }`) to verify the endpoint. If the Worker
responds correctly, Discord saves the URL. If the PING fails, you see an error — check
the wrangler tail output.

Before setting the URL, set the public key secret so the PING is verified correctly:

```sh
# In the worker/ directory:
npx wrangler secret put DISCORD_PUBLIC_KEY
# <paste the 64-char hex Public Key from your Discord app>
```

Redeploy after setting the secret:

```sh
npx wrangler deploy
```

### 6. Create an outbound webhook in a Discord server

This is the channel webhook that fires when you post a message:

1. In your Discord server, open a channel's settings (gear icon or right-click >
   Edit Channel).
2. Go to **Integrations** > **Webhooks** > **New Webhook**.
3. Name it `EmojiChef` and select the channel.
4. Copy the webhook URL — you do not need this in the Worker, but it is useful for
   testing by POSTing to Discord as if a user sent a message.

For the chatops flow (Discord -> Worker), the mechanism is:
- **Discord Slash Commands** (recommended) — Discord calls your Interactions Endpoint
  URL when a user runs a slash command. The Worker receives a JSON body with
  `data.options[0].value` containing the emoji string.
- **Outgoing Webhooks** — older mechanism; Discord sends a POST to your URL when a
  message matches a trigger word. Less reliable, not all server types support it.

For the workshop, use the slash command approach (step 7).

See `discord-webhook-setup.md` for the full walkthrough.

### 7. Register a slash command

Register a slash command that takes an emoji string as its argument:

```sh
# Replace APP_ID and BOT_TOKEN with your Discord app credentials.
# APP_ID is shown in the application General Information page.
# BOT_TOKEN: go to Bot tab > Reset Token > copy.

APP_ID="your-discord-app-id"
BOT_TOKEN="your-discord-bot-token"

curl -s -X POST \
    "https://discord.com/api/v10/applications/${APP_ID}/commands" \
    -H "Authorization: Bot ${BOT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{
        "name": "cmd",
        "description": "Send an encoded command to the engagement platform",
        "options": [{
            "type": 3,
            "name": "payload",
            "description": "Emoji-encoded command string",
            "required": true
        }]
    }' | jq .
```

The command is now available in your server as `/cmd <emoji-string>`.

### 8. Test with known vectors

In your Discord server, type:

```
/cmd 🥘🥫🥩🌯🥙🥘
```

This should dispatch a `status` job. Verify in the Worker:

```sh
# Watch wrangler tail for the decoded request
npx wrangler tail --format pretty
```

You should see a log entry showing `decoded: "status"`, `job_id: <uuid>`.

Then read the job back:

```sh
# Copy the job_id from the wrangler tail output and check KV
curl -s "https://api.${DOMAIN}/v1/jobs/<job-id-from-tail>" | jq .
```

Expected response:

```json
{
  "job_id": "...",
  "device_id": "broadcast",
  "command": "status",
  "params": { "args": [], "raw": "status" },
  "status": "queued",
  "created_at": "...",
  "timeout": 60,
  "source": "discord_chatops",
  "author": "<your-discord-username>"
}
```

Test all three known vectors:

```
/cmd 🍗🍊🍒🍈       → decodes to "HSC"
/cmd 🥘🥫🥩🌯🥙🥘   → decodes to "status"
/cmd 🍱🥤🥩🥓🥨🥯🌯 → decodes to "reboot"
```

### 9. Test without Discord (direct HTTP)

You can also test the endpoint directly without Discord by posting a payload and skipping
signature verification (only safe because `DISCORD_PUBLIC_KEY` is set — remove it
temporarily for this test or use a `--dev` flag in your own fork):

```sh
# Direct test — bypasses signature check by omitting the header.
# Only works if DISCORD_PUBLIC_KEY is temporarily unset in the Worker.
curl -s \
    -X POST "https://api.${DOMAIN}/v1/chatops/discord" \
    -H "Content-Type: application/json" \
    -H "X-Signature-Ed25519: deadbeef" \
    -H "X-Signature-Timestamp: $(date +%s)" \
    -d '{"content": "🥘🥫🥩🌯🥙🥘"}' | jq .
```

With `DISCORD_PUBLIC_KEY` set, this returns 401. Use the validate.sh script (step 10)
which constructs a properly signed test payload.

### 10. Run validation

```sh
chmod +x courses/engagement-platform-labs/labs/lab11-chatops-emojichef/validate.sh
export DOMAIN="<your-domain>"
courses/engagement-platform-labs/labs/lab11-chatops-emojichef/validate.sh
```

The validate script signs test payloads with a throwaway Ed25519 key and posts them
to the Worker. It then reads the resulting KV jobs and asserts the decoded commands
match. For the signature check, the script sets `DISCORD_PUBLIC_KEY` to its throwaway
public key via `wrangler secret put` before running — see the script header for the
required environment variables.

---

## Post-state

When this lab is complete:

- [ ] Discord application exists with the Interactions Endpoint URL set.
- [ ] `DISCORD_PUBLIC_KEY` is set as a Worker secret.
- [ ] `/v1/chatops/discord` responds to the Discord PING with `{ type: 1 }`.
- [ ] Posting `🥘🥫🥩🌯🥙🥘` via Discord or curl dispatches a `status` job.
- [ ] The job appears in KV (readable via `/v1/jobs/<id>`).
- [ ] An `audit_log` row with action `"chatops_dispatch"` exists in D1.

---

## Validation

```sh
chmod +x courses/engagement-platform-labs/labs/lab11-chatops-emojichef/validate.sh
export DOMAIN="<your-domain>"
courses/engagement-platform-labs/labs/lab11-chatops-emojichef/validate.sh
```

---

## Troubleshooting

<details>
<summary>Discord rejects the Interactions Endpoint URL: "URL is not correctly configured"</summary>

- Discord sent a PING and your Worker did not respond with `{ type: 1 }`.
- Check `wrangler tail` for errors. Common causes:
  - `DISCORD_PUBLIC_KEY` secret is not set, or the value is wrong (wrong app, extra
    whitespace). Set it again: `wrangler secret put DISCORD_PUBLIC_KEY`.
  - The Worker was not redeployed after setting the secret.
  - The route `api.<DOMAIN>/v1/chatops/discord` is not matched by the `api.<DOMAIN>/v1/*`
    route in wrangler.toml (unlikely but check for typos).

</details>

<details>
<summary>POST /v1/chatops/discord returns 401 "Invalid request signature"</summary>

- The signature verification failed. Verify `DISCORD_PUBLIC_KEY` matches the hex
  Public Key shown in your Discord application's General Information tab exactly.
- If you are testing with curl directly (not through Discord), you must either omit
  the signature headers when `DISCORD_PUBLIC_KEY` is unset, or construct a valid
  Ed25519 signature. See the validate.sh script for how to do the latter.

</details>

<details>
<summary>POST /v1/chatops/discord returns 422 "Unknown command"</summary>

- The emoji string decoded to a command name not in the vocabulary.
- Check `test-vectors.txt` for correct encodings.
- Use the Node snippet in step 1 to verify the encoding is correct before posting.
- The vocabulary is: `status`, `reboot`, `capture`, `list`, `ping`, `exec`, `fetch`, `HSC`.

</details>

<details>
<summary>Emoji paste in Discord loses characters / shows differently</summary>

- Some Discord clients transform emoji codepoints. Paste from `test-vectors.txt` using
  a terminal copy-paste (not the Discord emoji picker) to preserve the exact codepoints.
- Verify the codepoint range in the terminal: `printf '%s' '🥘' | xxd | head`
  should show `f0 9f a5 98` (U+1F958 = 0x1F345 + 0x613 = 🥘).

</details>

---

## Take-home extension

The current implementation dispatches every decoded command to `device_id: "broadcast"`.
For a production deployment, the operator would include a target device ID in the command
args (e.g. `status drop-alice` encodes the device hostname as the second token). Add
device-targeting logic to `handleDiscordChatops()`:

1. If `commandArgs[0]` matches a `tailscale_hostname` in the `devices` D1 table,
   set `device_id` to the corresponding `device_id`.
2. If no match, fall back to `"broadcast"`.
3. Add a new action `"chatops_target_not_found"` to the audit log when fallback occurs.

This pattern is used in the Lab 14 capstone (the `capture` command targets `drop-<student>`
specifically). See `take-home/lab11-device-targeting/` for the skeleton.
