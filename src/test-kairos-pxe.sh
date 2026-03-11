#!/bin/bash
# test-kairos-pxe.sh
#
# End-to-end: deploys Kairos as a BCM software image and boots a compute node.
#
# BCM handles everything:
#   1. Upload squashfs → unsquash as /cm/images/kairos-image/
#   2. cm-create-image registers it + installs BCM node packages
#   3. Configure node001 in cmsh (MAC, installmode=FULL, softwareimage=kairos-image)
#   4. Launch compute VM → BCM PXE boots it → node-installer rsyncs image to disk
#   5. BCM installs GRUB and reboots the node
#   6. Node boots from disk into Kairos → stylus-agent registers with Palette
#
# This script only prepares the image and launches the VM. BCM handles
# disk provisioning, GRUB, and reboot. No live boot or dracut hooks.
#
# Prerequisites:
#   - BCM head node running (launch-bcm-kvm.sh --disk or --auto)
#   - Kairos artifacts extracted (extract-kairos-pxe.sh)
#
# Usage:
#   ./test-kairos-pxe.sh                 # Deploy + launch
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

# Display: use gtk if DISPLAY or WAYLAND_DISPLAY is set, otherwise headless
if [[ -z "${QEMU_DISPLAY:-}" ]]; then
    if [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
        QEMU_DISPLAY="gtk"
    else
        QEMU_DISPLAY="none"
    fi
fi

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
SCP_CMD="sshpass -p ${BCM_PASSWORD} scp -O ${SSH_OPTS} -P ${SSH_PORT}"

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

# Wait for cmfirstboot to finish — BCM services aren't ready until it completes
echo "[..] Waiting for cmfirstboot to complete..."
elapsed=0
while true; do
    CMFB_STATUS=$(${SSH_CMD} "systemctl is-active cmfirstboot" 2>/dev/null || echo "unknown")
    if [[ "$CMFB_STATUS" != "activating" && "$CMFB_STATUS" != "active" ]]; then
        break
    fi
    elapsed=$((elapsed + 10))
    printf "\r  [%dm%02ds] cmfirstboot still running..." $((elapsed / 60)) $((elapsed % 60))
    sleep 10
done
echo ""

# Verify cmfirstboot completed successfully (not failed)
CMFB_RESULT=$(${SSH_CMD} "systemctl show cmfirstboot --property=Result --value" 2>/dev/null || echo "unknown")
if [[ "$CMFB_RESULT" != "success" ]]; then
    echo "[WARN] cmfirstboot result: ${CMFB_RESULT}"
fi
echo "[OK] cmfirstboot complete"

# Wait for key BCM services to be ready (cmd, CMDaemon)
echo "[..] Waiting for BCM services..."
elapsed=0
while true; do
    CMD_STATUS=$(${SSH_CMD} "systemctl is-active cmd" 2>/dev/null || echo "inactive")
    CMDAEMON_STATUS=$(${SSH_CMD} "systemctl is-active cmdaemon" 2>/dev/null || echo "inactive")
    if [[ "$CMD_STATUS" == "active" ]] && [[ "$CMDAEMON_STATUS" == "active" ]]; then
        break
    fi
    elapsed=$((elapsed + 5))
    if [[ $elapsed -ge 300 ]]; then
        echo ""
        echo "ERROR: BCM services not ready after 5 minutes (cmd=${CMD_STATUS}, cmdaemon=${CMDAEMON_STATUS})"
        exit 1
    fi
    printf "\r  [%dm%02ds] cmd=%s cmdaemon=%s" $((elapsed / 60)) $((elapsed % 60)) "$CMD_STATUS" "$CMDAEMON_STATUS"
    sleep 5
done
echo ""
echo "[OK] BCM services ready (cmd + cmdaemon active)"

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

    echo "[4/7] Placing user-data..."
    ${SCP_CMD} "${PXE_DIR}/user-data.yaml" root@localhost:/cm/images/kairos-image/oem/99_userdata.yaml
    # 80_stylus.yaml must NOT be in /oem/ during initial registration.
    # With it present, stylus-agent takes the upgrade path instead of registration,
    # which crashes on auth failure and poisons Palette rate limits.
    # Without it, the agent enters registration mode and retries properly.
    # After successful registration, stylus-agent creates its own config files.
    ${SSH_CMD} << 'STYLUS_CHECK'
if [ -f /cm/images/kairos-image/oem/80_stylus.yaml ]; then
    rm -f /cm/images/kairos-image/oem/80_stylus.yaml
    echo "[OK] Removed 80_stylus.yaml from /oem/ (prevents upgrade-path crash)"
else
    echo "[OK] 80_stylus.yaml not in /oem/ (correct for registration)"
fi
STYLUS_CHECK

    echo "[5/7] Configuring image for BCM provisioning..."
    ${SSH_CMD} << 'IMAGE_FIXES'
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
# Registration mode is handled by bcm-sync-userdata.sh (ExecStartPre overlay).
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
    # Configure node001 — pipe cmsh commands via echo to avoid nested heredoc expansion issues
    ${SSH_CMD} "echo -e 'device\nuse node001\nset mac ${COMPUTE_MAC}\nset installmode FULL\nset softwareimage kairos-image\ncommit' | cmsh && echo '[OK] node001: MAC=${COMPUTE_MAC}, installmode=FULL, image=kairos-image'"

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
echo "First boot: empty disk → PXE → BCM rsyncs image + installs GRUB → reboot → Kairos + Palette registration"
echo ""
echo "Tip: tail -f ${SERIAL_LOG}"
echo ""

> "${SERIAL_LOG}"

# Boot order: disk first, network fallback
# First boot: disk is empty → falls through to PXE → BCM rsyncs image + installs GRUB
# After reboot: boots from disk → Kairos + stylus-agent registers with Palette
qemu-system-x86_64 \
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
    -display "${QEMU_DISPLAY:-none}" \
    -serial file:"${SERIAL_LOG}" \
    -pidfile "${PROJECT_DIR}/build/.kairos-qemu.pid" \
    -daemonize \
    -boot order=cn

echo "[..] Compute node VM started, waiting for BCM provisioning + SSH..."

# Wait for node001 to be UP in BCM and SSH-reachable
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
elapsed=0
timeout=900
while true; do
    # Check if QEMU is still running
    if ! pgrep -f "qemu-system.*Kairos-ComputeNode" >/dev/null 2>&1; then
        echo ""
        echo "[FAIL] Compute node QEMU exited unexpectedly"
        exit 1
    fi

    # Check if node001 is UP and SSH-reachable via BCM
    NODE_STATUS=$(${SSH_CMD} "cmsh -c 'device; use node001; status' 2>/dev/null" 2>/dev/null || true)
    if echo "$NODE_STATUS" | grep -q "UP"; then
        if ${SSH_CMD} "ssh ${SSH_OPTS} -o ConnectTimeout=3 root@10.141.0.1 'echo ok'" >/dev/null 2>&1; then
            echo ""
            echo "[OK] Kairos compute node is UP and SSH-ready (${elapsed}s)"
            break
        fi
    fi

    elapsed=$((elapsed + 10))
    if [[ $elapsed -ge $timeout ]]; then
        echo ""
        echo "[FAIL] Compute node not ready after ${timeout}s"
        exit 1
    fi
    printf "\r  [%dm%02ds] Waiting... %s" $((elapsed / 60)) $((elapsed % 60)) "$(echo "$NODE_STATUS" | tr -d '[:space:]' | head -c 40)"
    sleep 10
done

# ---- Post-provisioning validation ----
echo "[..] Validating services on compute node..."
NODE_SSH="${SSH_CMD} \"ssh ${SSH_OPTS} root@10.141.0.1\""
FAIL=false

# Check cmd service
if ${SSH_CMD} "ssh ${SSH_OPTS} root@10.141.0.1 'systemctl is-active cmd'" 2>/dev/null | grep -q "active"; then
    echo "[OK] cmd service is active"
else
    echo "[FAIL] cmd service is not active"
    FAIL=true
fi

# Check stylus-agent service
if ${SSH_CMD} "ssh ${SSH_OPTS} root@10.141.0.1 'systemctl is-active stylus-agent'" 2>/dev/null | grep -q "active"; then
    echo "[OK] stylus-agent is active"
else
    echo "[FAIL] stylus-agent is not active"
    FAIL=true
fi

# Wait for successful Palette registration (with timeout)
echo "[..] Waiting for Palette registration..."
reg_elapsed=0
reg_timeout=300
while true; do
    if ${SSH_CMD} "ssh ${SSH_OPTS} root@10.141.0.1 'journalctl -u stylus-agent --no-pager'" 2>/dev/null | grep -q "Registration completed"; then
        echo "[OK] Palette registration completed"
        break
    fi
    reg_elapsed=$((reg_elapsed + 10))
    if [[ $reg_elapsed -ge $reg_timeout ]]; then
        echo "[FAIL] Palette registration not completed after ${reg_timeout}s"
        FAIL=true
        break
    fi
    printf "\r  [%dm%02ds] Waiting for registration..." $((reg_elapsed / 60)) $((reg_elapsed % 60))
    sleep 10
done

if [[ "$FAIL" == "true" ]]; then
    echo ""
    echo "[FAIL] Post-provisioning validation failed"
    exit 1
fi

echo ""
echo "[OK] Compute node fully provisioned and registered (total: $((elapsed + reg_elapsed))s)"
