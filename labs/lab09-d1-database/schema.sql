-- fleet-database schema
-- Applied via: wrangler d1 execute fleet-database --file=schema.sql --remote
-- Source: docs/technical_specifications.md Worker template + added indices / constraints.
--
-- Note: D1 rejects PRAGMA statements with SQLITE_AUTH; the engine runs in WAL
-- mode by default, so the explicit PRAGMA below was removed during the
-- 2026-05-05 walk (delivery-notes §11.9).

-- ---------------------------------------------------------------------------
-- devices
-- Primary registry for all enrolled engagement-platform nodes and drop devices.
-- device_id is a stable hardware identifier (e.g. /proc/cpuinfo Serial on MIPS).
-- tag is generated at enrollment time and used for Tailscale ACL scoping.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS devices (
    device_id          TEXT    NOT NULL PRIMARY KEY,
    device_type        TEXT    NOT NULL,                      -- 'mango' | 'engagement-platform' | ...
    tag                TEXT    NOT NULL,                      -- e.g. device-mango-<ts>
    tailscale_hostname TEXT    NOT NULL,
    engagement_id      TEXT    NOT NULL DEFAULT 'workshop',
    metadata           TEXT    NOT NULL DEFAULT '{}',         -- JSON blob
    enrolled_at        TEXT    NOT NULL DEFAULT (datetime('now')),
    last_seen          TEXT    NOT NULL DEFAULT (datetime('now')),
    CHECK (json_valid(metadata))
);

CREATE INDEX IF NOT EXISTS idx_devices_last_seen
    ON devices (last_seen);

CREATE INDEX IF NOT EXISTS idx_devices_engagement_id
    ON devices (engagement_id);

-- ---------------------------------------------------------------------------
-- audit_log
-- Append-only record of every operator action and device event.
-- device_id is nullable because some actions (operator login, health check)
-- are not scoped to a specific device.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit_log (
    id          INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    operator_id TEXT,
    device_id   TEXT,
    action      TEXT    NOT NULL,
    details     TEXT    NOT NULL DEFAULT '{}',   -- JSON blob
    source_ip   TEXT,
    user_agent  TEXT,
    created_at  TEXT    NOT NULL DEFAULT (datetime('now')),
    CHECK (json_valid(details))
);

CREATE INDEX IF NOT EXISTS idx_audit_log_device_id
    ON audit_log (device_id);

CREATE INDEX IF NOT EXISTS idx_audit_log_action
    ON audit_log (action);

CREATE INDEX IF NOT EXISTS idx_audit_log_created_at
    ON audit_log (created_at);

-- ---------------------------------------------------------------------------
-- sessions
-- Short-lived operator sessions issued after CF Access JWT validation.
-- Expires column is a Unix epoch integer for fast TTL comparisons.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sessions (
    session_id  TEXT    NOT NULL PRIMARY KEY,     -- UUID
    operator_id TEXT    NOT NULL,
    expires     INTEGER NOT NULL,                 -- Unix epoch seconds
    metadata    TEXT    NOT NULL DEFAULT '{}',
    created_at  TEXT    NOT NULL DEFAULT (datetime('now')),
    CHECK (json_valid(metadata))
);

CREATE INDEX IF NOT EXISTS idx_sessions_operator_id
    ON sessions (operator_id);

CREATE INDEX IF NOT EXISTS idx_sessions_expires
    ON sessions (expires);
