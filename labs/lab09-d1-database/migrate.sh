#!/bin/sh
# migrate.sh — apply schema.sql to the remote fleet-database D1 database.
# Run from the repo root or from within this lab directory.
# Requires: wrangler authenticated (wrangler whoami).
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCHEMA="${SCRIPT_DIR}/schema.sql"
DB_NAME="fleet-database"

if ! command -v wrangler >/dev/null 2>&1; then
    echo "ERROR: wrangler not found. Install with: npm install -g wrangler@4"
    exit 1
fi

echo "Applying schema to D1 database: ${DB_NAME}"
echo "Schema file: ${SCHEMA}"
echo ""

# Execute against the remote (deployed) database.
# To apply locally for testing, add: --local
wrangler d1 execute "${DB_NAME}" \
    --file="${SCHEMA}" \
    --remote

echo ""
echo "Schema applied. Verify tables with:"
echo "  wrangler d1 execute ${DB_NAME} --command=\"SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;\" --remote"
