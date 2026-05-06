# Take-home: Discord transport variant

## Why Discord is the take-home

The primary path for Lab 11 uses GitHub issue comments as the command queue.
That choice is deliberate: GitHub traffic is indistinguishable from ordinary
developer activity, the issue thread provides a persistent audit log without
any additional infrastructure, and the webhook contract (HMAC-SHA256,
JSON body, standard HTTPS POST) matches the shape of most production alerting
and CI systems.

Discord is the demo-friendly alternative. It is faster to observe in real time
and easier to share with non-technical audiences, but it is less realistic as
an operator TTP. Running the Discord variant as a take-home exercise is the
most useful framing: you have already built the full pipeline once (encoder,
signature verification, KV job queue, result reply), so the take-home is
strictly about substituting the transport layer.

## The substitution surface

Only one layer changes when you swap GitHub for Discord:

| Layer | GitHub (primary) | Discord (take-home) |
|---|---|---|
| Signature algorithm | HMAC-SHA256 (`X-Hub-Signature-256`) | Ed25519 (`X-Signature-Ed25519` + `X-Signature-Timestamp`) |
| Authentication material | Shared webhook secret | Application public key |
| Invocation form | Issue comment starting with `@<slot>` | Slash command interaction (`payload.data.options[0].value`) |
| Result delivery | POST to GitHub Issues API | Respond with `{ type: 4, data: { content: "..." } }` in the interaction response |
| Ping/verification | None (HTTP 204 on ping event) | `{ type: 1 }` PING/PONG exchange before URL is accepted |

Everything below the transport stays identical:

- EmojiChef encoder and decoder (`EmojiChefQuick` class)
- KV job queue shape (`enqueueJob`, `RATE_LIMITS`)
- Tailnet dispatch and device targeting
- R2 signed URL generation
- D1 audit log schema and `chatops_dispatch` action

The `handleDiscordChatops` handler in `labs/lab07-first-worker/worker/src/index.js`
is already wired. The `/v1/chatops/discord` route stays active. Discord secrets
are optional: if `DISCORD_PUBLIC_KEY` is not set, the Worker runs the Discord
handler in degraded mode (signature verification is skipped). This means you
can test the decode path without a Discord application, but a real deployment
must have the public key set.

## Setup

Follow the full Discord setup guide in `discord-webhook-setup.md` (in this
directory). The guide covers:

1. Creating a Discord application and copying the public key.
2. Setting `DISCORD_PUBLIC_KEY` as a Worker secret.
3. Configuring the Interactions Endpoint URL.
4. Adding the app to a test server.
5. Registering the `/cmd` slash command.
6. Sending a test command and verifying the KV job.

## Relationship to the primary lab

The `validate.sh` in the parent directory (`lab11-chatops-emojichef/validate.sh`)
tests the GitHub path only. There is no separate validate script for the Discord
variant; use `wrangler tail` and manual inspection of the KV job to confirm the
round-trip works.
