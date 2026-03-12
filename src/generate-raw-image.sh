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

# BCM integration
BCM_PASSWORD="${BCM_PASSWORD:-}"
HEAD_NODE_IP="${HEAD_NODE_IP:-10.141.255.254}"
BCM_SSH_KEY="${BCM_SSH_KEY:-}"  # Path to private key for SSH to BCM head node

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

# Read BCM SSH private key if provided
BCM_SSH_KEY_CONTENT=""
if [[ -n "$BCM_SSH_KEY" && -f "$BCM_SSH_KEY" ]]; then
    BCM_SSH_KEY_CONTENT=$(cat "$BCM_SSH_KEY")
    echo "  BCM SSH key: ${BCM_SSH_KEY}"
elif [[ -f "${BUILD_DIR}/bcm-kairos-key" ]]; then
    BCM_SSH_KEY_CONTENT=$(cat "${BUILD_DIR}/bcm-kairos-key")
    echo "  BCM SSH key: ${BUILD_DIR}/bcm-kairos-key"
fi

# Build the BCM integration stages block if we have credentials
BCM_STAGES=""
if [[ -n "$BCM_SSH_KEY_CONTENT" ]]; then
    # Indent the key content for YAML embedding (10 spaces for file content block)
    INDENTED_KEY=$(echo "$BCM_SSH_KEY_CONTENT" | sed 's/^/              /')

    BCM_STAGES=$(cat <<BCMEOF
    - name: "Install BCM SSH key"
      files:
        - path: /var/lib/bcm/bcm-key
          content: |
${INDENTED_KEY}
          permissions: 0600
          owner: 0
          group: 0
    - name: "BCM integration: set NOSYNC + start cmd chroot"
      commands:
        - |
          # Wait for network to be ready
          for i in \$(seq 1 30); do
            ping -c1 -W2 ${HEAD_NODE_IP} >/dev/null 2>&1 && break
            sleep 2
          done

          # Set installmode NOSYNC on BCM head node to prevent re-provisioning
          ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
              -o ConnectTimeout=10 -i /var/lib/bcm/bcm-key \
              root@${HEAD_NODE_IP} \
              "echo -e 'device\nuse ${EDGE_HOST_NAME}\nset installmode NOSYNC\ncommit' | cmsh" \
              >/dev/null 2>&1 && echo "bcm-init: NOSYNC set" || echo "bcm-init: NOSYNC failed"

          # NFS mount BCM default-image rootfs for cmd chroot
          mkdir -p /var/lib/cm/rootfs
          mount -t nfs -o ro,nolock,vers=3 ${HEAD_NODE_IP}:/cm/images/default-image /var/lib/cm/rootfs 2>/dev/null || {
            echo "bcm-init: NFS mount failed"; exit 0
          }

          # Mount /cm/shared (writable)
          mount -t nfs -o rw,nolock,vers=3 ${HEAD_NODE_IP}:/cm/shared /var/lib/cm/rootfs/cm/shared 2>/dev/null || true

          # Mount essentials for chroot
          mount -t proc proc /var/lib/cm/rootfs/proc 2>/dev/null || true
          mount -t sysfs sysfs /var/lib/cm/rootfs/sys 2>/dev/null || true
          mount --bind /dev /var/lib/cm/rootfs/dev 2>/dev/null || true

          # Writable tmpfs for cmd runtime state (NFS rootfs is read-only)
          mount -t tmpfs tmpfs /var/lib/cm/rootfs/var/spool/cmd 2>/dev/null || true
          mount -t tmpfs tmpfs /var/lib/cm/rootfs/var/run 2>/dev/null || true
          mount -t tmpfs tmpfs /var/lib/cm/rootfs/tmp 2>/dev/null || true

          # Writable overlay for cmd config (need to set Master IP)
          mkdir -p /var/lib/cm/cmd-etc
          cp /var/lib/cm/rootfs/cm/local/apps/cmd/etc/* /var/lib/cm/cmd-etc/ 2>/dev/null || true
          mount --bind /var/lib/cm/cmd-etc /var/lib/cm/rootfs/cm/local/apps/cmd/etc
          sed -i "s/Master = master/Master = ${HEAD_NODE_IP}/" /var/lib/cm/cmd-etc/cmd.conf

          # Copy network info into chroot
          cp /etc/resolv.conf /var/lib/cm/rootfs/etc/resolv.conf 2>/dev/null || true
          echo "${EDGE_HOST_NAME}" > /var/lib/cm/rootfs/etc/hostname 2>/dev/null || true

          # Start cmd daemon in slave mode inside chroot (background)
          chroot /var/lib/cm/rootfs /bin/bash -c '
            export HOSTNAME=${EDGE_HOST_NAME}
            mkdir -p /var/spool/cmd /var/run
            /cm/local/apps/cmd/sbin/cmd -s -n &
          ' >/dev/null 2>&1 &

          echo "bcm-init: cmd chroot started"
BCMEOF
    )
fi

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
${BCM_STAGES}
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
