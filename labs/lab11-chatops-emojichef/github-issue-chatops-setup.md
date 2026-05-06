# GitHub issue ChatOps setup for EmojiChef

This guide walks through creating the workshop repository, generating a
fine-grained PAT, configuring the Worker secrets, and wiring the GitHub
webhook so that issue comment events reach your Worker.

---

## Part 1 — Designate or create the workshop repo and issue #1

The Worker uses a single GitHub repository as its command queue. Each student
needs a repo they control with Issues enabled.

**Using an existing fork:**

If you already forked `epl-student-starter` during onboarding, use that repo.
Open the **Issues** tab and confirm it is enabled (Settings > General >
Features > Issues must be checked).

**Creating a fresh repo:**

1. Go to [github.com/new](https://github.com/new).
2. Name the repo (e.g. `eplabs-chatops`). Make it public or private; either
   works.
3. Check **Add a README file** so the repo is non-empty and Issues are
   automatically enabled.
4. Click **Create repository**.

**Create issue #1:**

1. Open your repo and click the **Issues** tab.
2. Click **New issue**.
3. Title it `EPL Command Queue`. Leave the body blank.
4. Click **Submit new issue**.
5. Confirm the URL ends in `/issues/1`.

Note the values you will use in Part 4:

```
GITHUB_OWNER=<your-github-username>
GITHUB_REPO=<your-repo-name>
GITHUB_ISSUE_NUMBER=1
```

---

## Part 2 — Generate a fine-grained PAT (Issues: read+write)

The Worker posts replies on your issue using this token. Scope it to Issues on
this one repo only.

1. Click your avatar (top right on github.com) > **Settings**.
2. In the left sidebar, scroll to the bottom and click **Developer settings**.
3. Click **Personal access tokens** > **Fine-grained tokens**.
4. Click **Generate new token**.

Fill in the form:

- **Token name:** `eplabs-chatops-<your-slot>` (e.g. `eplabs-chatops-alpha`)
- **Expiration:** 30 days (or the duration of your workshop).
- **Description:** optional.
- **Resource owner:** your personal account.
- **Repository access:** select "Only select repositories", then choose the
  workshop repo you created in Part 1.

Under **Permissions > Repository permissions**, find **Issues** and set it to
**Read and write**. All other permissions should remain at "No access".

Click **Generate token**. Copy the token value immediately and store it
somewhere safe for this session. GitHub will not show it again.

---

## Part 3 — Generate a random webhook secret

The Worker and the GitHub webhook configuration must share an identical secret.
Generate one now:

```sh
openssl rand -hex 32
```

Alternative (Python):

```sh
python3 -c 'import secrets; print(secrets.token_hex(32))'
```

Example output (yours will differ):

```
a3f8c21d7b904e56f1234abc9870fedc1a2b3c4d5e6f708192a3b4c5d6e7f890
```

Copy the 64-character hex string. You will paste it into both the Worker
secrets (Part 4) and the GitHub webhook form (Part 5).

---

## Part 4 — Set Worker secrets and [vars]; redeploy

Set both secrets with wrangler:

```sh
cd courses/engagement-platform-labs/labs/lab07-first-worker/worker

npx wrangler secret put GITHUB_WEBHOOK_SECRET
# paste the 64-char hex secret from Part 3 at the prompt

npx wrangler secret put GITHUB_TOKEN
# paste the fine-grained PAT from Part 2 at the prompt
```

Open `worker/wrangler.toml` and add (or update) the `[vars]` section:

```toml
[vars]
# ... existing vars ...
GITHUB_OWNER = "your-github-username"
GITHUB_REPO = "your-repo-name"
GITHUB_ISSUE_NUMBER = "1"
STUDENT_SLOT = "alpha"
```

Replace each value with your actual values. `STUDENT_SLOT` is your assigned
workshop slot (e.g. `alpha`, `bravo`, `charlie`). Commands posted to the issue
must start with `@<STUDENT_SLOT> ` to be accepted by the Worker.

Redeploy so the new vars and secrets take effect:

```sh
npx wrangler deploy
```

Wait for the deployment to confirm with:

```
Published fleet-gateway (...)
  https://api.<your-domain>/v1/*
```

---

## Part 5 — Configure the GitHub repository webhook

1. Open your workshop repo on GitHub.
2. Click **Settings** (the gear icon in the repo top nav).
3. In the left sidebar click **Webhooks**.
4. Click **Add webhook**.

Fill in the webhook form:

- **Payload URL:** `https://api.<your-domain>/v1/chatops/github`
  Substitute your actual domain (e.g. `https://api.a00f3f13.eplabs.cloud/v1/chatops/github`).
- **Content type:** `application/json`
- **Secret:** paste the 64-char hex string from Part 3 (the same value you
  gave to `wrangler secret put GITHUB_WEBHOOK_SECRET`).
- **SSL verification:** Enable SSL verification (leave the default).
- **Which events would you like to trigger this webhook?**
  Select "Let me select individual events". Uncheck **Pushes** (which is
  checked by default), then check **Issue comments** only.
- **Active:** checked.

Click **Add webhook**.

GitHub immediately sends a `ping` event to verify the URL is reachable.

**Verify the ping in Recent Deliveries:**

On the webhook settings page, click the webhook you just created, then click
**Recent Deliveries**. You should see one entry.

- **HTTP 204:** the Worker received the ping, recognized it as a ping event
  (no `action` field present), and returned 204. This is the expected success
  response.
- **HTTP 401:** the HMAC-SHA256 signature did not match. The secret in GitHub
  does not match the `GITHUB_WEBHOOK_SECRET` in the Worker. Regenerate and
  re-enter both (see Troubleshooting below).
- **HTTP 5xx or connection error:** the Worker is not deployed to the correct
  route, or the domain is wrong. Check `wrangler.toml` routes and redeploy.

---

## Part 6 — Send a test comment

Post a test comment on issue #1 in your workshop repo. The comment body must
start with `@<STUDENT_SLOT> ` followed by an emoji-encoded command.

**Via the GitHub web UI:**

1. Open your repo's Issues tab and click issue #1.
2. In the comment box at the bottom, type (or paste):
   ```
   @alpha 🍡🍼🍖🍦🍢🍌🍚🍸
   ```
   Replace `@alpha` with your actual `STUDENT_SLOT`.
3. Click **Comment**.

**Via the GitHub API (from the operator console):**

```sh
curl -s -X POST \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/issues/${GITHUB_ISSUE_NUMBER}/comments" \
  -d "{\"body\":\"@${STUDENT_SLOT} \U0001F958\U0001F96B\U0001F969\U0001F32F\U0001F959\U0001F958\"}"
```

Watch `wrangler tail` in a separate terminal:

```sh
cd courses/engagement-platform-labs/labs/lab07-first-worker/worker
npx wrangler tail --format pretty
```

You should see a log entry containing `decoded: "status"` and a `job_id` UUID.

Shortly after, the bot posts a reply on issue #1. The reply body starts with:

```
[eplabs:result] @alpha status: queued — job_id: <uuid>
```

---

## Part 7 — Verify the job in KV

Copy the `job_id` from the `wrangler tail` output or from the bot reply and
check the KV job store:

```sh
JOB_ID="paste-job-id-here"
curl -s "https://api.${DOMAIN}/v1/jobs/${JOB_ID}" | jq .
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
  "source": "github_chatops",
  "author": "<your-github-username>"
}
```

The `source` field will show `github_chatops` for jobs dispatched through this
endpoint, distinguishing them from jobs created via the REST command API.

---

## Troubleshooting

**Signature failures (HTTP 401 in Recent Deliveries)**

The HMAC-SHA256 digest over the raw request body did not match
`X-Hub-Signature-256`. This means the secret value in GitHub's webhook
configuration and the `GITHUB_WEBHOOK_SECRET` Worker secret are not identical.

Resolution:

1. Generate a new secret: `openssl rand -hex 32`
2. `npx wrangler secret put GITHUB_WEBHOOK_SECRET` and paste the new value.
3. `npx wrangler deploy` to push the updated secret.
4. In GitHub webhook settings, click **Edit**, update the **Secret** field with
   the same new value, click **Update webhook**.
5. Click **Redeliver** on the failing delivery to test without posting a new
   comment.

**Allow-list mismatches (HTTP 422 "Unknown command")**

The emoji decoded successfully but the resulting command string is not in the
Worker's vocabulary. Verify the encoding with the EmojiChef widget in the lab
README before posting. The allowed commands are: `status`, `reboot`, `capture`,
`list`, `ping`, `exec`, `fetch`, `HSC`.

**Prefix gate misses (HTTP 204, no reply posted)**

The comment body did not start with `@<STUDENT_SLOT> `. The Worker checks for
an exact prefix match including the space after the slot name. Common issues:

- Wrong slot name in the comment (e.g. `@Alpha` instead of `@alpha`; case
  sensitive).
- Missing trailing space after the slot name.
- `STUDENT_SLOT` var in `wrangler.toml` does not match what you typed.

**Replay rejects (HTTP 204, logged as "duplicate delivery")**

The Worker tracks `X-GitHub-Delivery` IDs in KV for 600 seconds. If GitHub
resends a delivery (e.g. you clicked "Redeliver" in Recent Deliveries within
10 minutes), the Worker drops it silently with HTTP 204. Wait 10 minutes and
redeliver, or post a new comment to generate a fresh delivery ID.

**401 vs 204 on the ping event**

GitHub sends a ping with a body of `{"zen":"...","hook_id":...,"hook":{...}}`.
The Worker returns HTTP 204 for ping events (no `action` field, not an issue
comment). If you see HTTP 401 on the ping, the secret is wrong (fix above). If
you see HTTP 204 on the ping and the webhook is marked active, that is correct
behavior.

**Bot reply does not appear on the issue**

If the Worker log shows the job was enqueued but no reply appears:

1. Check that `GITHUB_TOKEN` has Issues write permission on the correct repo.
2. Check that `GITHUB_OWNER`, `GITHUB_REPO`, and `GITHUB_ISSUE_NUMBER` in
   `wrangler.toml` `[vars]` match the repo and issue you are posting to.
3. Run `npx wrangler tail` and watch for errors in the reply POST request.

**"Resource not accessible by integration" error from GitHub API**

The fine-grained PAT does not have write access to Issues on the target repo.
Regenerate the token with Issues: read+write on the correct repository (see
Part 2).
