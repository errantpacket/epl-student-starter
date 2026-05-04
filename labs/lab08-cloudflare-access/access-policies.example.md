# Access Policies Reference — Lab 08

This document describes the two Cloudflare Access policies configured in the Zero Trust
dashboard during Lab 08. CF Access policies are not currently configurable via wrangler
or Terraform in a way that is practical for a workshop setting; they require dashboard
clicks. Use this document as a reference if you need to recreate them after an account
reset, or if you are pre-staging the environment before the workshop.

---

## Access Application: fleet-gateway-api

| Setting | Value |
|---|---|
| Type | Self-hosted |
| Application name | `fleet-gateway-api` |
| Application domain | `api.<student>.eplabs.cloud` |
| Path | `/v1/*` |
| Session duration | 24 hours |
| App Launcher visibility | Off (not user-facing) |

The path `/v1/*` means only requests to `api.<domain>/v1/...` are gated by Access.
The root path `api.<domain>/` (cloudflared tunnel passthrough to devcontainer nginx)
is NOT behind Access — this is intentional during the workshop for operator debugging.

In a production deployment you would extend the path to `/*` and disable the
workers.dev subdomain route as described in the Lab 08 take-home extension.

---

## Policy 1: operator-email-allowlist

**Purpose:** Allow instructor and student operator access via email identity (one-time PIN).

| Setting | Value |
|---|---|
| Policy name | `operator-email-allowlist` |
| Action | Allow |
| Session duration | (inherit from application — 24h) |

**Include rule:**

| Selector | Value |
|---|---|
| Emails | `<student-email>`, `<instructor-email>` |

For the workshop, the instructor email is `instructor@eplabs.cloud` (or whatever the
instructor uses). Each student adds their own email.

**How to click through the dashboard:**

1. Zero Trust > Access > Applications > fleet-gateway-api > Configure.
2. Policies tab > Add a policy.
3. Policy name: `operator-email-allowlist`, Action: Allow.
4. Include section: selector = Emails, values = student + instructor email addresses.
5. Save policy.

---

## Policy 2: device-service-token

**Purpose:** Allow Mango drop devices (and the devcontainer during testing) to authenticate
using static service token credentials — no browser, no human interaction.

| Setting | Value |
|---|---|
| Policy name | `device-service-token` |
| Action | Allow |
| Session duration | (inherit from application — 24h) |

**Include rule:**

| Selector | Value |
|---|---|
| Service Token | `mango-drop-<student-id>` |

The service token must be created first (Zero Trust > Access > Service Auth > Service
Tokens > Create Service Token) before it appears as a selectable option in the policy.

**How to click through the dashboard:**

1. Zero Trust > Access > Service Auth > Service Tokens > Create Service Token.
   - Name: `mango-drop-<student-id>` (e.g. `mango-drop-a00f3f13`).
   - Duration: 1 year.
   - Click Generate Token. Copy both Client ID and Client Secret immediately.
2. Zero Trust > Access > Applications > fleet-gateway-api > Configure.
3. Policies tab — edit `operator-email-allowlist` (or add a second policy).
4. Include section: add selector = Service Token, value = the token you just created.
5. Save policy.

**Why edit the existing policy rather than create a separate one?**

CF Access evaluates policies with OR semantics by default: a request matches if it
satisfies ANY policy on the application. Adding the service token selector to the existing
policy (alongside the email selector) achieves the same effect as a second policy and
keeps the policy list cleaner. Either approach works.

---

## output/access-tokens.json schema

Lab 12's `bake-secrets.sh` reads this file. The fields are:

```json
{
  "service_token_id":     "<CF-Access-Client-Id header value>",
  "service_token_secret": "<CF-Access-Client-Secret header value>",
  "access_app_domain":    "api.<student>.eplabs.cloud",
  "access_app_path":      "/v1/*",
  "created_at":           "<ISO 8601 timestamp>",
  "note":                 "Service token for Mango drop device enrollment."
}
```

`bake-secrets.sh` uses `service_token_id` and `service_token_secret` to substitute
`{{SERVICE_TOKEN_ID}}` and `{{SERVICE_TOKEN_SECRET}}` in the
`files-mango/etc/uci-defaults/99-enroll.sh.template`.

The file must be at:

```
courses/engagement-platform-labs/labs/lab08-cloudflare-access/output/access-tokens.json
```

This path is `.gitignored` — it must not be committed to the repository.

---

## Security notes

- Service tokens are long-lived by default. Use the shortest practical duration for your
  workshop window (1 year covers lab rotation; 7 days covers a single cohort).
- If a token is compromised, revoke it in Zero Trust > Access > Service Auth > Service
  Tokens, regenerate, update `output/access-tokens.json`, and rebuild the Mango image.
- The Client Secret is shown only once at generation time. If you lose it, you cannot
  retrieve it — you must revoke the token and generate a new one.
- Operator JWTs (browser flow) expire per the session duration (24h). Students who return
  the next day will need to re-authenticate via email OTP.
