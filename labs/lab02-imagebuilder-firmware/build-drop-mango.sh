#!/bin/sh
# Lab 02 / Contract B — Build the GL.iNet Mango (GL-MT300N-V2) drop firmware.
#
# Must fit in 16MB NOR. Verified by enforcing a squashfs ceiling at the end.
# Heavy packages (tailscale, cloudflared, python3) are installed POST-FLASH
# via ExtRoot in Lab 03, NOT here.
#
# Run inside the imagebuilder container:
#   docker compose run --rm imagebuilder /labs/lab02-imagebuilder-firmware/build-drop-mango.sh
#
# Or via the labs/ Makefile:
#   make drop-mango

set -eu

PROFILE="${PROFILE:-glinet_gl-mt300n-v2}"
IMAGE_NAME="${IMAGE_NAME:-drop-v1}"

# files-mango/ overlay lives in shared/, not in this lab dir, so a single
# canonical overlay is consumed by both Lab 02 (build) and Lab 12 (rebuild
# with secrets).
LAB_DIR="$(cd "$(dirname "$0")" && pwd)"
FILES_DIR="${FILES_DIR:-$LAB_DIR/../shared/files-mango}"
OUTPUT_DIR="${OUTPUT_DIR:-$LAB_DIR/../output}"

# Reproducibility: fix mtime stamps in the squashfs so two clean builds on
# the same source produce identical SHA256.
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1714694400}" # 2024-05-03 UTC

# Squashfs size ceiling (bytes). 16MB NOR partition layout on the Mango is
# roughly: u-boot 192KB + kernel 1.5MB + rootfs ~13MB + reserved 1.4MB.
# Cap rootfs at 13MB to leave headroom for the kernel + reserved regions.
SQUASHFS_CEILING_BYTES=$((13 * 1024 * 1024))

# === PACKAGES (canonical, plan-approved) ===
# Keep this list short. Anything multi-MB belongs on the ExtRoot USB.
PACKAGES="
  base-files busybox ca-bundle ca-certificates dropbear
  fstools libc libgcc libustream-mbedtls logd mtd netifd opkg uci
  uclient-fetch urandom-seed urngd
  block-mount kmod-usb-storage kmod-usb3 kmod-fs-ext4 e2fsprogs
  curl jsonfilter
  tcpdump-mini
  -ppp -ppp-mod-pppoe
  -wpad-basic-wolfssl -wpad-basic-mbedtls -wpad-basic-openssl
  -odhcpd-ipv6only
  -dnsmasq -firewall4 -nftables -kmod-nft-offload
  -luci -luci-base -luci-mod-admin-full -luci-theme-bootstrap
"

echo ">>> drop-mango build"
echo "    PROFILE=$PROFILE"
echo "    FILES_DIR=$FILES_DIR"
echo "    SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH"
echo "    OUTPUT_DIR=$OUTPUT_DIR"

# Validate inputs early
if [ ! -d "$FILES_DIR" ]; then
    echo "ERROR: FILES_DIR=$FILES_DIR does not exist" >&2
    exit 1
fi

# Refuse to bake an un-substituted enrollment template into the production
# image. Lab 02 produces a TEMPLATE-stage image (no secrets, no tailscale
# enrollment); Lab 12 substitutes secrets and rebuilds.
if [ -f "$FILES_DIR/etc/uci-defaults/99-enroll.sh" ]; then
    if grep -q '{{[A-Z_]*}}' "$FILES_DIR/etc/uci-defaults/99-enroll.sh" 2>/dev/null; then
        echo "WARN: 99-enroll.sh still has {{TEMPLATE}} placeholders — Lab 12 will substitute them"
    fi
fi

# Upstream openwrt/imagebuilder unpacks ImageBuilder at /builder. Older
# revisions of this script searched /home/buildbot, which does not exist
# in the upstream image. Prefer /builder; fall back to a find as a
# safety net for derivative images that lay it out differently.
if [ -f /builder/Makefile ]; then
    cd /builder
else
    IB_MAKEFILE=$(find / -maxdepth 4 -name Makefile -path '*builder*' 2>/dev/null | head -1)
    if [ -n "$IB_MAKEFILE" ]; then
        cd "$(dirname "$IB_MAKEFILE")"
    else
        echo "ERROR: ImageBuilder Makefile not found in container" >&2
        exit 1
    fi
fi
echo "    PWD=$(pwd)"

# Confirm the Mango profile exists in this ImageBuilder
if ! make info | grep -q "^$PROFILE:"; then
    echo "ERROR: profile '$PROFILE' not found in this ImageBuilder" >&2
    echo "Available profiles:" >&2
    make info | grep -E '^[a-z][a-z0-9_-]+:' | head -30 >&2
    exit 1
fi

# Flatten PACKAGES to a single space-separated line. ImageBuilder reconstructs
# `bash -c "...$(PACKAGES)..."` internally; embedded newlines from a multi-line
# shell heredoc-style PACKAGES variable break that bash quoting.
PACKAGES_FLAT=$(printf '%s' "$PACKAGES" | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//')

# Build
make image \
    PROFILE="$PROFILE" \
    PACKAGES="$PACKAGES_FLAT" \
    EXTRA_IMAGE_NAME="$IMAGE_NAME" \
    FILES="$FILES_DIR"

# Locate the produced sysupgrade .bin
BIN_PATH=$(find bin -type f -name "*${PROFILE}*sysupgrade.bin" | head -1)
if [ -z "$BIN_PATH" ] || [ ! -f "$BIN_PATH" ]; then
    echo "ERROR: no sysupgrade .bin produced under bin/" >&2
    find bin -type f | head -20 >&2
    exit 1
fi

BIN_SIZE=$(wc -c < "$BIN_PATH")
BIN_SHA=$(sha256sum "$BIN_PATH" | awk '{print $1}')

echo ">>> built: $BIN_PATH"
echo "    size: $BIN_SIZE bytes"
echo "    sha256: $BIN_SHA"

# Also locate the rootfs squashfs blob and check it against the ceiling
SQ_PATH=$(find bin -type f -name "*${PROFILE}*squashfs-rootfs*" | head -1)
if [ -n "$SQ_PATH" ] && [ -f "$SQ_PATH" ]; then
    SQ_SIZE=$(wc -c < "$SQ_PATH")
    echo "    squashfs rootfs: $SQ_SIZE bytes ($SQ_PATH)"
    if [ "$SQ_SIZE" -gt "$SQUASHFS_CEILING_BYTES" ]; then
        echo "ERROR: squashfs rootfs $SQ_SIZE bytes exceeds ceiling $SQUASHFS_CEILING_BYTES" >&2
        echo "       trim the PACKAGES list or move heavy packages to ExtRoot (Lab 03)" >&2
        exit 1
    fi
fi

# Manifest
mkdir -p "$OUTPUT_DIR"
PKG_SHA=$(printf '%s\n' $PACKAGES | sort -u | sha256sum | awk '{print $1}')
cat > "$OUTPUT_DIR/build-manifest.json" <<EOF
{
  "role": "drop-mango",
  "openwrt_version": "23.05.3",
  "openwrt_target": "ramips/mt76x8",
  "openwrt_profile": "$PROFILE",
  "image_sha256": "$BIN_SHA",
  "image_size_bytes": $BIN_SIZE,
  "package_list_sha256": "$PKG_SHA",
  "source_date_epoch": $SOURCE_DATE_EPOCH,
  "created_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "builder_host": "$(hostname)"
}
EOF

# Copy artifacts to OUTPUT_DIR for easy student access
cp "$BIN_PATH" "$OUTPUT_DIR/"

# Also copy the package .manifest produced by ImageBuilder so Lab 02's
# Step 4 ("Compare to upstream rootfs") can read the resolved package
# list directly from $OUTPUT_DIR/ without traversing into bin/targets/.
MFST_PATH=$(find bin -type f -name "*${PROFILE}*.manifest" | head -1)
if [ -n "$MFST_PATH" ] && [ -f "$MFST_PATH" ]; then
    cp "$MFST_PATH" "$OUTPUT_DIR/"
fi

echo ">>> artifacts in $OUTPUT_DIR/"
ls -la "$OUTPUT_DIR/"
