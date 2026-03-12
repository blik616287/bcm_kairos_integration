#!/bin/bash
# generate-raw-image.sh
#
# Generates a raw disk image with full COS partition layout using AuroraBoot.
# Takes the container image built by build-kairos-container.sh and produces
# a raw disk image ready for dd onto a compute node.
#
# The raw image contains:
#   - COS_GRUB    (EFI — GRUB bootloader)
#   - COS_OEM     (cloud-config, userdata)
#   - COS_RECOVERY (Kairos squashfs system image)
#
# On first boot, Kairos creates COS_STATE and COS_PERSISTENT automatically.
#
# Usage:
#   ./generate-raw-image.sh [OPTIONS]
#
# After generating, deploy with:
#   ./deploy-kairos-dd.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
AURORABOOT_DIR="${BUILD_DIR}/auroraboot"

# Palette registration (from env vars or env.json via Makefile)
PALETTE_ENDPOINT="${PALETTE_ENDPOINT:-api.spectrocloud.com}"
PALETTE_TOKEN="${PALETTE_TOKEN:?ERROR: PALETTE_TOKEN not set. Set in env.json or export PALETTE_TOKEN}"
PALETTE_PROJECT_UID="${PALETTE_PROJECT_UID:?ERROR: PALETTE_PROJECT_UID not set. Set in env.json or export PALETTE_PROJECT_UID}"
EDGE_HOST_NAME="${EDGE_HOST_NAME:-node001}"

# AuroraBoot config
AURORABOOT_IMAGE="quay.io/kairos/auroraboot"
DISK_SIZE="${DISK_SIZE:-81920}"  # MB

# Container image ref
IMAGE_REF_FILE="${BUILD_DIR}/kairos-container-image.ref"

CLEAN=false

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Generates a Kairos raw disk image via AuroraBoot with COS partition layout.

Options:
  --image-ref FILE     Path to container image reference file
                       (default: build/kairos-container-image.ref)
  --edge-name NAME     Edge host name for Palette + BCM (default: node001)
  --disk-size MB       Raw disk size in MB (default: 81920)
  --clean              Remove existing artifacts first
  -h, --help           Show this help

Outputs:
  build/kairos-disk.raw          Raw disk image with COS partitions
  build/kairos-disk.raw.sha256   Checksum
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image-ref)   IMAGE_REF_FILE="$2"; shift 2 ;;
        --edge-name)   EDGE_HOST_NAME="$2"; shift 2 ;;
        --disk-size)   DISK_SIZE="$2"; shift 2 ;;
        --clean)       CLEAN=true; shift ;;
        -h|--help)     usage ;;
        *)             echo "Unknown option: $1"; usage ;;
    esac
done

# ---- Preflight ----
if [[ ! -f "$IMAGE_REF_FILE" ]]; then
    echo "ERROR: Container image reference not found at $IMAGE_REF_FILE"
    echo "Build it first: ./build-kairos-container.sh"
    exit 1
fi

CONTAINER_IMAGE=$(cat "$IMAGE_REF_FILE")
echo "Container image: ${CONTAINER_IMAGE}"

if ! command -v docker &>/dev/null; then
    echo "ERROR: Docker not found."
    exit 1
fi

# ---- Clean ----
if [[ "$CLEAN" == "true" ]]; then
    echo "Cleaning existing artifacts..."
    rm -rf "${AURORABOOT_DIR}"
    rm -f "${BUILD_DIR}/kairos-disk.raw" "${BUILD_DIR}/kairos-disk.raw.sha256"
fi

mkdir -p "${AURORABOOT_DIR}"

echo "============================================"
echo " Generating Kairos Raw Disk Image"
echo "============================================"
echo " Container: ${CONTAINER_IMAGE}"
echo " Disk size: ${DISK_SIZE} MB"
echo " Edge name: ${EDGE_HOST_NAME}"
echo "============================================"
echo ""

# ---- Generate cloud-config ----
echo "[1/3] Generating cloud-config..."

cat > "${AURORABOOT_DIR}/cloud-config.yaml" <<CLOUDCONFIG
#cloud-config

# Palette Edge Registration
stylus:
  site:
    paletteEndpoint: ${PALETTE_ENDPOINT}
    edgeHostToken: ${PALETTE_TOKEN}
    projectUid: ${PALETTE_PROJECT_UID}
    name: ${EDGE_HOST_NAME}

users:
  - name: kairos
    shell: /bin/bash
    groups:
      - sudo
      - admin
      - adm
      - systemd-journal
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false

stages:
  boot:
    - name: "Set kairos user password"
      users:
        kairos:
          passwd: kairos
    - name: "Enable SSH password auth"
      files:
        - path: /etc/ssh/sshd_config.d/99-kairos-test.conf
          content: |
            PasswordAuthentication yes
            PermitRootLogin yes
          permissions: 0644
      commands:
        - systemctl restart sshd || systemctl restart ssh || true
CLOUDCONFIG

# ---- Run AuroraBoot ----
echo "[2/3] Running AuroraBoot (this may take a while)..."

docker run --privileged \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${AURORABOOT_DIR}:/aurora" \
    --rm \
    "${AURORABOOT_IMAGE}" \
    --set "disable_http_server=true" \
    --set "disable_netboot=true" \
    --set "disk.efi=true" \
    --set "disk.size=${DISK_SIZE}" \
    --set "container_image=${CONTAINER_IMAGE}" \
    --set "state_dir=/aurora" \
    --cloud-config /aurora/cloud-config.yaml

# ---- Locate and move output ----
echo "[3/3] Locating output..."

# AuroraBoot places disk.raw in the state dir or a subdirectory
RAW_FILE=""
for candidate in "${AURORABOOT_DIR}/disk.raw" "${AURORABOOT_DIR}/"*/disk.raw; do
    if [[ -f "$candidate" ]]; then
        RAW_FILE="$candidate"
        break
    fi
done

if [[ -z "$RAW_FILE" ]]; then
    # Search more broadly
    RAW_FILE=$(find "${AURORABOOT_DIR}" -name "*.raw" -type f | head -1)
fi

if [[ -z "$RAW_FILE" || ! -f "$RAW_FILE" ]]; then
    echo "ERROR: Raw disk image not found in ${AURORABOOT_DIR}"
    echo "Contents:"
    find "${AURORABOOT_DIR}" -type f 2>/dev/null
    exit 1
fi

if [[ "$RAW_FILE" != "${BUILD_DIR}/kairos-disk.raw" ]]; then
    mv "$RAW_FILE" "${BUILD_DIR}/kairos-disk.raw"
fi

# ---- Generate checksum ----
cd "${BUILD_DIR}"
sha256sum kairos-disk.raw > kairos-disk.raw.sha256

# ---- Validate partition layout ----
echo ""
echo "Validating partition layout..."

if command -v fdisk &>/dev/null; then
    FDISK_OUT=$(fdisk -l "${BUILD_DIR}/kairos-disk.raw" 2>/dev/null || true)
    echo "$FDISK_OUT"

    # Check for expected partitions (at least 3 GPT partitions)
    PART_COUNT=$(echo "$FDISK_OUT" | grep -c "^${BUILD_DIR}/kairos-disk.raw" || true)
    if [[ "$PART_COUNT" -ge 3 ]]; then
        echo ""
        echo "  [OK] Found ${PART_COUNT} partitions (expected >= 3)"
    else
        echo ""
        echo "  [WARN] Found ${PART_COUNT} partitions (expected >= 3)"
    fi
else
    echo "  [SKIP] fdisk not available for validation"
fi

RAW_SIZE=$(du -h "${BUILD_DIR}/kairos-disk.raw" | cut -f1)

echo ""
echo "============================================"
echo " Raw image generation complete!"
echo "============================================"
echo " ${BUILD_DIR}/kairos-disk.raw  (${RAW_SIZE})"
echo " ${BUILD_DIR}/kairos-disk.raw.sha256"
echo ""
echo " Next: ./deploy-kairos-dd.sh"
echo "============================================"
