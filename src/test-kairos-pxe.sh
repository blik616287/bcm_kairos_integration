#!/bin/bash
# test-kairos-pxe.sh
#
# Deploys Kairos as a BCM software image and launches a compute node VM
# that gets provisioned by BCM's native PXE boot chain.
#
# How it works:
#   1. Uploads rootfs.squashfs to BCM head node
#   2. Extracts it as a BCM software image (/cm/images/kairos-image/)
#   3. Configures node001 in cmsh (MAC, installmode=FULL, softwareimage)
#   4. Launches compute node QEMU — BCM PXE provisions it automatically
#   5. After provisioning, node reboots from disk into Kairos
#
# Prerequisites:
#   1. BCM head node running in KVM (launch-bcm-kvm.sh --disk or --auto)
#   2. Kairos PXE artifacts extracted (extract-kairos-pxe.sh)
#
# Usage:
#   ./test-kairos-pxe.sh [OPTIONS]
#
# Examples:
#   ./test-kairos-pxe.sh                 # Deploy + launch (BCM provisions Kairos)
#   ./test-kairos-pxe.sh --no-launch     # Deploy only, don't start VM
#   ./test-kairos-pxe.sh --skip-upload   # Launch VM only (already deployed)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PXE_DIR="${PROJECT_DIR}/build/pxe"

# BCM head node connection
SSH_PORT=10022
BCM_PASSWORD="${BCM_PASSWORD:?ERROR: BCM_PASSWORD not set. Set in env.json or export BCM_PASSWORD}"

# Head node internal IP
HEAD_NODE_IP="10.141.255.254"

# Compute node VM settings
COMPUTE_RAM="4096"
COMPUTE_CPUS="2"
COMPUTE_DISK_SIZE="80G"
COMPUTE_DISK="${PROJECT_DIR}/build/compute-node-disk.qcow2"
COMPUTE_MAC="52:54:00:00:02:01"

# Mode
NO_LAUNCH=false
SKIP_UPLOAD=false
RESET_COMPUTE=false

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Deploys Kairos as a BCM software image and provisions a compute node.

Options:
  --no-launch          Deploy only, don't launch compute VM
  --skip-upload        Skip deploy, only launch compute VM
  --pxe-dir DIR        PXE artifacts directory (default: build/pxe/)
  --ssh-port PORT      BCM head node SSH port (default: 10022)
  --password PASS      BCM root password
  --compute-ram MB     Compute node RAM (default: 4096)
  --compute-cpus N     Compute node CPUs (default: 2)
  --compute-disk-size  Compute node disk size (default: 80G)
  --reset-compute      Delete existing compute node disk
  -h, --help           Show this help

Examples:
  $0                   # Deploy + launch (BCM provisions Kairos)
  $0 --no-launch       # Deploy only
  $0 --skip-upload     # Launch VM (already deployed)
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-launch)        NO_LAUNCH=true; shift ;;
        --skip-upload)      SKIP_UPLOAD=true; shift ;;
        --pxe-dir)          PXE_DIR="$2"; shift 2 ;;
        --ssh-port)         SSH_PORT="$2"; shift 2 ;;
        --password)         BCM_PASSWORD="$2"; shift 2 ;;
        --compute-ram)      COMPUTE_RAM="$2"; shift 2 ;;
        --compute-cpus)     COMPUTE_CPUS="$2"; shift 2 ;;
        --compute-disk-size) COMPUTE_DISK_SIZE="$2"; shift 2 ;;
        --reset-compute)    RESET_COMPUTE=true; shift ;;
        -h|--help)          usage ;;
        *)                  echo "Unknown option: $1"; usage ;;
    esac
done

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
SSH_CMD="sshpass -p ${BCM_PASSWORD} ssh ${SSH_OPTS} -p ${SSH_PORT} root@localhost"
SCP_CMD="sshpass -p ${BCM_PASSWORD} scp ${SSH_OPTS} -P ${SSH_PORT}"

# ---- Preflight ----
if [[ "$SKIP_UPLOAD" != "true" ]]; then
    if [[ ! -f "${PXE_DIR}/rootfs.squashfs" ]]; then
        echo "ERROR: rootfs.squashfs not found at ${PXE_DIR}/rootfs.squashfs"
        echo "Run ./extract-kairos-pxe.sh first."
        exit 1
    fi
    if [[ ! -f "${PXE_DIR}/user-data.yaml" ]]; then
        echo "ERROR: user-data.yaml not found at ${PXE_DIR}/user-data.yaml"
        echo "Run ./extract-kairos-pxe.sh first."
        exit 1
    fi

    if ! command -v sshpass &>/dev/null; then
        echo "ERROR: sshpass not found. Install with: sudo apt install sshpass"
        exit 1
    fi
fi

if ! command -v qemu-system-x86_64 &>/dev/null; then
    echo "ERROR: qemu-system-x86_64 not found"
    exit 1
fi

# Check head node is reachable
echo "[..] Checking BCM head node connectivity..."
if ! ${SSH_CMD} "echo ok" &>/dev/null; then
    echo "ERROR: Cannot SSH to BCM head node at localhost:${SSH_PORT}"
    echo "Ensure the head node is running: ./launch-bcm-kvm.sh --disk"
    exit 1
fi
echo "[OK] BCM head node is reachable"

# ---- Deploy Kairos as BCM software image ----
if [[ "$SKIP_UPLOAD" != "true" ]]; then
    echo ""
    echo "============================================"
    echo " Deploying Kairos as BCM Software Image"
    echo "============================================"

    # Check if image already exists and is current
    EXTRACTED=false
    EXISTING=$(${SSH_CMD} "ls -d /cm/images/kairos-image 2>/dev/null && echo yes || echo no")
    if [[ "$EXISTING" == "yes" ]]; then
        echo "[..] kairos-image already exists, checking if squashfs is newer..."
        LOCAL_SIZE=$(stat -c%s "${PXE_DIR}/rootfs.squashfs")
        REMOTE_MARKER=$(${SSH_CMD} "cat /cm/images/kairos-image/.squashfs-size 2>/dev/null || echo 0")
        if [[ "$LOCAL_SIZE" == "$REMOTE_MARKER" ]]; then
            echo "[OK] kairos-image is up to date, skipping extraction"
        else
            echo "[..] Squashfs changed, re-deploying..."
            EXISTING="no"
        fi
    fi

    if [[ "$EXISTING" != "yes" ]]; then
        EXTRACTED=true
        echo "[1/7] Uploading rootfs.squashfs (this takes a while)..."
        ${SCP_CMD} "${PXE_DIR}/rootfs.squashfs" root@localhost:/tmp/kairos-rootfs.squashfs

        echo "[2/7] Extracting to /cm/images/kairos-image/..."
        ${SSH_CMD} "rm -rf /cm/images/kairos-image && unsquashfs -d /cm/images/kairos-image /tmp/kairos-rootfs.squashfs && rm -f /tmp/kairos-rootfs.squashfs"
        LOCAL_SIZE=$(stat -c%s "${PXE_DIR}/rootfs.squashfs")
        ${SSH_CMD} "echo ${LOCAL_SIZE} > /cm/images/kairos-image/.squashfs-size"
    else
        echo "[1/7] Upload: skipped (image up to date)"
        echo "[2/7] Extract: skipped (image up to date)"
    fi

    echo "[3/7] Registering as BCM software image (cm-create-image)..."
    # cm-create-image must run BEFORE image fixes because it overwrites /etc/default/grub
    if [[ "$EXTRACTED" == "true" ]]; then
        # Image was re-extracted — must re-run cm-create-image to reinstall BCM packages
        # Use -u (update) if image already registered, otherwise create fresh
        ${SSH_CMD} << 'CM_CREATE'
if cmsh -c "softwareimage; use kairos-image" 2>/dev/null; then
    echo "Updating existing kairos-image registration..."
    cm-create-image -d /cm/images/kairos-image --minimal --skipdist -n kairos-image -g public -u -f 2>&1 | tail -5
else
    echo "Creating new kairos-image registration..."
    cm-create-image -d /cm/images/kairos-image --minimal --skipdist -n kairos-image -g public -f 2>&1 | tail -5
fi
echo "[OK] kairos-image registered via cm-create-image"
CM_CREATE
    else
        ${SSH_CMD} << 'CM_CREATE'
if cmsh -c "softwareimage; use kairos-image" 2>/dev/null; then
    echo "[OK] kairos-image already registered in cmsh"
else
    cm-create-image -d /cm/images/kairos-image --minimal --skipdist -n kairos-image -g public -f 2>&1 | tail -5
    echo "[OK] kairos-image registered via cm-create-image"
fi
CM_CREATE
    fi

    echo "[4/7] Placing user-data and stylus cloud-configs..."
    ${SCP_CMD} "${PXE_DIR}/user-data.yaml" root@localhost:/cm/images/kairos-image/oem/99_userdata.yaml
    # 80_stylus.yaml must exist in /oem/ or stylus-agent crashes on boot.
    # In a normal Kairos install, boot stages copy it; BCM provisioning skips those stages.
    ${SSH_CMD} << 'STYLUS_COPY'
if [ ! -f /cm/images/kairos-image/oem/80_stylus.yaml ] && [ -f /cm/images/kairos-image/etc/kairos/80_stylus.yaml ]; then
    cp /cm/images/kairos-image/etc/kairos/80_stylus.yaml /cm/images/kairos-image/oem/80_stylus.yaml
    echo "[OK] Copied 80_stylus.yaml to /oem/"
else
    echo "[OK] 80_stylus.yaml already in /oem/"
fi
STYLUS_COPY

    echo "[5/7] Configuring image for BCM provisioning..."
    # Must run AFTER cm-create-image, which overwrites /etc/default/grub
    ${SSH_CMD} << 'IMAGE_FIXES'
# Enable GRUB kernel boot entries: BCM disables 10_linux so nodes always PXE boot.
# We need native disk boot for Kairos kernel + stylus-agent.
chmod +x /cm/images/kairos-image/etc/grub.d/10_linux 2>/dev/null && \
    echo "[OK] Made 10_linux executable" || true

# Add stylus.registration + serial console to GRUB cmdline
GRUB_CFG="/cm/images/kairos-image/etc/default/grub"
if [ -f "$GRUB_CFG" ]; then
    if ! grep -q "stylus.registration" "$GRUB_CFG"; then
        sed -i 's/GRUB_CMDLINE_LINUX="biosdevname=0/GRUB_CMDLINE_LINUX="stylus.registration biosdevname=0/' "$GRUB_CFG"
        echo "[OK] Added stylus.registration to GRUB cmdline"
    fi
    if ! grep -q "console=ttyS0" "$GRUB_CFG"; then
        sed -i 's/GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 console=ttyS0,115200 console=tty0"/' "$GRUB_CFG"
        echo "[OK] Added serial console to GRUB cmdline"
    fi
fi

# Ensure ifupdown is installed: cm-create-image removes NetworkManager and masks
# systemd-networkd, so ifupdown is the only way to bring up interfaces after disk boot.
if ! chroot /cm/images/kairos-image which ifup &>/dev/null; then
    chroot /cm/images/kairos-image bash -c 'apt-get install -y --no-install-recommends ifupdown 2>&1 | tail -3'
    echo "[OK] Installed ifupdown"
else
    echo "[OK] ifupdown already installed"
fi
mkdir -p /cm/images/kairos-image/etc/network/interfaces.d
echo "[OK] Ensured /etc/network/interfaces.d/ exists"

# Enable Palette services (stylus-agent, stylus-operator)
# In normal Kairos boot, boot stages enable these; BCM provisioning skips those.
WANTS="/cm/images/kairos-image/etc/systemd/system/multi-user.target.wants"
mkdir -p "$WANTS"
for svc in stylus-agent stylus-operator; do
    SVC_FILE="/cm/images/kairos-image/etc/systemd/system/${svc}.service"
    if [ -f "$SVC_FILE" ] && [ ! -L "${WANTS}/${svc}.service" ]; then
        ln -sf "/etc/systemd/system/${svc}.service" "${WANTS}/${svc}.service"
        echo "[OK] Enabled ${svc}.service"
    fi
done
IMAGE_FIXES

    echo "[6/7] Patching PXE template..."
    # IPAPPEND 2 (BOOTIF only, no ip= injection)
    # BCM's default IPAPPEND 3 injects ip= which conflicts with the node-installer
    ${SSH_CMD} << 'TEMPLATE_PATCH'
for tmpl in /tftpboot/pxelinux.cfg/template /tftpboot/x86_64/bios/pxelinux.cfg/template; do
    if [ -f "$tmpl" ] && grep -q "IPAPPEND 3" "$tmpl"; then
        sed -i 's/IPAPPEND 3/IPAPPEND 2/g' "$tmpl"
        echo "[OK] Patched $tmpl: IPAPPEND 3 -> 2"
    fi
done
TEMPLATE_PATCH

    echo "[7/7] Configuring node001..."
    # Configure node001 (needs variable expansion so separate heredoc)
    ${SSH_CMD} << CMSH_SETUP
cmsh << 'CMSH'
device
use node001
set mac ${COMPUTE_MAC}
set installmode FULL
set softwareimage kairos-image
commit
CMSH
echo "[OK] node001: MAC=${COMPUTE_MAC}, installmode=FULL, image=kairos-image"
CMSH_SETUP

    echo "[..] Waiting for ramdisk generation..."
    ${SSH_CMD} << 'WAIT_RAMDISK'
KERNEL_VER=$(cmsh -c "softwareimage; use kairos-image; get kernelversion" 2>/dev/null)
INITRD="/cm/images/kairos-image/boot/initrd.cm.img-${KERNEL_VER}"
for i in $(seq 1 60); do
    if [ -f "$INITRD" ]; then
        echo "[OK] initrd.cm.img generated ($(du -h "$INITRD" | cut -f1))"
        break
    fi
    sleep 5
done
if [ ! -f "$INITRD" ]; then
    echo "[WARN] initrd.cm.img not found after 5 minutes, triggering manually..."
    cmsh -c "softwareimage; use kairos-image; createramdisk" 2>/dev/null
    sleep 30
fi
# Regenerate node001 ramdisk
cmsh -c "device; use node001; createramdisk" 2>/dev/null
sleep 15
echo "[OK] Node ramdisk ready"
WAIT_RAMDISK

    echo ""
    echo "[OK] BCM configured to provision Kairos on node001"
fi

if [[ "$NO_LAUNCH" == "true" ]]; then
    echo ""
    echo "============================================"
    echo " Deploy complete (--no-launch specified)"
    echo "============================================"
    echo " node001 will PXE boot and get Kairos via BCM provisioning."
    echo " To launch: $0 --skip-upload"
    echo "============================================"
    exit 0
fi

# ---- Launch compute node VM ----
echo ""
echo "============================================"
echo " Launching Kairos Compute Node VM"
echo "============================================"

KVM_FLAG=""
if [[ -e /dev/kvm ]]; then
    KVM_FLAG="-enable-kvm"
fi

if [[ "$RESET_COMPUTE" == "true" ]] && [[ -f "$COMPUTE_DISK" ]]; then
    echo "Removing existing compute node disk..."
    rm -f "$COMPUTE_DISK"
fi

if [[ ! -f "$COMPUTE_DISK" ]]; then
    echo "Creating ${COMPUTE_DISK_SIZE} compute node disk..."
    qemu-img create -f qcow2 "$COMPUTE_DISK" "$COMPUTE_DISK_SIZE"
fi

echo " Mode:      BCM PXE provisioning → disk boot"
echo " RAM:       ${COMPUTE_RAM} MB"
echo " CPUs:      ${COMPUTE_CPUS}"
echo " Disk:      ${COMPUTE_DISK}"
echo " MAC:       ${COMPUTE_MAC}"
mkdir -p "${PROJECT_DIR}/logs"
SERIAL_LOG="${PROJECT_DIR}/logs/kairos-serial.log"
echo " Network:   BCM internal (socket connect :31337)"
echo " Serial:    ${SERIAL_LOG}"
echo "============================================"
echo ""
echo "Boot order: disk first, then network (PXE)."
echo "First boot: empty disk → PXE → BCM provisions → GRUB installed → reboot → Kairos"
echo ""
echo "Tip: tail -f ${SERIAL_LOG}"
echo ""

> "${SERIAL_LOG}"

# Boot order: disk first, network fallback
# First boot: disk is empty → falls through to PXE → BCM provisions → installs GRUB
# After provisioning + reboot: boots from disk → Kairos
exec qemu-system-x86_64 \
    ${KVM_FLAG} \
    -m "${COMPUTE_RAM}" \
    -smp "${COMPUTE_CPUS}" \
    -cpu host \
    -name "Kairos-ComputeNode" \
    -smbios type=1,uuid=52540000-0201-0000-0000-525400000201 \
    -drive file="${COMPUTE_DISK}",format=qcow2,if=virtio \
    -netdev socket,id=intnet,connect=:31337 \
    -device virtio-net-pci,netdev=intnet,mac=${COMPUTE_MAC} \
    -vga virtio \
    -display gtk \
    -serial file:"${SERIAL_LOG}" \
    -boot order=cn
