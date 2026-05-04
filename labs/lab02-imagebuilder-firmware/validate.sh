#!/bin/sh
# Lab 02 — validate.sh
# Checks that both firmware contracts produced expected artifacts and that
# the drop-mango .bin fits within the 16MB NOR flash ceiling.
#
# Usage:
#   bash labs/lab02-imagebuilder-firmware/validate.sh
#
# Make executable once after cloning:
#   chmod +x labs/lab02-imagebuilder-firmware/validate.sh
#
# May be run from inside the devcontainer or on the host (requires python3).

set -eu

# ---------------------------------------------------------------------------
# Locate labs/ directory relative to this script
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LABS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$LABS_DIR/output"
SCHEMA="$LABS_DIR/shared/build-manifest.schema.json"

MANGO_PROFILE="glinet_gl-mt300n-v2"

# Hard ceiling: full 16MB NOR chip size in bytes.
# The build script enforces a tighter squashfs-only ceiling (13MB); this
# validator checks the complete sysupgrade .bin against the absolute chip size.
NOR_CEILING_BYTES=16777216

PASS=0
FAIL=1

fail() {
    printf '[FAIL] %s\n' "$*" >&2
    exit "$FAIL"
}

pass() {
    printf '[PASS] %s\n' "$*"
}

# ---------------------------------------------------------------------------
# Check 1: output/build-manifest.json exists
# ---------------------------------------------------------------------------

printf 'Checking labs/output/build-manifest.json exists...\n'
[ -f "$OUTPUT_DIR/build-manifest.json" ] || {
    fail "$OUTPUT_DIR/build-manifest.json not found. Run 'make drop-mango' or 'make engagement-platform' first."
}
pass "build-manifest.json present"

# ---------------------------------------------------------------------------
# Check 2: build-manifest.json contains required fields
# ---------------------------------------------------------------------------

printf 'Checking build-manifest.json has required fields...\n'

# Use grep for basic field presence — works without jq on the host
grep -q '"role"' "$OUTPUT_DIR/build-manifest.json" || \
    fail "build-manifest.json missing 'role' field"
grep -q '"openwrt_version"' "$OUTPUT_DIR/build-manifest.json" || \
    fail "build-manifest.json missing 'openwrt_version' field"
grep -q '"created_at"' "$OUTPUT_DIR/build-manifest.json" || \
    fail "build-manifest.json missing 'created_at' field"

pass "build-manifest.json has required fields"

# ---------------------------------------------------------------------------
# Check 3: build-manifest.json validates against the schema (requires python3)
# ---------------------------------------------------------------------------

if command -v python3 >/dev/null 2>&1; then
    printf 'Validating build-manifest.json against schema...\n'
    [ -f "$SCHEMA" ] || fail "Schema not found at $SCHEMA"

    python3 - <<PYEOF
import json, sys

with open("$OUTPUT_DIR/build-manifest.json") as f:
    manifest = json.load(f)

with open("$SCHEMA") as f:
    schema = json.load(f)

# Minimal required-field check without jsonschema dependency
required = schema.get("required", [])
missing = [k for k in required if k not in manifest]
if missing:
    print("FAIL: build-manifest.json missing required fields: " + ", ".join(missing), file=sys.stderr)
    sys.exit(1)

# Validate 'role' enum
role_enum = schema.get("properties", {}).get("role", {}).get("enum", [])
if role_enum and manifest.get("role") not in role_enum:
    print("FAIL: 'role' value '{}' not in allowed values {}".format(
        manifest.get("role"), role_enum), file=sys.stderr)
    sys.exit(1)

print("[PASS] build-manifest.json is schema-valid")
PYEOF
else
    printf '[SKIP] python3 not available on host — schema validation skipped.\n'
    printf '       To validate: run this script inside the devcontainer where python3 is installed.\n'
fi

# ---------------------------------------------------------------------------
# Check 4: Mango sysupgrade .bin exists in output/
# ---------------------------------------------------------------------------

printf 'Checking for Mango sysupgrade .bin in labs/output/...\n'

BIN_PATH=$(find "$OUTPUT_DIR" -maxdepth 2 -type f \
    -name "*${MANGO_PROFILE}*sysupgrade.bin" 2>/dev/null | head -1)

[ -n "$BIN_PATH" ] && [ -f "$BIN_PATH" ] || {
    fail "No file matching *${MANGO_PROFILE}*sysupgrade.bin found in $OUTPUT_DIR. Run 'make drop-mango'."
}

pass "Mango sysupgrade .bin found: $(basename "$BIN_PATH")"

# ---------------------------------------------------------------------------
# Check 5: .bin size is within NOR flash ceiling
# ---------------------------------------------------------------------------

printf 'Checking .bin size <= 16MB NOR ceiling (%d bytes)...\n' "$NOR_CEILING_BYTES"

BIN_SIZE=$(wc -c < "$BIN_PATH")
printf '    %s: %d bytes (%.2f MB)\n' "$(basename "$BIN_PATH")" \
    "$BIN_SIZE" "$(echo "$BIN_SIZE" | awk '{printf "%.2f", $1/1024/1024}')"

if [ "$BIN_SIZE" -gt "$NOR_CEILING_BYTES" ]; then
    fail ".bin size ${BIN_SIZE} bytes exceeds NOR ceiling ${NOR_CEILING_BYTES} bytes (16MB). Trim the PACKAGES list."
fi

pass ".bin fits within 16MB NOR ceiling"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\nAll Lab 02 checks passed.\n'
printf '  build-manifest.json: %s\n' "$OUTPUT_DIR/build-manifest.json"
printf '  Mango .bin:          %s (%d bytes)\n' "$(basename "$BIN_PATH")" "$BIN_SIZE"

exit "$PASS"
