# Lab 09 — D1 Device Registry and Audit Log

**Duration: 60 minutes**
**Day:** 2, Session 2

The Worker from Lab 07 has been returning HTTP 501 for `/v1/devices/enroll` and
`/v1/devices` since you deployed it. That ends here. In this lab you provision a
Cloudflare D1 SQLite database, apply the fleet schema, wire the Worker bindings, and
replace both stubs with real INSERT and SELECT logic. By the end, enrolling a device
writes a row to the `devices` table and a corresponding row to `audit_log`; the device
list endpoint reads them back as authenticated JSON.

D1 is the tamper-evident spine of the engagement platform — every action that matters
goes through it.

---

## Learning objectives

- Provision a D1 database with `wrangler d1 create` and understand the `database_id`.
- Apply a SQL schema file with `wrangler d1 execute --file --remote`.
- Wire a D1 binding in `wrangler.toml` (`[[d1_databases]]`) and redeploy.
- Read and write D1 from a Worker using prepared statements with positional parameters.
- Understand `INSERT ... ON CONFLICT DO UPDATE` (upsert) for idempotent re-enrollment.
- Query the audit log directly via `wrangler d1 execute` as an operator tool.

---

## Pre-state

Before starting, confirm:

```sh
# Lab 07 Worker is deployed and /v1/health returns 200
curl -sf https://api.${DOMAIN}/v1/health | jq .ok
# Expected: true

# wrangler is authenticated
wrangler whoami

# DOMAIN is exported
echo "${DOMAIN}"
```

Confirm that enroll still returns 501 (it should — Lab 07 stubs are in place):

```sh
curl -s -o /dev/null -w "%{http_code}" \
    -X POST https://api.${DOMAIN}/v1/devices/enroll
# Expected: 501
```

---

## Walkthrough

### 1. Create the D1 database

```sh
cd courses/engagement-platform-labs/labs/lab07-first-worker/worker
npx wrangler d1 create fleet-database
```

Expected output:

```
Successfully created DB 'fleet-database'
Created your new D1 database.

[[d1_databases]]
binding = "FLEET_DB"
database_name = "fleet-database"
database_id = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

Copy the `database_id` value — you need it in the next step.

### 2. Update wrangler.toml with your database_id

Open `worker/wrangler.toml`. The `[[d1_databases]]` block is already present and
uncommented. Replace `YOUR_D1_DATABASE_ID` with the UUID from step 1:

```toml
[[d1_databases]]
binding       = "FLEET_DB"
database_name = "fleet-database"
database_id   = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

Or use sed:

```sh
DB_ID="paste-your-database_id-here"
sed -i "s/YOUR_D1_DATABASE_ID/${DB_ID}/" wrangler.toml
```

Verify:

```sh
grep "database_id" wrangler.toml
# Should show your UUID, not the placeholder
```

### 3. Apply the schema

The schema file is at `labs/lab09-d1-database/schema.sql`. It creates three tables:
`devices`, `audit_log`, and `sessions`, plus indices on hot query columns.

Run the migration wrapper:

```sh
cd courses/engagement-platform-labs/labs/lab09-d1-database
chmod +x migrate.sh
./migrate.sh
```

Or run directly:

```sh
cd courses/engagement-platform-labs/labs/lab07-first-worker/worker
npx wrangler d1 execute fleet-database \
    --file=../../../lab09-d1-database/schema.sql \
    --remote
```

Verify the tables were created:

```sh
npx wrangler d1 execute fleet-database \
    --command="SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;" \
    --remote
```

Expected output:

```
┌───────────┐
│ name      │
├───────────┤
│ audit_log │
│ devices   │
│ sessions  │
└───────────┘
```

### 4. Review the schema

Open `labs/lab09-d1-database/schema.sql` and read through it. Key design decisions:

- `devices.device_id` is the primary key — a stable hardware identifier (e.g. the
  value from `/proc/cpuinfo Serial` on MIPS, or a UUID set at image build time).
- `INSERT ... ON CONFLICT DO UPDATE` in the Worker means re-enrolling a device
  (after a reboot or re-flash) is safe — it updates `last_seen` and `tailscale_hostname`
  without creating a duplicate row.
- `audit_log` is append-only — the Worker never DELETEs or UPDATEs rows here.
  `device_id` is nullable because some audit events (operator login, schema migration)
  are not scoped to a specific device.
- `sessions` is for Lab 12 operator sessions. It is created now so the schema migration
  is a single operation.
- Indices on `devices(last_seen)` and `audit_log(device_id, created_at)` keep the
  device list query and audit queries fast even with thousands of rows.

### 5. Review the Worker code

The `handleEnroll()` and `handleDeviceList()` functions in
`labs/lab07-first-worker/worker/src/index.js` are now fully implemented. Read both
functions before deploying. Key points:

**handleEnroll:**
- Validates `CF-Access-Client-Id` and `CF-Access-Client-Secret` headers (device service
  token from Lab 08). Requests without these return 401.
- Requires `device_id`, `device_type`, and `tailscale_hostname` in the JSON body.
- Generates a `tag` string (`device-<type>-<ts>`) used for Tailscale ACL scoping.
- Upserts the device row: first enrollment INSERTs; subsequent re-enrollments UPDATE
  `last_seen` and hostname.
- Always writes an `audit_log` row with action `"enroll"`.

**handleDeviceList:**
- Requires `CF-Access-Jwt-Assertion` header (operator JWT from CF Access). Requests
  without this return 401.
- SELECTs all devices ordered by `last_seen DESC`.
- Parses the `metadata` JSON blob and adds a computed `status` field (`"online"` if
  `last_seen` is within the last 5 minutes).

The `logAudit()` utility is shared — Labs 10 and 11 also call it. It silently swallows
errors so an audit write failure never breaks the primary request path.

### 6. Redeploy the Worker

```sh
cd courses/engagement-platform-labs/labs/lab07-first-worker/worker
npx wrangler deploy
```

The deploy output should still show the same route. The binding change takes effect
immediately on deploy.

### 7. Test enrollment

Use a fake device payload. The service token headers can be any non-empty strings for
testing — in production they must match the token you created in Lab 08.

```sh
curl -s \
    -X POST "https://api.${DOMAIN}/v1/devices/enroll" \
    -H "CF-Access-Client-Id: test-client-id" \
    -H "CF-Access-Client-Secret: test-client-secret" \
    -H "Content-Type: application/json" \
    -d '{
        "device_id": "lab09-test-device",
        "device_type": "mango",
        "tailscale_hostname": "drop-lab09.tailnet.ts.net",
        "metadata": { "test": true }
    }' | jq .
```

Expected response:

```json
{
  "enrolled": true,
  "tag": "device-mango-1700000000000",
  "device_id": "lab09-test-device",
  "tailscale_hostname": "drop-lab09.tailnet.ts.net"
}
```

### 8. Test the device list

```sh
# Get a CF Access JWT for your operator account first.
# In the devcontainer, wrangler can produce a test token:
TOKEN=$(npx wrangler access token "https://api.${DOMAIN}")

curl -s \
    -H "CF-Access-Jwt-Assertion: ${TOKEN}" \
    "https://api.${DOMAIN}/v1/devices" | jq .
```

Expected response (truncated):

```json
[
  {
    "device_id": "lab09-test-device",
    "device_type": "mango",
    "tag": "device-mango-1700000000000",
    "tailscale_hostname": "drop-lab09.tailnet.ts.net",
    "enrolled_at": "2024-09-23 10:00:00",
    "last_seen": "2024-09-23 10:00:00",
    "metadata": { "test": true },
    "status": "online"
  }
]
```

### 9. Inspect the audit log directly

```sh
cd courses/engagement-platform-labs/labs/lab07-first-worker/worker
npx wrangler d1 execute fleet-database \
    --command="SELECT * FROM audit_log ORDER BY created_at DESC LIMIT 5;" \
    --remote
```

You should see one row with `action = "enroll"` and `device_id = "lab09-test-device"`.

### 10. Re-enroll the same device

Run the enrollment curl from step 7 again without changing the `device_id`. The
response should be identical (same `device_id`), but the device row is updated rather
than duplicated. Verify:

```sh
npx wrangler d1 execute fleet-database \
    --command="SELECT COUNT(*) as count FROM devices WHERE device_id='lab09-test-device';" \
    --remote
# count: 1  (not 2)

npx wrangler d1 execute fleet-database \
    --command="SELECT COUNT(*) as count FROM audit_log WHERE device_id='lab09-test-device';" \
    --remote
# count: 2  (one row per enrollment call)
```

This is the correct behavior: the device table has one row per device; the audit log
has one row per event.

---

## Post-state

When this lab is complete:

- [ ] `fleet-database` D1 database exists in your Cloudflare account.
- [ ] `wrangler.toml` `database_id` is set to your actual UUID.
- [ ] `schema.sql` applied — `devices`, `audit_log`, `sessions` tables exist.
- [ ] `/v1/devices/enroll` returns HTTP 200 with `enrolled: true`.
- [ ] `/v1/devices` returns a JSON array (may be empty if you cleared test data).
- [ ] `audit_log` contains an `"enroll"` row for the test device.

---

## Validation

```sh
chmod +x courses/engagement-platform-labs/labs/lab09-d1-database/validate.sh
export DOMAIN="<your-domain>"
courses/engagement-platform-labs/labs/lab09-d1-database/validate.sh
```

The script enrolls a synthetic device, fetches the device list, and queries D1
directly for the audit log row. It exits 0 on success.

---

## Troubleshooting

<details>
<summary>Worker returns "FLEET_DB is not defined" or 500 on /v1/devices/enroll</summary>

- The `database_id` placeholder was not replaced. Check `wrangler.toml` for
  `YOUR_D1_DATABASE_ID` and substitute your real UUID.
- The Worker may not have been redeployed after editing `wrangler.toml`. Run
  `npx wrangler deploy` again.
- Confirm the binding appears in the deployed Worker: Cloudflare dashboard >
  Workers & Pages > fleet-gateway > Settings > Bindings.

</details>

<details>
<summary>wrangler d1 execute fails: "database not found"</summary>

- The database name must match exactly: `fleet-database` (hyphen, lowercase).
- Run `wrangler d1 list` to confirm the database exists in your account.
- If it does not exist, re-run `wrangler d1 create fleet-database`.

</details>

<details>
<summary>/v1/devices returns 401 "Unauthorized"</summary>

- The `CF-Access-Jwt-Assertion` header is required. The simplest way to get a valid
  token in development: use `wrangler access token <URL>` from the devcontainer, or
  temporarily bypass the check by removing the header guard (revert after testing).
- In production, ensure your operator browser session is authenticated with CF Access.

</details>

<details>
<summary>schema.sql apply fails: "table already exists"</summary>

- `schema.sql` uses `CREATE TABLE IF NOT EXISTS` — this should never fail on a fresh
  database. If you see this error, the schema was partially applied.
- Run the SELECT on `sqlite_master` (step 3) to see which tables exist.
- The schema is idempotent: re-running it is safe.

</details>

<details>
<summary>Re-enrollment creates a duplicate row instead of upserting</summary>

- D1 requires SQLite `ON CONFLICT` syntax. The prepared statement in `handleEnroll()`
  uses `INSERT INTO ... ON CONFLICT(device_id) DO UPDATE SET ...`. If you edited the
  Worker and changed this to `INSERT OR REPLACE`, a new `enrolled_at` is written and
  the old row is deleted then re-inserted — functionally equivalent but changes
  `enrolled_at`. Use the upsert form to preserve `enrolled_at`.

</details>

---

## Take-home extension

The `sessions` table is created but unused in the in-class labs. As a take-home
exercise, add a `/v1/sessions` endpoint to the Worker that:

1. Accepts a CF Access JWT in the header.
2. Decodes the JWT (Workers have access to `crypto.subtle` for JWT verification using
   the CF Access public key from `https://<team>.cloudflareaccess.com/cdn-cgi/access/certs`).
3. Inserts a session row with a UUID and a 1-hour expiry.
4. Returns the session UUID.

This gives you a server-side session store backed by D1 — useful for operator tooling
that needs to correlate multiple requests without re-validating the JWT each time.

See `take-home/lab09-sessions/` for the solution skeleton.
