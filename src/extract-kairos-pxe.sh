#!/bin/bash
# extract-kairos-pxe.sh
#
# Extracts artifacts from a CanvOS-built Kairos ISO for BCM provisioning:
#   - rootfs.squashfs (to be unsquashed as a BCM software image)
#   - user-data.yaml (Palette registration + SSH config for /oem/)
#
# BCM handles PXE boot, disk provisioning (rsync), and GRUB installation.
# No kernel/initrd/iPXE/dracut hooks needed — BCM's node-installer does all of that.
#
# Usage:
#   ./extract-kairos-pxe.sh [OPTIONS]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
ISO_PATH="${BUILD_DIR}/palette-edge-installer.iso"
OUTPUT_DIR="${BUILD_DIR}/pxe"
CLEAN=false

# Palette registration (from env vars or env.json via Makefile)
PALETTE_ENDPOINT="${PALETTE_ENDPOINT:-api.spectrocloud.com}"
PALETTE_TOKEN="${PALETTE_TOKEN:?ERROR: PALETTE_TOKEN not set. Set in env.json or export PALETTE_TOKEN}"
PALETTE_PROJECT_UID="${PALETTE_PROJECT_UID:?ERROR: PALETTE_PROJECT_UID not set. Set in env.json or export PALETTE_PROJECT_UID}"

# Edge host name — used as both the Palette edge ID and system hostname.
# Keeps BCM and Palette in sync (BCM knows this node by the same name).
EDGE_HOST_NAME="${EDGE_HOST_NAME:-node001}"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Extracts artifacts from a Kairos ISO for BCM provisioning.

Options:
  --iso PATH           Path to Kairos ISO (default: build/palette-edge-installer.iso)
  --output-dir DIR     Output directory (default: build/pxe/)
  --edge-name NAME     Edge host name for Palette + BCM (default: node001)
  --clean              Remove existing artifacts first
  -h, --help           Show this help

Outputs:
  build/pxe/rootfs.squashfs   Root filesystem (unsquashed as BCM image)
  build/pxe/user-data.yaml    Cloud-config for Palette registration
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --iso)          ISO_PATH="$2"; shift 2 ;;
        --output-dir)   OUTPUT_DIR="$2"; shift 2 ;;
        --edge-name)    EDGE_HOST_NAME="$2"; shift 2 ;;
        --clean)        CLEAN=true; shift ;;
        -h|--help)      usage ;;
        *)              echo "Unknown option: $1"; usage ;;
    esac
done

# ---- Preflight ----
if [[ ! -f "$ISO_PATH" ]]; then
    echo "ERROR: ISO not found at $ISO_PATH"
    echo "Build it first: ./build-canvos.sh"
    exit 1
fi

if [[ "$CLEAN" == "true" ]]; then
    echo "Cleaning existing artifacts..."
    rm -rf "$OUTPUT_DIR"
fi

mkdir -p "$OUTPUT_DIR"

# ---- Mount ISO ----
MOUNT_DIR=$(mktemp -d "${PROJECT_DIR}/.bcm-work.XXXXXX")
cleanup() {
    sudo umount "$MOUNT_DIR" 2>/dev/null || true
    rmdir "$MOUNT_DIR" 2>/dev/null || true
}
trap cleanup EXIT

echo "============================================"
echo " Extracting Kairos Artifacts for BCM"
echo "============================================"
echo " ISO:    $ISO_PATH"
echo " Output: $OUTPUT_DIR"
echo "============================================"
echo ""

echo "[1/3] Mounting ISO and extracting rootfs.squashfs..."
sudo mount -o loop,ro "$ISO_PATH" "$MOUNT_DIR"

if [[ -f "${MOUNT_DIR}/rootfs.squashfs" ]]; then
    sudo cp "${MOUNT_DIR}/rootfs.squashfs" "${OUTPUT_DIR}/rootfs.squashfs"
else
    SQFS=$(find "${MOUNT_DIR}" -name "*.squashfs" -print -quit 2>/dev/null || true)
    if [[ -n "$SQFS" ]]; then
        echo "  Found squashfs at: ${SQFS#$MOUNT_DIR}"
        sudo cp "$SQFS" "${OUTPUT_DIR}/rootfs.squashfs"
    else
        echo "ERROR: No squashfs found in ISO"
        ls -la "${MOUNT_DIR}/" 2>/dev/null
        exit 1
    fi
fi
sudo chmod 644 "${OUTPUT_DIR}/rootfs.squashfs"
sudo umount "$MOUNT_DIR"

# ---- Generate user-data ----
# This goes into /oem/99_userdata.yaml in the BCM image.
# BCM rsyncs the entire image to the compute node's disk, so this
# is already on disk when Kairos boots — no live boot or config_url needed.
echo "[2/3] Generating user-data.yaml..."

cat > "${OUTPUT_DIR}/user-data.yaml" <<USERDATA
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
USERDATA

# ---- Summary ----
echo "[3/3] Generating checksums..."
cd "$OUTPUT_DIR"
sha256sum rootfs.squashfs user-data.yaml > SHA256SUMS

SQFS_SIZE=$(du -h "${OUTPUT_DIR}/rootfs.squashfs" | cut -f1)

echo ""
echo "============================================"
echo " Extraction complete!"
echo "============================================"
echo " ${OUTPUT_DIR}/rootfs.squashfs  (${SQFS_SIZE})"
echo " ${OUTPUT_DIR}/user-data.yaml"
echo " ${OUTPUT_DIR}/SHA256SUMS"
echo ""
echo " Next: make kairos-deploy"
echo "============================================"
