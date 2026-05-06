#!/bin/sh
# lab12-drop-device/bake-secrets.sh
#
# Substitutes secrets into 99-enroll.sh.template and rebuilds the sealed
# Mango image.  Must be run from the repo root OR from within the labs/
# directory (the script self-locates).
#
# Required env vars (or interactive prompt fallback):
#   TAILSCALE_KEY     — ephemeral, tag:device, single-use
#   DOMAIN            — e.g. a00f3f13.eplabs.cloud
#   STUDENT           — slot name, e.g. alpha  (Mango joins as drop-${STUDENT})
#
# Optional overrides:
#   WORKER_URL        — defaults to https://api.${DOMAIN}
#   ACCESS_TOKENS_JSON — path to lab08 output; defaults to auto-detected
#   TEMPLATE_SH       — path to 99-enroll.sh.template; defaults to auto-detected
#   OUTPUT_BIN        — output path for sealed .bin; defaults to labs/output/

set -eu

# ---------------------------------------------------------------------------
# Locate repo root and lab paths regardless of working directory.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LABS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SHARED_TEMPLATE="${LABS_DIR}/shared/files-mango/etc/uci-defaults/99-enroll.sh.template"
ACCESS_TOKENS_DEFAULT="${LABS_DIR}/lab08-cloudflare-access/output/access-tokens.json"
BUILD_SCRIPT="${LABS_DIR}/lab02-imagebuilder-firmware/build-drop-mango.sh"
WRANGLER_TOML="${LABS_DIR}/lab07-first-worker/worker/wrangler.toml"
OUTPUT_DIR="${LABS_DIR}/output"

# Allow overrides
TEMPLATE_SH="${TEMPLATE_SH:-${SHARED_TEMPLATE}}"
ACCESS_TOKENS_JSON="${ACCESS_TOKENS_JSON:-${ACCESS_TOKENS_DEFAULT}}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

prompt_if_empty() {
    # $1 = varname, $2 = prompt text
    eval "val=\${$1:-}"
    if [ -z "$val" ]; then
        printf '%s: ' "$2" >&2
        read -r val
        [ -z "$val" ] && die "$1 cannot be empty"
        eval "$1=\"\$val\""
    fi
}

# ---------------------------------------------------------------------------
# Validate prerequisites
# ---------------------------------------------------------------------------
[ -f "$TEMPLATE_SH" ] || die "enrollment template not found: ${TEMPLATE_SH}
  Run from the repo root or set TEMPLATE_SH to the correct path."

[ -f "$ACCESS_TOKENS_JSON" ] || die "CF Access tokens not found: ${ACCESS_TOKENS_JSON}
  Complete Lab 08 first, then re-run this script.
  Expected fields: service_token_id, service_token_secret"

[ -f "$BUILD_SCRIPT" ] || die "imagebuilder script not found: ${BUILD_SCRIPT}"

# ---------------------------------------------------------------------------
# Read CF Access service token pair from lab08 output.
# jq is the primary path; jsonfilter (devcontainer) and a sed fallback follow.
# The sed fallback tolerates whitespace around the JSON colon (the earlier
# grep `'"key":"value"'` pattern broke on jq-formatted files; this one
# accepts both compact and pretty-printed input).
# ---------------------------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
    SERVICE_TOKEN_ID=$(jq -r '.service_token_id // ""' "$ACCESS_TOKENS_JSON")
    SERVICE_TOKEN_SECRET=$(jq -r '.service_token_secret // ""' "$ACCESS_TOKENS_JSON")
elif command -v jsonfilter >/dev/null 2>&1; then
    SERVICE_TOKEN_ID=$(jsonfilter -i "$ACCESS_TOKENS_JSON" -e '@.service_token_id')
    SERVICE_TOKEN_SECRET=$(jsonfilter -i "$ACCESS_TOKENS_JSON" -e '@.service_token_secret')
else
    # POSIX sed fallback. Tolerates `"key":"value"` (compact) and
    # `"key": "value"` (pretty) and `"key" : "value"` (whitespace-around).
    extract_field() {
        sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$2" | head -1
    }
    SERVICE_TOKEN_ID=$(extract_field service_token_id "$ACCESS_TOKENS_JSON")
    SERVICE_TOKEN_SECRET=$(extract_field service_token_secret "$ACCESS_TOKENS_JSON")
fi

[ -n "$SERVICE_TOKEN_ID" ]     || die "service_token_id is empty in ${ACCESS_TOKENS_JSON}"
[ -n "$SERVICE_TOKEN_SECRET" ] || die "service_token_secret is empty in ${ACCESS_TOKENS_JSON}"
printf 'ok   service token id = %s...\n' "$(printf '%s' "$SERVICE_TOKEN_ID" | head -c 8)"

# ---------------------------------------------------------------------------
# Resolve WORKER_URL
# ---------------------------------------------------------------------------
if [ -z "${WORKER_URL:-}" ]; then
    if [ -n "${DOMAIN:-}" ]; then
        WORKER_URL="https://api.${DOMAIN}"
    elif [ -f "$WRANGLER_TOML" ]; then
        # Extract domain from the first route pattern in wrangler.toml
        RAW=$(grep 'pattern' "$WRANGLER_TOML" | head -1 | sed 's/.*pattern *= *"//;s|/.*||')
        # RAW is now "api.<DOMAIN>" — strip the "api." prefix
        DOMAIN_GUESS=$(printf '%s' "$RAW" | sed 's/^api\.//')
        if [ -n "$DOMAIN_GUESS" ] && [ "$DOMAIN_GUESS" != "YOUR_DOMAIN" ]; then
            WORKER_URL="https://api.${DOMAIN_GUESS}"
            DOMAIN="${DOMAIN_GUESS}"
        fi
    fi
fi
prompt_if_empty WORKER_URL "Worker URL (e.g. https://api.a00f3f13.eplabs.cloud)"

# ---------------------------------------------------------------------------
# Resolve STUDENT slot
# ---------------------------------------------------------------------------
prompt_if_empty STUDENT "Student slot name (e.g. alpha) — Mango will join as drop-STUDENT"
SLOT="drop-${STUDENT}"
printf 'ok   slot = %s\n' "$SLOT"

# ---------------------------------------------------------------------------
# Resolve TAILSCALE_KEY
# ---------------------------------------------------------------------------
prompt_if_empty TAILSCALE_KEY "Tailscale ephemeral auth key (tskey-auth-...)"

# ---------------------------------------------------------------------------
# Build a temporary overlay directory with the substituted script.
#
# The overlay must live UNDER labs/ (which docker-compose.yml bind-mounts to
# /labs/ inside the imagebuilder container), so the path inside the container
# resolves to the same files. A path under /tmp on the host is invisible to
# the container — that bug bit Lab 12 once already; the substituted
# 99-enroll.sh silently never made it into the image, leaving only the
# .template, which then ran on first boot with literal {{SLOT}} placeholders
# and failed at "no network within 120s". See delivery-notes §11.16.
# ---------------------------------------------------------------------------
HOST_TMPDIR="${LABS_DIR}/.bake-tmp-${STUDENT}-$$"
CONTAINER_TMPDIR="/labs/$(basename "$HOST_TMPDIR")"
OVERLAY_DEFAULTS="${HOST_TMPDIR}/etc/uci-defaults"
mkdir -p "$OVERLAY_DEFAULTS"
trap 'rm -rf "$HOST_TMPDIR"' EXIT INT TERM

# Copy the full files-mango overlay structure into the temp dir.
SHARED_FILES_DIR="${LABS_DIR}/shared/files-mango"
if [ -d "$SHARED_FILES_DIR" ]; then
    cp -a "${SHARED_FILES_DIR}/." "${HOST_TMPDIR}/"
fi

# Drop the .template from the temp overlay before substituting. uci-defaults
# runs every executable in /etc/uci-defaults/ alphabetically; if both
# 99-enroll.sh (substituted) and 99-enroll.sh.template (original) end up in
# the image, both run, and the .template fires after the .sh has self-deleted
# itself, then fails on placeholders. Only the substituted .sh should ship.
rm -f "${OVERLAY_DEFAULTS}/99-enroll.sh.template"

# Perform substitutions using sed (POSIX-safe; no special chars in values assumed)
sed \
    -e "s|{{WORKER_URL}}|${WORKER_URL}|g" \
    -e "s|{{TAILSCALE_KEY}}|${TAILSCALE_KEY}|g" \
    -e "s|{{SERVICE_TOKEN_ID}}|${SERVICE_TOKEN_ID}|g" \
    -e "s|{{SERVICE_TOKEN_SECRET}}|${SERVICE_TOKEN_SECRET}|g" \
    -e "s|{{SLOT}}|${SLOT}|g" \
    "$TEMPLATE_SH" > "${OVERLAY_DEFAULTS}/99-enroll.sh"

chmod 755 "${OVERLAY_DEFAULTS}/99-enroll.sh"

# Sanity check — no unreplaced placeholders
if grep -q '{{[A-Z_]*}}' "${OVERLAY_DEFAULTS}/99-enroll.sh"; then
    die "unreplaced placeholder(s) remain in substituted enrollment script:
$(grep '{{[A-Z_]*}}' "${OVERLAY_DEFAULTS}/99-enroll.sh")"
fi
printf 'ok   secrets injected into overlay (no unreplaced placeholders)\n'

# ---------------------------------------------------------------------------
# Determine output path
# ---------------------------------------------------------------------------
mkdir -p "$OUTPUT_DIR"
SEALED_BIN="${OUTPUT_DIR}/drop-mango-sealed-${STUDENT}.bin"

# ---------------------------------------------------------------------------
# Re-invoke the Lab 02 imagebuilder script with secrets-bearing overlay.
#
# Pass FILES_DIR via -e so build-drop-mango.sh inside the container reads
# our temp overlay. Without -e, docker compose run does NOT inherit env from
# the calling shell, and build-drop-mango.sh would fall back to its default
# FILES_DIR=$LAB_DIR/../shared/files-mango — i.e., the original (unsubstituted)
# overlay. SOURCE_DATE_EPOCH is similarly explicit so the build is
# reproducible.
# ---------------------------------------------------------------------------
printf '>>> running imagebuilder (this takes 2-4 minutes)...\n'

docker compose \
    -f "${LABS_DIR}/docker-compose.yml" \
    run --rm \
    -e FILES_DIR="$CONTAINER_TMPDIR" \
    -e IMAGE_NAME="drop-v1-sealed" \
    -e SOURCE_DATE_EPOCH \
    imagebuilder \
    "/labs/lab02-imagebuilder-firmware/build-drop-mango.sh"

# Locate what the builder produced
BUILT_BIN=$(find "$OUTPUT_DIR" -name '*glinet_gl-mt300n-v2*sysupgrade*.bin' \
    -newer "$TEMPLATE_SH" | sort | tail -1)

if [ -z "$BUILT_BIN" ] || [ ! -f "$BUILT_BIN" ]; then
    # Clean up temp dir before dying
    rm -rf "$HOST_TMPDIR"
    die "imagebuilder did not produce a sysupgrade .bin in ${OUTPUT_DIR}"
fi

# Rename to the canonical sealed-image name
mv "$BUILT_BIN" "$SEALED_BIN"

SEALED_SHA=$(sha256sum "$SEALED_BIN" | awk '{print $1}')
SEALED_SIZE=$(wc -c < "$SEALED_BIN")

# ---------------------------------------------------------------------------
# Update the build manifest with sealed-image metadata. Idempotent: re-runs
# overwrite the sealed_* fields rather than appending duplicate fragments.
# (The earlier sed-based approach produced malformed JSON on re-bake — see
# delivery-notes §11.10 out-of-scope flag.)
# ---------------------------------------------------------------------------
MANIFEST="${OUTPUT_DIR}/build-manifest.json"
if [ -f "$MANIFEST" ] && command -v jq >/dev/null 2>&1; then
    jq --arg img "$(basename "$SEALED_BIN")" \
       --arg sha "$SEALED_SHA" \
       --argjson sz "$SEALED_SIZE" \
       --arg slot "$SLOT" \
       --arg url "$WORKER_URL" \
       '. + {
            sealed_image: $img,
            sealed_sha256: $sha,
            sealed_size_bytes: $sz,
            slot: $slot,
            worker_url: $url
        }' "$MANIFEST" > "${MANIFEST}.tmp" \
       && mv "${MANIFEST}.tmp" "$MANIFEST"
elif [ -f "$MANIFEST" ]; then
    printf 'WARN: jq not found; sealed_image metadata not written to %s\n' \
        "$MANIFEST" >&2
fi

# ---------------------------------------------------------------------------
# Cleanup temp overlay (it contains live secrets — remove immediately)
# ---------------------------------------------------------------------------
rm -rf "$HOST_TMPDIR"
printf 'ok   temp overlay with secrets removed\n'

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n>>> sealed image ready\n'
printf '    path:   %s\n' "$SEALED_BIN"
printf '    size:   %s bytes\n' "$SEALED_SIZE"
printf '    sha256: %s\n' "$SEALED_SHA"
printf '\nNext step: flash this image to the Mango (Lab 12 Step 5)\n'
printf '  scp %s root@192.168.1.1:/tmp/sealed.bin\n' "$SEALED_BIN"
printf '  ssh root@192.168.1.1 "sysupgrade -n /tmp/sealed.bin"\n'
