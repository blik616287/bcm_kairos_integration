#!/bin/bash
# extract-kairos-pxe.sh
#
# Extracts PXE boot artifacts from a CanvOS-built Kairos ISO:
#   - vmlinuz (kernel)
#   - initrd (initramfs)
#   - rootfs.squashfs (squashfs root filesystem)
#   - kairos-boot.ipxe (iPXE boot script for BCM head node)
#
# The Kairos ISO (built by osbuilder-tools) has this structure:
#   /boot/kernel or /boot/kernel.xz
#   /boot/initrd
#   /rootfs.squashfs
#
# Usage:
#   ./extract-kairos-pxe.sh [OPTIONS]
#
# After extracting, test with:
#   ./test-kairos-pxe.sh --direct

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
ISO_PATH="${BUILD_DIR}/palette-edge-installer.iso"
OUTPUT_DIR="${BUILD_DIR}/pxe"
CLEAN=false

# BCM head node IP on internalnet
HEAD_NODE_IP="10.141.255.254"
HTTP_PORT="8888"

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

Extracts PXE boot artifacts from a Kairos ISO.

Options:
  --iso PATH           Path to Kairos ISO (default: build/palette-edge-installer.iso)
  --output-dir DIR     Output directory (default: build/pxe/)
  --edge-name NAME     Edge host name for Palette + BCM (default: node001)
  --head-ip IP         BCM head node internal IP (default: 10.141.255.254)
  --http-port PORT     HTTP server port on head node (default: 8888)
  --clean              Remove existing PXE artifacts first
  -h, --help           Show this help

Outputs:
  build/pxe/vmlinuz           Kernel
  build/pxe/initrd            Initramfs
  build/pxe/rootfs.squashfs   Root filesystem
  build/pxe/user-data.yaml    Cloud-config (SSH user: kairos/kairos)
  build/pxe/kairos-boot.ipxe  iPXE boot script

After extracting, test with:
  ./test-kairos-pxe.sh --direct
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --iso)          ISO_PATH="$2"; shift 2 ;;
        --output-dir)   OUTPUT_DIR="$2"; shift 2 ;;
        --edge-name)    EDGE_HOST_NAME="$2"; shift 2 ;;
        --head-ip)      HEAD_NODE_IP="$2"; shift 2 ;;
        --http-port)    HTTP_PORT="$2"; shift 2 ;;
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
    echo "Cleaning existing PXE artifacts..."
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
echo " Extracting Kairos PXE Artifacts"
echo "============================================"
echo " ISO:    $ISO_PATH"
echo " Output: $OUTPUT_DIR"
echo "============================================"
echo ""

echo "[1/8] Mounting ISO..."
sudo mount -o loop,ro "$ISO_PATH" "$MOUNT_DIR"

# ---- Extract kernel ----
echo "[2/8] Extracting kernel..."
if [[ -f "${MOUNT_DIR}/boot/kernel" ]]; then
    sudo cp "${MOUNT_DIR}/boot/kernel" "${OUTPUT_DIR}/vmlinuz"
elif [[ -f "${MOUNT_DIR}/boot/kernel.xz" ]]; then
    sudo cp "${MOUNT_DIR}/boot/kernel.xz" "${OUTPUT_DIR}/vmlinuz"
else
    echo "ERROR: No kernel found in ISO at /boot/kernel or /boot/kernel.xz"
    echo "Contents of /boot/:"
    ls -la "${MOUNT_DIR}/boot/" 2>/dev/null || echo "  (no /boot directory)"
    exit 1
fi
sudo chmod 644 "${OUTPUT_DIR}/vmlinuz"

# ---- Extract initrd ----
echo "[3/8] Extracting initrd..."
if [[ -f "${MOUNT_DIR}/boot/initrd" ]]; then
    sudo cp "${MOUNT_DIR}/boot/initrd" "${OUTPUT_DIR}/initrd"
else
    echo "ERROR: No initrd found in ISO at /boot/initrd"
    exit 1
fi
sudo chmod 644 "${OUTPUT_DIR}/initrd"

# ---- Extract squashfs ----
echo "[4/8] Extracting rootfs.squashfs..."
if [[ -f "${MOUNT_DIR}/rootfs.squashfs" ]]; then
    sudo cp "${MOUNT_DIR}/rootfs.squashfs" "${OUTPUT_DIR}/rootfs.squashfs"
else
    # Search for it elsewhere in the ISO
    SQFS=$(find "${MOUNT_DIR}" -name "*.squashfs" -print -quit 2>/dev/null || true)
    if [[ -n "$SQFS" ]]; then
        echo "  Found squashfs at: ${SQFS#$MOUNT_DIR}"
        sudo cp "$SQFS" "${OUTPUT_DIR}/rootfs.squashfs"
    else
        echo "ERROR: No squashfs found in ISO"
        echo "ISO contents:"
        ls -la "${MOUNT_DIR}/" 2>/dev/null
        exit 1
    fi
fi
sudo chmod 644 "${OUTPUT_DIR}/rootfs.squashfs"

# ---- Unmount ----
sudo umount "$MOUNT_DIR"

# ---- Generate iPXE boot script ----
echo "[5/8] Generating user-data cloud-config..."

cat > "${OUTPUT_DIR}/user-data.yaml" <<USERDATA
#cloud-config

# Palette Edge Registration
stylus:
  site:
    paletteEndpoint: ${PALETTE_ENDPOINT}
    edgeHostToken: ${PALETTE_TOKEN}
    projectUid: ${PALETTE_PROJECT_UID}
    name: ${EDGE_HOST_NAME}

# Auto-install to local disk on PXE boot
install:
  auto: true
  device: auto
  reboot: true
  grub-entry-name: "Palette eXtended Kubernetes Edge"
  system:
    size: 4096
  passive:
    size: 4096
  recovery-system:
    size: 4096
  partitions:
    oem:
      size: 2048
      fs: ext4

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
    - name: "Ensure stylus config exists to prevent crash loop"
      if: "[ ! -f /oem/80_stylus.yaml ] && [ -f /etc/kairos/80_stylus.yaml ]"
      commands:
        - cp /etc/kairos/80_stylus.yaml /oem/80_stylus.yaml
    - name: "Auto-install Kairos to disk"
      if: "[ ! -e /dev/disk/by-label/COS_ACTIVE ]"
      commands:
        - kairos-agent manual-install --device auto --reboot /oem/99_userdata.yaml
  after-install:
    - name: "Set GRUB to registration mode for first boot"
      commands:
        - rm -f /oem/80_stylus.yaml
        - grub2-editenv /oem/grubenv set saved_entry=registration
USERDATA

# ---- Build initrd overlay with user-data embedded ----
# With rd.cos.disable, immucore doesn't fetch config_url and the initramfs /oem/
# doesn't survive switch_root. So we add a dracut pre-pivot hook that copies
# the user-data from the initramfs to /sysroot/oem/ before switch_root.
echo "[6/8] Building initrd overlay with embedded user-data..."
OVERLAY_DIR=$(mktemp -d)

# Place user-data in initramfs /oem/
mkdir -p "${OVERLAY_DIR}/oem"
cp "${OUTPUT_DIR}/user-data.yaml" "${OVERLAY_DIR}/oem/99_userdata.yaml"

# Add dracut pre-pivot hook to copy /oem into /sysroot/oem before switch_root
# and inject a systemd service for auto-install (boot stages don't run with boot_mode=unknown)
mkdir -p "${OVERLAY_DIR}/usr/lib/dracut/hooks/pre-pivot"
cat > "${OVERLAY_DIR}/usr/lib/dracut/hooks/pre-pivot/99-copy-oem-userdata.sh" <<'HOOK'
#!/bin/sh
# Copy embedded user-data from initramfs /oem/ to real rootfs /sysroot/oem/
# This runs after rootfs is mounted but before switch_root.
if [ -f /oem/99_userdata.yaml ]; then
    mkdir -p /sysroot/oem
    cp /oem/99_userdata.yaml /sysroot/oem/99_userdata.yaml
    echo "kairos-pxe: copied user-data to /sysroot/oem/99_userdata.yaml"
fi

# Inject auto-install systemd service into the live rootfs.
# With rd.cos.disable, immucore sets boot_mode=unknown (overwrites any sentinel),
# which prevents kairos-agent from running user-defined boot stages.
# This service triggers manual-install directly via systemd instead.
mkdir -p /sysroot/etc/systemd/system/multi-user.target.wants
printf '%s\n' \
    '[Unit]' \
    'Description=Kairos Auto Install to Disk' \
    'After=network-online.target kairos-agent.service' \
    'Wants=network-online.target' \
    'ConditionPathExists=!/dev/disk/by-label/COS_ACTIVE' \
    '' \
    '[Service]' \
    'Type=oneshot' \
    'ExecStart=/usr/bin/kairos-agent manual-install --device auto --reboot /oem/99_userdata.yaml' \
    'StandardOutput=journal+console' \
    'StandardError=journal+console' \
    'TimeoutSec=infinity' \
    > /sysroot/etc/systemd/system/kairos-auto-install.service

ln -sf /etc/systemd/system/kairos-auto-install.service \
    /sysroot/etc/systemd/system/multi-user.target.wants/kairos-auto-install.service
echo "kairos-pxe: created auto-install systemd service"
HOOK
chmod +x "${OVERLAY_DIR}/usr/lib/dracut/hooks/pre-pivot/99-copy-oem-userdata.sh"

(cd "${OVERLAY_DIR}" && find . | cpio -o -H newc 2>/dev/null) | gzip > "${OUTPUT_DIR}/initrd-overlay.cgz"
rm -rf "${OVERLAY_DIR}"

echo "[7/8] Creating combined initrd (base + user-data overlay)..."
cat "${OUTPUT_DIR}/initrd" "${OUTPUT_DIR}/initrd-overlay.cgz" > "${OUTPUT_DIR}/initrd-combined"

echo "[8/8] Generating iPXE boot script..."

cat > "${OUTPUT_DIR}/kairos-boot.ipxe" <<IPXE
#!ipxe
# Kairos PXE boot script for BCM compute nodes
# Generated by extract-kairos-pxe.sh
#
# Serves Kairos kernel/initrd/squashfs from BCM head node HTTP server.
# The squashfs is fetched at boot time by dracut (live boot).

set http-server http://${HEAD_NODE_IP}:${HTTP_PORT}/kairos

echo
echo ==========================================
echo   Kairos Edge Installer - PXE Boot
echo ==========================================
echo
echo Server: \${http-server}
echo

echo Loading kernel...
kernel \${http-server}/vmlinuz rd.neednet=1 ip=dhcp rd.cos.disable root=live:\${http-server}/rootfs.squashfs rd.live.dir=/ rd.live.squashimg=rootfs.squashfs net.ifnames=1 console=tty1 console=ttyS0 rd.live.overlay.overlayfs selinux=0 rd.immucore.sysrootwait=600 config_url=\${http-server}/user-data.yaml

echo Loading initrd...
initrd \${http-server}/initrd

echo Booting Kairos...
boot
IPXE

# ---- Checksums ----
cd "$OUTPUT_DIR"
sha256sum vmlinuz initrd rootfs.squashfs user-data.yaml > SHA256SUMS

# ---- Summary ----
KERNEL_SIZE=$(du -h "${OUTPUT_DIR}/vmlinuz" | cut -f1)
INITRD_SIZE=$(du -h "${OUTPUT_DIR}/initrd" | cut -f1)
SQFS_SIZE=$(du -h "${OUTPUT_DIR}/rootfs.squashfs" | cut -f1)

echo ""
echo "============================================"
echo " Extraction complete!"
echo "============================================"
echo " ${OUTPUT_DIR}/vmlinuz          (${KERNEL_SIZE})"
echo " ${OUTPUT_DIR}/initrd           (${INITRD_SIZE})"
echo " ${OUTPUT_DIR}/rootfs.squashfs  (${SQFS_SIZE})"
echo " ${OUTPUT_DIR}/user-data.yaml"
echo " ${OUTPUT_DIR}/kairos-boot.ipxe"
echo " ${OUTPUT_DIR}/SHA256SUMS"
echo ""
echo " Next: ./test-kairos-pxe.sh --direct"
echo "============================================"
