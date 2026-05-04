#!/usr/bin/env bash
# Lab 02 / Contract A — Build the engagement-platform devcontainer.
#
# Replaces what was originally the GL.iNet Beryl AX (GL-MT3000) "primary"
# build. Same OpenWrt 23.05.3 baseline as the Mango drop firmware, but the
# devcontainer is unconstrained on flash/RAM so it carries the full
# engagement-stack (tailscale, cloudflared, python, wrangler, etc.).
#
# Run from the host (NOT from inside the imagebuilder container):
#   bash labs/lab02-imagebuilder-firmware/build-engagement-platform.sh
#
# Or via the labs/ Makefile:
#   make engagement-platform

set -euo pipefail

OPENWRT_VERSION="${OPENWRT_VERSION:-23.05.3}"
IMAGE_TAG="${IMAGE_TAG:-epl-engagement-platform:${OPENWRT_VERSION}}"

LAB_DIR="$(cd "$(dirname "$0")" && pwd)"
COURSE_ROOT="$(cd "$LAB_DIR/../.." && pwd)"
DEVCONTAINER="$COURSE_ROOT/.devcontainer"
OUTPUT_DIR="${OUTPUT_DIR:-$LAB_DIR/../output}"

if [ ! -d "$DEVCONTAINER" ]; then
    echo "ERROR: $DEVCONTAINER missing — devcontainer config not in repo" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo ">>> engagement-platform build"
echo "    OPENWRT_VERSION=$OPENWRT_VERSION"
echo "    IMAGE_TAG=$IMAGE_TAG"
echo "    DEVCONTAINER=$DEVCONTAINER"

docker build \
    --build-arg "OPENWRT_VERSION=$OPENWRT_VERSION" \
    -t "$IMAGE_TAG" \
    -f "$DEVCONTAINER/Dockerfile" \
    "$DEVCONTAINER"

# Capture image digest for the manifest
IMAGE_DIGEST=$(docker image inspect "$IMAGE_TAG" --format '{{.Id}}')
IMAGE_SIZE=$(docker image inspect "$IMAGE_TAG" --format '{{.Size}}')

# Optional: extract the rootfs as a tarball for Lab 02 inspection (so
# students can `tar tvf` the rootfs and compare to drop-mango's squashfs).
ROOTFS_TAR="$OUTPUT_DIR/engagement-platform-rootfs.tar"
CONTAINER_ID=$(docker create "$IMAGE_TAG")
docker export "$CONTAINER_ID" > "$ROOTFS_TAR"
docker rm "$CONTAINER_ID" >/dev/null
ROOTFS_SHA=$(sha256sum "$ROOTFS_TAR" | awk '{print $1}')
ROOTFS_SIZE=$(wc -c < "$ROOTFS_TAR")

cat > "$OUTPUT_DIR/build-manifest.json" <<EOF
{
  "role": "engagement-platform",
  "openwrt_version": "$OPENWRT_VERSION",
  "openwrt_target": "x86_64",
  "imagebuilder_image": "$IMAGE_DIGEST",
  "image_sha256": "$ROOTFS_SHA",
  "image_size_bytes": $ROOTFS_SIZE,
  "docker_image_size_bytes": $IMAGE_SIZE,
  "created_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "builder_host": "$(hostname)"
}
EOF

echo ">>> built: $IMAGE_TAG"
echo "    digest: $IMAGE_DIGEST"
echo "    docker image size: $IMAGE_SIZE bytes"
echo "    rootfs tar: $ROOTFS_TAR ($ROOTFS_SIZE bytes, sha256=$ROOTFS_SHA)"
echo ">>> next: open this folder in VS Code and 'Reopen in Container'"
