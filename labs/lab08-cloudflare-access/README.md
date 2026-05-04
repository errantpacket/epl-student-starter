# Lab 08 — Cloudflare Access: Operator SSO + Service Tokens

**Duration: 45 minutes**
**Day:** 2, Session 2

The Worker you deployed in Lab 07 is currently open to the internet. Anyone who discovers
the URL can reach it. Cloudflare Access solves this by placing an identity-enforcing
reverse proxy in front of your Worker route — before a request even reaches the Worker
code.

This lab creates two authentication modes that the engagement platform uses throughout
Day 2:

1. **Operator JWT** — your browser or curl session proves identity via a one-time PIN sent
   to your email. CF Access sets a signed JWT cookie that the Worker (and later labs) can
   verify.
2. **Device service token** — a static `CF-Access-Client-Id` + `CF-Access-Client-Secret`
   header pair that the Mango drop device uses to authenticate enrollment requests. No
   browser. No human in the loop. Issued once; stored in `output/access-tokens.json`.

Lab 12 reads `output/access-tokens.json` and bakes those credentials into the Mango
firmware image. If you lose or rotate the service token, you must rebuild the Mango image.

---

## Learning objectives

- Create a Cloudflare Zero Trust Access Application protecting a Worker route.
- Configure an email-based identity policy (operator access).
- Mint a machine-to-machine service token (device access).
- Validate all three authentication states: unauthenticated (401), JWT (200), service
  token (200).
- Understand the difference between CF Access app-level protection and Worker-level
  token validation.

---

## Pre-state

Before starting this lab confirm:

```sh
# Lab 07 Worker is deployed and health endpoint works
curl -sf https://api.${DOMAIN}/v1/health | grep '"ok":true'

# wrangler is authenticated
wrangler whoami

# Zero Trust is enabled on your Cloudflare account
# (Free plan includes it — verify in: cloudflare.com > Zero Trust sidebar entry)

# DOMAIN is set
echo "${DOMAIN}"
```

If the Zero Trust sidebar does not appear in your Cloudflare dashboard, navigate to
`one.dash.cloudflare.com` and complete the one-time Zero Trust onboarding (free, takes
under 2 minutes).

---

## Walkthrough

### 1. Open Zero Trust dashboard

1. Log in to `cloudflare.com`.
2. Select your account (top-left dropdown if you have multiple).
3. Click **Zero Trust** in the left sidebar (or navigate to `one.dash.cloudflare.com`).

You should see the Zero Trust overview page with Access, Gateway, and Tunnel sections.

### 2. Create the Access Application

1. In Zero Trust, go to **Access > Applications**.
2. Click **Add an application**.
3. Select **Self-hosted**.

Fill in the form:

| Field | Value |
|---|---|
| Application name | `fleet-gateway-api` |
| Application domain | `api.<your-domain>` |
| Path | `/v1/*` |
| Session duration | `24h` |

Click **Next**.

**Instructor note:** The "Path" field restricts Access to paths matching `/v1/*`. Requests
to `api.<domain>/` (tunnel passthrough) are NOT protected by this policy. This is correct
— the tunnel origin for the devcontainer is separate from the Worker's API surface.

### 3. Configure the operator email policy

On the **Policies** page:

1. Click **Add a policy**.
2. Policy name: `operator-email-allowlist`
3. Action: **Allow**
4. In the **Include** section, click **Add require**.
5. Selector: **Emails** — enter `<your-email>` and `<instructor-email>`.

   Example: `student@example.com`, `instructor@eplabs.cloud`.

6. Click **Save policy**.
7. Click **Next** through the remaining wizard pages and click **Add application**.

You now have an Access Application. The Worker route `api.<domain>/v1/*` requires
authentication to reach. Unauthenticated requests receive a Cloudflare Access login page
(or 401 for API clients that send `Accept: application/json`).

### 4. Test operator browser authentication

Open a **private / incognito window** and navigate to:

```
https://api.<your-domain>/v1/health
```

You should see a Cloudflare Access login page ("Enter your email to continue").

Enter your email. Cloudflare sends a one-time PIN. Enter the PIN. You are redirected to
the health endpoint, which now returns the JSON response.

Cloudflare has set a `CF_Authorization` cookie in your browser session. This cookie is
the operator JWT. Its presence is what the Worker can check in later labs.

### 5. Test that unauthenticated API requests receive 401

Without a valid session or service token, API clients (curl, the Mango) cannot reach the
Worker:

```sh
# No authentication — should return 401 or Cloudflare Access redirect
curl -s -o /dev/null -w "%{http_code}" https://api.${DOMAIN}/v1/health
# Expected: 401
```

If you see 302 instead of 401, add `-L` to follow the redirect — it will land on the
Access login page (HTML). The `validate.sh` script checks for 401; if your Access policy
returns a redirect instead, add `-L` and check for the HTML login page pattern. See the
troubleshooting section.

### 6. Mint a device service token

Service tokens are machine-to-machine credentials. The Mango uses them to POST to
`/v1/devices/enroll` without a browser.

1. In Zero Trust, go to **Access > Service Auth > Service Tokens**.
2. Click **Create Service Token**.
3. Token name: `mango-drop-<your-student-id>` (use a unique name that identifies your kit).
4. Set the token duration to **1 year** (or to the end of the workshop period).
5. Click **Generate Token**.

You will see two values — **Client ID** and **Client Secret**. The secret is shown
only once. Copy both now.

```
CF_ACCESS_CLIENT_ID=<paste here>
CF_ACCESS_CLIENT_SECRET=<paste here>
```

**Do not close this page until you have saved both values.**

### 7. Attach the service token to the Access Application

The service token exists, but it is not yet authorized to reach `fleet-gateway-api`.

1. Go back to **Access > Applications** and click **Configure** next to `fleet-gateway-api`.
2. Click **Edit** on the `operator-email-allowlist` policy.
3. Under **Include**, click **Add require**.
4. Selector: **Service Token** — select `mango-drop-<your-student-id>`.
5. Click **Save policy**.

The Access Application now accepts two authentication modes: operator email JWT or the
device service token.

### 8. Test service token authentication

```sh
# Export the credentials minted in step 6
export CF_ACCESS_CLIENT_ID="<your-client-id>"
export CF_ACCESS_CLIENT_SECRET="<your-client-secret>"

# Authenticated request using service token headers
curl -s \
    -H "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}" \
    -H "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}" \
    https://api.${DOMAIN}/v1/health

# Expected: {"ok":true,"version":"1.0.0","timestamp":"..."}
```

The request reaches the Worker and returns the health response.

### 9. Save credentials for Lab 12

Lab 12's `bake-secrets.sh` reads `output/access-tokens.json` to inject the service token
into the Mango firmware image. Create that file now:

```sh
mkdir -p courses/engagement-platform-labs/labs/lab08-cloudflare-access/output

cat > courses/engagement-platform-labs/labs/lab08-cloudflare-access/output/access-tokens.json <<EOF
{
  "service_token_id": "${CF_ACCESS_CLIENT_ID}",
  "service_token_secret": "${CF_ACCESS_CLIENT_SECRET}",
  "access_app_domain": "api.${DOMAIN}",
  "access_app_path": "/v1/*",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "note": "Service token for Mango drop device enrollment. Read by lab12 bake-secrets.sh."
}
EOF
```

Verify the file was written:

```sh
cat courses/engagement-platform-labs/labs/lab08-cloudflare-access/output/access-tokens.json
```

The `output/` directory is `.gitignored` — credentials do not end up in the repo.

---

## Post-state

When this lab is complete:

- [ ] Access Application `fleet-gateway-api` exists in Zero Trust dashboard.
- [ ] `curl -s -o /dev/null -w "%{http_code}" https://api.${DOMAIN}/v1/health` returns 401 (no auth).
- [ ] The same curl with `CF-Access-Client-Id` / `CF-Access-Client-Secret` headers returns 200.
- [ ] `output/access-tokens.json` exists with both `service_token_id` and `service_token_secret` fields.
- [ ] Operator browser flow (email + one-time PIN) works and sets the `CF_Authorization` cookie.

---

## Validation

Export the service token credentials, then run:

```sh
export DOMAIN="<your-domain>"
export CF_ACCESS_CLIENT_ID="<your-client-id>"
export CF_ACCESS_CLIENT_SECRET="<your-client-secret>"

bash courses/engagement-platform-labs/labs/lab08-cloudflare-access/validate.sh
```

Or make it executable and run directly:

```sh
chmod +x courses/engagement-platform-labs/labs/lab08-cloudflare-access/validate.sh
courses/engagement-platform-labs/labs/lab08-cloudflare-access/validate.sh
```

The script runs three curl assertions:
1. Unauthenticated request → 401.
2. Service token headers → 200 with correct JSON body.
3. Invalid service token → 401.

---

## Troubleshooting

<details>
<summary>Unauthenticated curl returns 302 instead of 401</summary>

Cloudflare Access returns a redirect to the login page for browser-like requests. API
clients that send `Accept: application/json` receive 401 directly. The `validate.sh`
script explicitly sends an API-style request. If you are testing manually, use:

```sh
curl -s -D - -o /dev/null -H "Accept: application/json" \
    https://api.${DOMAIN}/v1/health
```

If you still see 302, check the Access Application settings — the "Session behavior" may
be set to "Redirect to login page" for all clients. This is standard CF Access behavior;
the validate script works around it by checking for either 401 or a redirect to
`cloudflareaccess.com`.

</details>

<details>
<summary>Service token curl returns 401</summary>

- Confirm you saved the Client ID and Client Secret correctly. The Client ID ends in
  `.access` and the Client Secret is a long random string. They are separate — a common
  mistake is using the same value for both headers.
- Confirm the service token is attached to the `fleet-gateway-api` Access Application
  (step 7). A service token exists at the account level but must be explicitly allowed
  by each Access Application policy.
- Check token expiry. If the token duration was set to a short value during testing,
  it may have expired. Regenerate and update `output/access-tokens.json`.

</details>

<details>
<summary>Access Application wizard doesn't show "Service Token" as a selector</summary>

Service tokens appear as a policy selector only after at least one token has been created.
Complete step 6 first, then return to step 7 to attach it.

</details>

<details>
<summary>Browser flow redirects to login page but one-time PIN is never received</summary>

- Check spam / junk folder.
- Cloudflare Access sends from `no-reply@notify.cloudflare.com`. Add this to your
  safe-senders list.
- The PIN is valid for 10 minutes. If it has expired, start the flow again from a fresh
  incognito window.

</details>

<details>
<summary>output/access-tokens.json already exists with wrong values</summary>

Delete it and re-run the `cat >` heredoc from step 9 with the correct exported values.
The file is not tracked by git, so deleting it is safe.

</details>

---

## Take-home extension

**Workers.dev subdomain gap.** As noted in Lab 07, the workers.dev subdomain
(`fleet-gateway.<cf-subdomain>.workers.dev`) bypasses CF Access entirely because CF Access
protects the custom domain route, not the workers.dev URL. To close this gap in a
production deployment:

1. In the Cloudflare dashboard, go to Workers & Pages > fleet-gateway > Settings >
   Domains & Routes.
2. Disable the workers.dev route.

This makes the custom domain the only entry point, closing the bypass.

**Rotating service tokens.** If a service token is compromised, regenerate it in
Zero Trust > Access > Service Auth, update `output/access-tokens.json`, and rebuild
the Mango image (Lab 12). This is the incident-response drill for Lab 14's take-home
extension.

**JWT verification in the Worker.** CF Access sets a `CF-Access-Jwt-Assertion` header
on every authenticated request. In Lab 09, `handleDeviceList()` will check this header.
Preview the full reference implementation in
`docs/technical_specifications.md` lines 293–321 to see how the Worker reads this header.
