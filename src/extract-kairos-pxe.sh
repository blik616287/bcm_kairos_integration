#!/bin/bash
# extract-kairos-pxe.sh
#
# Extracts artifacts from a CanvOS-built Kairos ISO for Option C deployment:
#   - vmlinuz           (kernel for PXE boot)
#   - initrd            (initramfs for PXE boot)
#   - rootfs.squashfs   (root filesystem, served via HTTP)
#   - install-config.yaml (cloud-config with install: block for Kairos auto-install)
#
# Option C: BCM provides DHCP + PXE label pointing to Kairos kernel/initrd.
# Kairos handles its own disk partitioning (COS_OEM, COS_STATE, COS_RECOVERY, COS_PERSISTENT).
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
EDGE_HOST_NAME="${EDGE_HOST_NAME:-node001}"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Extracts boot artifacts from a Kairos ISO for Option C PXE deployment.

Options:
  --iso PATH           Path to Kairos ISO (default: build/palette-edge-installer.iso)
  --output-dir DIR     Output directory (default: build/pxe/)
  --edge-name NAME     Edge host name for Palette + BCM (default: node001)
  --clean              Remove existing artifacts first
  -h, --help           Show this help

Outputs:
  build/pxe/vmlinuz             Kernel for PXE boot
  build/pxe/initrd              Initramfs for PXE boot
  build/pxe/rootfs.squashfs     Root filesystem (served via HTTP)
  build/pxe/install-config.yaml Cloud-config for Kairos auto-install
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
echo " Extracting Kairos Artifacts (Option C)"
echo "============================================"
echo " ISO:    $ISO_PATH"
echo " Output: $OUTPUT_DIR"
echo "============================================"
echo ""

echo "[1/4] Mounting ISO and extracting boot artifacts..."
sudo mount -o loop,ro "$ISO_PATH" "$MOUNT_DIR"

# Extract kernel (may be named vmlinuz, kernel, or vmlinuz-*)
VMLINUZ=""
for candidate in "${MOUNT_DIR}/boot/vmlinuz" "${MOUNT_DIR}/vmlinuz" "${MOUNT_DIR}/boot/kernel" "${MOUNT_DIR}/kernel" "${MOUNT_DIR}/boot/vmlinuz-"*; do
    if [[ -f "$candidate" ]]; then
        VMLINUZ="$candidate"
        break
    fi
done
if [[ -z "$VMLINUZ" ]]; then
    VMLINUZ=$(find "${MOUNT_DIR}" \( -name "vmlinuz*" -o -name "kernel" \) -type f -print -quit 2>/dev/null || true)
fi
if [[ -z "$VMLINUZ" || ! -f "$VMLINUZ" ]]; then
    echo "ERROR: No kernel (vmlinuz) found in ISO"
    echo "ISO contents:"
    ls -la "${MOUNT_DIR}/" 2>/dev/null
    ls -la "${MOUNT_DIR}/boot/" 2>/dev/null || true
    exit 1
fi
sudo cp "$VMLINUZ" "${OUTPUT_DIR}/vmlinuz"
sudo chmod 644 "${OUTPUT_DIR}/vmlinuz"
echo "  Found kernel: ${VMLINUZ#$MOUNT_DIR}"

# Extract initrd (may be named initrd, initrd.img, initramfs-*)
INITRD=""
for candidate in "${MOUNT_DIR}/boot/initrd" "${MOUNT_DIR}/initrd" "${MOUNT_DIR}/boot/initrd.img" "${MOUNT_DIR}/boot/initramfs-"*; do
    if [[ -f "$candidate" ]]; then
        INITRD="$candidate"
        break
    fi
done
if [[ -z "$INITRD" ]]; then
    INITRD=$(find "${MOUNT_DIR}" -name "initrd*" -o -name "initramfs*" -type f 2>/dev/null | head -1 || true)
fi
if [[ -z "$INITRD" || ! -f "$INITRD" ]]; then
    echo "ERROR: No initrd found in ISO"
    echo "ISO contents:"
    ls -la "${MOUNT_DIR}/" 2>/dev/null
    ls -la "${MOUNT_DIR}/boot/" 2>/dev/null || true
    exit 1
fi
sudo cp "$INITRD" "${OUTPUT_DIR}/initrd"
sudo chmod 644 "${OUTPUT_DIR}/initrd"
echo "  Found initrd: ${INITRD#$MOUNT_DIR}"

# Extract squashfs
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

# ---- Generate install cloud-config ----
# This drives the Kairos installer (auto-install mode) and carries over
# to the installed system. Unlike Option A's user-data.yaml (placed in /oem/
# by BCM rsync), this is fetched via config_url during PXE boot.
echo "[2/4] Generating install-config.yaml..."

cat > "${OUTPUT_DIR}/install-config.yaml" <<INSTALLCONFIG
#cloud-config

# Kairos auto-install: partitions disk with COS layout, reboots into installed system
install:
  auto: true
  device: "auto"
  reboot: true
  poweroff: false
  partitions:
    persistent:
      size: 0

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
INSTALLCONFIG

# ---- Summary ----
echo "[3/4] Generating checksums..."
cd "$OUTPUT_DIR"
sha256sum vmlinuz initrd rootfs.squashfs install-config.yaml > SHA256SUMS

VMLINUZ_SIZE=$(du -h "${OUTPUT_DIR}/vmlinuz" | cut -f1)
INITRD_SIZE=$(du -h "${OUTPUT_DIR}/initrd" | cut -f1)
SQFS_SIZE=$(du -h "${OUTPUT_DIR}/rootfs.squashfs" | cut -f1)

echo "[4/4] Done."
echo ""
echo "============================================"
echo " Extraction complete!"
echo "============================================"
echo " ${OUTPUT_DIR}/vmlinuz             (${VMLINUZ_SIZE})"
echo " ${OUTPUT_DIR}/initrd              (${INITRD_SIZE})"
echo " ${OUTPUT_DIR}/rootfs.squashfs     (${SQFS_SIZE})"
echo " ${OUTPUT_DIR}/install-config.yaml"
echo " ${OUTPUT_DIR}/SHA256SUMS"
echo ""
echo " Next: make kairos-deploy"
echo "============================================"
