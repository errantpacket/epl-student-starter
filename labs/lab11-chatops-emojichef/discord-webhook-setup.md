# Discord Webhook Setup for EmojiChef ChatOps

This guide walks through creating a Discord application, configuring the
Interactions Endpoint URL (the Worker route), and sending a slash command
that routes through EmojiChef decode.

---

## Part 1 — Create the Discord application

1. Open [discord.com/developers/applications](https://discord.com/developers/applications)
   and sign in.

2. Click **New Application** (top right).

3. Enter a name. Use something identifiable per student, for example:
   `eplabs-chatops-<your-8-char-student-id>`

4. Click **Create**.

5. On the **General Information** tab:
   - Copy the **Application ID** — you need this to register slash commands.
   - Copy the **Public Key** (64-character hex string at the bottom of the page).
     This is `DISCORD_PUBLIC_KEY`.

6. On the **Bot** tab:
   - Click **Add Bot** (or **Reset Token** if the bot already exists).
   - Copy the **Token** — you need this for the slash command registration API call.
   - Under **Privileged Gateway Intents**, leave everything off (not needed for webhooks).

---

## Part 2 — Set the public key as a Worker secret

Before configuring the Interactions Endpoint URL, set the public key so the Worker
can verify the Discord PING:

```sh
cd courses/engagement-platform-labs/labs/lab07-first-worker/worker
npx wrangler secret put DISCORD_PUBLIC_KEY
```

At the prompt, paste the 64-character hex Public Key from step 5 above (no quotes,
no extra whitespace).

Redeploy the Worker so the secret is active:

```sh
npx wrangler deploy
```

---

## Part 3 — Configure the Interactions Endpoint URL

1. Return to your Discord application's **General Information** tab.

2. Find the **Interactions Endpoint URL** field (midway down the page).

3. Enter your Worker's chatops route:
   ```
   https://api.<your-domain>/v1/chatops/discord
   ```
   Replace `<your-domain>` with your actual domain (e.g. `a00f3f13.eplabs.cloud`).

4. Click **Save Changes**.

   Discord immediately POSTs a verification request (`{ "type": 1 }`) to your endpoint.
   Your Worker must respond with `{ "type": 1 }` for Discord to accept the URL.

5. If you see a green checkmark or "Saved", the PING succeeded. If you see an error:
   - Open `wrangler tail` in a terminal and watch for the incoming request.
   - Common failures:
     - Wrong public key → `401 Invalid request signature`
     - Worker not redeployed after setting secret → stale signature verification
     - Route not matched → `404 Not Found` (check `wrangler.toml` route pattern)

---

## Part 4 — Add the app to a Discord server

1. On the **OAuth2** > **URL Generator** tab:
   - Under **Scopes**, check `applications.commands`.
   - Under **Bot Permissions** (appears after selecting bot scope), check `Send Messages`
     (only needed if you want the bot to reply; not required for slash commands).

2. Copy the generated URL and open it in a browser.

3. Select your test server from the dropdown and click **Authorize**.

The application is now in your server and can register slash commands.

---

## Part 5 — Register the `/cmd` slash command

From your terminal (replace the placeholders with your values from Part 1):

```sh
APP_ID="your-application-id"
BOT_TOKEN="your-bot-token"

curl -s -X POST \
    "https://discord.com/api/v10/applications/${APP_ID}/commands" \
    -H "Authorization: Bot ${BOT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{
        "name": "cmd",
        "description": "Send an emoji-encoded command to the engagement platform",
        "options": [
            {
                "type": 3,
                "name": "payload",
                "description": "Emoji-encoded command (e.g. paste from EmojiChef encoder)",
                "required": true
            }
        ]
    }' | jq .
```

Expected response: a JSON object with `"id"` and `"name": "cmd"`.

Global slash commands can take up to 1 hour to propagate. For faster testing during
the workshop, register the command as a guild (server) command instead:

```sh
GUILD_ID="your-server-id"   # Right-click server name > Copy Server ID (enable Dev Mode first)

curl -s -X POST \
    "https://discord.com/api/v10/applications/${APP_ID}/guilds/${GUILD_ID}/commands" \
    -H "Authorization: Bot ${BOT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{
        "name": "cmd",
        "description": "Send an emoji-encoded command to the engagement platform",
        "options": [
            {
                "type": 3,
                "name": "payload",
                "description": "Emoji-encoded command",
                "required": true
            }
        ]
    }' | jq .
```

Guild commands are available immediately.

**Enable Developer Mode in Discord:**
User Settings (gear icon) > Advanced > Developer Mode. This lets you right-click
servers, channels, and users to copy their IDs.

---

## Part 6 — Send a test command

In your Discord server, type `/cmd` and press Tab. The slash command picker should
appear. In the `payload` field, paste one of the known test vectors:

```
🥘🥫🥩🌯🥙🥘
```

(Run the Node encoder from Lab 11 step 1 to get the correct encoding for "status" —
verify it matches what you paste.)

Press Enter. Discord posts the interaction to your Worker's Interactions Endpoint URL.

Watch `wrangler tail` for the decoded result:

```sh
cd courses/engagement-platform-labs/labs/lab07-first-worker/worker
npx wrangler tail --format pretty
```

You should see a log entry with `decoded` and `job_id` fields, confirming the command
was decoded and enqueued.

---

## Part 7 — Verify the job in KV

Copy the `job_id` from the `wrangler tail` output and check KV:

```sh
JOB_ID="paste-job-id-here"
curl -s "https://api.${DOMAIN}/v1/jobs/${JOB_ID}" | jq .
```

Expected:

```json
{
  "job_id": "...",
  "device_id": "broadcast",
  "command": "status",
  "status": "queued",
  ...
}
```

---

## Troubleshooting

**Slash command does not appear in Discord:**
- Global commands can take up to 1 hour. Use a guild command instead (see Part 5).
- The app may not be in the server. Re-run the OAuth2 URL with `applications.commands`
  scope and re-authorize.

**Discord shows "This interaction failed":**
- The Worker must respond within 3 seconds. If the Worker times out, D1 or KV may be
  slow on first invocation after a cold start. Retry — subsequent calls are faster.
- Check `wrangler tail` for the exception.

**`wrangler tail` shows "Ed25519 verification failed":**
- The `DISCORD_PUBLIC_KEY` does not match the app. Double-check by copying the Public
  Key directly from the Discord developer portal (not the bot token — they are different).

**Slash command option value arrives as undefined:**
- The Worker looks for `payload.data.options[0].value`. In Discord interactions, the
  option name must match the registered `"name"` field. If you changed the option name
  from `payload` to something else, update the Worker accordingly.
