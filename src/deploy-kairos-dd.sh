#!/bin/bash
# deploy-kairos-dd.sh
#
# Option B: Deploys Kairos via raw disk image dd.
#
# Instead of rsync'ing a squashfs (Option A), this:
#   1. Uploads a Kairos raw disk image to the BCM head node
#   2. Creates a BCM "installer" software image with a dd systemd service
#   3. BCM PXE boots the compute node and rsyncs the installer image
#   4. On first boot, the installer downloads the raw image and dd's it to disk
#   5. Node reboots into Kairos with proper COS partitions + immutability
#   6. Sets installmode NOSYNC to prevent BCM re-provisioning
#
# Prerequisites:
#   - BCM head node running (launch-bcm-kvm.sh --disk or --auto)
#   - Raw image generated (generate-raw-image.sh)
#
# Usage:
#   ./deploy-kairos-dd.sh                 # Deploy + launch
#   ./deploy-kairos-dd.sh --no-launch     # Deploy only, don't start VM
#   ./deploy-kairos-dd.sh --skip-upload   # Launch VM only (already deployed)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"

# BCM head node connection
SSH_PORT=10022
BCM_PASSWORD="${BCM_PASSWORD:?ERROR: BCM_PASSWORD not set. Set in env.json or export BCM_PASSWORD}"

# Head node internal IP
HEAD_NODE_IP="10.141.255.254"

# Raw image path
RAW_IMAGE="${BUILD_DIR}/kairos-disk.raw"

# Compute node VM settings
COMPUTE_RAM="4096"
COMPUTE_CPUS="2"
COMPUTE_DISK_SIZE="80G"
COMPUTE_DISK="${PROJECT_DIR}/build/compute-node-disk.qcow2"
COMPUTE_MAC="52:54:00:00:02:01"

# Display
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

Deploys Kairos via raw disk image dd (Option B).

Options:
  --no-launch          Deploy only, don't launch compute VM
  --skip-upload        Skip deploy, only launch compute VM
  --raw-image PATH     Path to raw disk image (default: build/kairos-disk.raw)
  --ssh-port PORT      BCM head node SSH port (default: 10022)
  --password PASS      BCM root password
  --compute-ram MB     Compute node RAM (default: 4096)
  --compute-cpus N     Compute node CPUs (default: 2)
  --compute-disk-size  Compute node disk size (default: 80G)
  --reset-compute      Delete existing compute node disk
  -h, --help           Show this help

Examples:
  $0                   # Deploy + launch (installer → dd → Kairos)
  $0 --no-launch       # Deploy only
  $0 --skip-upload     # Launch VM (already deployed)
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-launch)         NO_LAUNCH=true; shift ;;
        --skip-upload)       SKIP_UPLOAD=true; shift ;;
        --raw-image)         RAW_IMAGE="$2"; shift 2 ;;
        --ssh-port)          SSH_PORT="$2"; shift 2 ;;
        --password)          BCM_PASSWORD="$2"; shift 2 ;;
        --compute-ram)       COMPUTE_RAM="$2"; shift 2 ;;
        --compute-cpus)      COMPUTE_CPUS="$2"; shift 2 ;;
        --compute-disk-size) COMPUTE_DISK_SIZE="$2"; shift 2 ;;
        --reset-compute)     RESET_COMPUTE=true; shift ;;
        -h|--help)           usage ;;
        *)                   echo "Unknown option: $1"; usage ;;
    esac
done

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
SSH_CMD="sshpass -p ${BCM_PASSWORD} ssh ${SSH_OPTS} -p ${SSH_PORT} root@localhost"
SCP_CMD="sshpass -p ${BCM_PASSWORD} scp -O ${SSH_OPTS} -P ${SSH_PORT}"

# Filter BCM's MOTD noise from SSH command output.
filter_motd() {
    grep -vE "cmfirstboot is still in progress|^$" || true
}

# ---- Preflight ----
if [[ "$SKIP_UPLOAD" != "true" ]]; then
    if [[ ! -f "$RAW_IMAGE" ]]; then
        echo "ERROR: Raw disk image not found at ${RAW_IMAGE}"
        echo "Run ./generate-raw-image.sh first."
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

# Wait for cmfirstboot to finish
echo "[..] Waiting for cmfirstboot to complete..."
elapsed=0
while true; do
    CMFB_STATUS=$(${SSH_CMD} "systemctl is-active cmfirstboot" 2>/dev/null | filter_motd || echo "unknown")
    if [[ "$CMFB_STATUS" != "activating" && "$CMFB_STATUS" != "active" ]]; then
        break
    fi
    elapsed=$((elapsed + 10))
    printf "\r  [%dm%02ds] cmfirstboot still running..." $((elapsed / 60)) $((elapsed % 60))
    sleep 10
done
echo ""

CMFB_RESULT=$(${SSH_CMD} "systemctl show cmfirstboot --property=Result --value" 2>/dev/null | filter_motd || echo "unknown")
if [[ "$CMFB_RESULT" != "success" ]]; then
    echo "[WARN] cmfirstboot result: ${CMFB_RESULT}"
fi

# Wait for clean shell
echo "[..] Waiting for clean shell (no MOTD noise)..."
motd_elapsed=0
while true; do
    SHELL_OUTPUT=$(${SSH_CMD} "echo CLEAN" 2>/dev/null || echo "")
    if [[ "$SHELL_OUTPUT" == "CLEAN" ]]; then
        break
    fi
    motd_elapsed=$((motd_elapsed + 5))
    if [[ $motd_elapsed -ge 300 ]]; then
        echo ""
        echo "[WARN] .bashrc still producing MOTD after 5 minutes, proceeding anyway"
        break
    fi
    printf "\r  [%dm%02ds] .bashrc still noisy..." $((motd_elapsed / 60)) $((motd_elapsed % 60))
    sleep 5
done
echo ""
echo "[OK] cmfirstboot complete"

# Wait for BCM services
echo "[..] Waiting for BCM services (cmd + cmsh)..."
elapsed=0
while true; do
    CMD_STATUS=$(${SSH_CMD} "systemctl is-active cmd" 2>/dev/null | filter_motd || echo "inactive")
    CMSH_OK=$(${SSH_CMD} "cmsh -c 'device; list' >/dev/null 2>&1 && echo ok || echo no" 2>/dev/null | filter_motd || echo "no")
    if [[ "$CMD_STATUS" == "active" ]] && [[ "$CMSH_OK" == "ok" ]]; then
        break
    fi
    elapsed=$((elapsed + 5))
    if [[ $elapsed -ge 300 ]]; then
        echo ""
        echo "ERROR: BCM services not ready after 5 minutes (cmd=${CMD_STATUS}, cmsh=${CMSH_OK})"
        exit 1
    fi
    printf "\r  [%dm%02ds] cmd=%s cmsh=%s" $((elapsed / 60)) $((elapsed % 60)) "$CMD_STATUS" "$CMSH_OK"
    sleep 5
done
echo ""
echo "[OK] BCM services ready (cmd active, cmsh responsive)"

# Ensure sshpass is available on BCM (needed for Phase 2 Kairos SSH detection)
${SSH_CMD} "command -v sshpass >/dev/null 2>&1 || apt-get install -y -qq sshpass >/dev/null 2>&1" 2>/dev/null || true

# ---- Generate SSH key pair for Kairos → BCM communication ----
BCM_KEY="${BUILD_DIR}/bcm-kairos-key"
BCM_KEY_PUB="${BCM_KEY}.pub"
if [[ ! -f "$BCM_KEY" ]]; then
    echo "[..] Generating SSH key pair for Kairos → BCM..."
    ssh-keygen -t ed25519 -f "$BCM_KEY" -N "" -C "kairos-node@bcm" -q
fi
# Add public key to BCM authorized_keys (idempotent)
PUBKEY=$(cat "$BCM_KEY_PUB")
${SSH_CMD} "grep -qF '${PUBKEY}' /root/.ssh/authorized_keys 2>/dev/null || echo '${PUBKEY}' >> /root/.ssh/authorized_keys" 2>/dev/null || true
echo "[OK] SSH key pair ready (Kairos can SSH to BCM)"

# ---- Export BCM paths via NFS for cmd podman container ----
${SSH_CMD} "exportfs -v 2>/dev/null | grep -q '/cm/images/default-image' || exportfs -o ro,no_subtree_check,no_root_squash,async 10.141.0.0/16:/cm/images/default-image" 2>/dev/null || true
${SSH_CMD} "exportfs -v 2>/dev/null | grep -q '/cm/shared' || exportfs -o rw,no_subtree_check,no_root_squash,async 10.141.0.0/16:/cm/shared" 2>/dev/null || true
echo "[OK] BCM NFS exports configured (default-image, /cm/shared)"

# ---- Deploy Kairos raw image + installer ----
if [[ "$SKIP_UPLOAD" != "true" ]]; then
    echo ""
    echo "============================================"
    echo " Deploying Kairos via dd Installer (Option B)"
    echo "============================================"

    RAW_SIZE=$(du -h "$RAW_IMAGE" | cut -f1)
    echo " Raw image:  ${RAW_IMAGE} (${RAW_SIZE})"

    # Step 1: Upload raw image (compressed — raw image is sparse/80GB, scp would expand it)
    echo "[1/7] Compressing and uploading raw disk image to BCM head node..."
    ${SSH_CMD} "mkdir -p /cm/shared/kairos" | filter_motd
    COMPRESSED="${RAW_IMAGE}.gz"
    if [[ ! -f "$COMPRESSED" ]] || [[ "$RAW_IMAGE" -nt "$COMPRESSED" ]]; then
        echo "     Compressing raw image..."
        gzip -c "$RAW_IMAGE" > "$COMPRESSED"
    fi
    echo "     Uploading $(du -h "$COMPRESSED" | cut -f1) compressed image..."
    ${SCP_CMD} "${COMPRESSED}" root@localhost:/cm/shared/kairos/disk.raw.gz
    # Keep it compressed on head node — installer will decompress on-the-fly via curl | gunzip | dd

    # Step 2: Start HTTP server on BCM to serve the raw image
    echo "[2/7] Starting HTTP server on head node..."
    ${SSH_CMD} << 'HTTP_SETUP' | filter_motd
# Create systemd service for serving the raw image
cat > /etc/systemd/system/kairos-http.service << 'HTTPEOF'
[Unit]
Description=Kairos image HTTP server
After=network.target

[Service]
Type=simple
WorkingDirectory=/cm/shared/kairos
ExecStart=/usr/bin/python3 -m http.server 8888
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
HTTPEOF

systemctl daemon-reload
systemctl enable --now kairos-http

# Verify the server is serving the image
sleep 2
if curl --fail --silent --head http://localhost:8888/disk.raw.gz >/dev/null 2>&1; then
    SIZE=$(curl --fail --silent --head http://localhost:8888/disk.raw.gz | grep -i content-length | awk '{print $2}' | tr -d '\r')
    echo "[OK] HTTP server running, serving disk.raw.gz (${SIZE} bytes)"
else
    echo "[FAIL] HTTP server not serving disk.raw.gz"
    exit 1
fi
HTTP_SETUP

    # Step 3: Create BCM installer software image
    echo "[3/7] Creating BCM installer software image..."
    ${SSH_CMD} << 'INSTALLER_IMAGE' | filter_motd
# Check if kairos-installer image already exists
if cmsh -c "softwareimage; use kairos-installer" 2>/dev/null; then
    echo "kairos-installer already exists, reusing"
else
    echo "Cloning default-image to kairos-installer..."
    cmsh -c "softwareimage; clone default-image kairos-installer; commit" 2>&1
    echo "[OK] kairos-installer image created"
fi
INSTALLER_IMAGE

    # Step 4: Install the dd script and service into the image
    echo "[4/7] Installing dd service into kairos-installer image..."
    ${SSH_CMD} << 'INSTALL_DD' | filter_motd
IMAGE_ROOT="/cm/images/kairos-installer"

# Ensure target directories exist in the cloned image
mkdir -p "${IMAGE_ROOT}/usr/local/sbin"
mkdir -p "${IMAGE_ROOT}/etc/systemd/system"

# Write the installer script
# NOTE: This script dd's the Kairos image over the same disk it's running from.
# All binaries are staged to /dev/shm (tmpfs/RAM) first so dd can complete
# even after the on-disk filesystem is overwritten.
cat > "${IMAGE_ROOT}/usr/local/sbin/install-kairos.sh" << 'SCRIPT'
#!/bin/bash
set -euo pipefail

LOG="/dev/shm/kairos-install.log"
exec > >(tee -a "$LOG") 2>&1

HEAD_IP="10.141.255.254"
RAW_URL="http://${HEAD_IP}:8888/disk.raw.gz"
DISK=$(lsblk -ndo NAME,TYPE | awk '$2=="disk" && $1!~/^fd[0-9]/{print "/dev/"$1; exit}')

echo "[$(date)] ============================================"
echo "[$(date)] Kairos Raw Image Installer"
echo "[$(date)] ============================================"
echo "[$(date)] Image URL:  ${RAW_URL}"
echo "[$(date)] Target:     ${DISK:-NOT FOUND}"

if [[ -z "$DISK" || ! -b "$DISK" ]]; then
    echo "[$(date)] ERROR: No disk device found"
    lsblk 2>/dev/null || true
    exit 1
fi

echo "[$(date)] Waiting for image server..."
RETRIES=0
while ! curl --fail --silent --head "$RAW_URL" >/dev/null 2>&1; do
    RETRIES=$((RETRIES + 1))
    if [[ $RETRIES -ge 60 ]]; then
        echo "[$(date)] ERROR: Image server not available after 60 attempts"
        exit 1
    fi
    sleep 10
done

IMAGE_SIZE=$(curl --fail --silent --head "$RAW_URL" | grep -i content-length | awk '{print $2}' | tr -d '\r')
if [[ -n "$IMAGE_SIZE" ]]; then
    echo "[$(date)] Compressed image size: $(( IMAGE_SIZE / 1048576 )) MB"
fi

# Stage all binaries and libraries to RAM (tmpfs) before dd.
# dd overwrites the boot disk, so on-disk binaries become unavailable.
echo "[$(date)] Staging binaries to RAM..."
RAMDIR="/dev/shm/kinstall"
mkdir -p "$RAMDIR/lib"

for bin in bash curl gunzip dd sync reboot sleep; do
    BIN_PATH=$(which "$bin" 2>/dev/null) && cp "$BIN_PATH" "$RAMDIR/" || true
done

# Copy shared libraries needed by staged binaries
for b in "$RAMDIR"/*; do
    [ -f "$b" ] && [ -x "$b" ] || continue
    ldd "$b" 2>/dev/null | awk '/=>/ {print $3} !/=>/ && /^\// {print $1}' | while read -r l; do
        [ -f "$l" ] && cp -n "$l" "$RAMDIR/lib/" 2>/dev/null || true
    done || true
done

# Write the dd runner that executes entirely from RAM
cat > "$RAMDIR/run-dd.sh" << DDEOF
#!/dev/shm/kinstall/bash
export LD_LIBRARY_PATH="/dev/shm/kinstall/lib"
echo "[\$(date)] Writing raw image to ${DISK} (running from RAM)..."
/dev/shm/kinstall/curl --fail -s "${RAW_URL}" | /dev/shm/kinstall/gunzip | /dev/shm/kinstall/dd of="${DISK}" bs=16M conv=fsync 2>&1
/dev/shm/kinstall/sync
echo "[\$(date)] ============================================"
echo "[\$(date)] Write complete. Rebooting into Kairos..."
echo "[\$(date)] ============================================"
/dev/shm/kinstall/sleep 2
# Use sysrq trigger for hard reboot — reboot -f may fail when filesystem is destroyed
echo s > /proc/sysrq-trigger 2>/dev/null || true
/dev/shm/kinstall/sleep 1
echo b > /proc/sysrq-trigger
DDEOF
chmod +x "$RAMDIR/run-dd.sh"

echo "[$(date)] Starting dd from RAM..."
export LD_LIBRARY_PATH="$RAMDIR/lib"
exec "$RAMDIR/bash" "$RAMDIR/run-dd.sh"
SCRIPT
chmod +x "${IMAGE_ROOT}/usr/local/sbin/install-kairos.sh"

# Write the systemd service
cat > "${IMAGE_ROOT}/etc/systemd/system/kairos-install.service" << 'SERVICE'
[Unit]
Description=Install Kairos Raw Disk Image
After=network-online.target
Wants=network-online.target
# Wait for network to be fully up before curling the image
After=NetworkManager-wait-online.service systemd-networkd-wait-online.service

[Service]
Type=oneshot
ExecStartPre=/bin/bash -c 'echo "kairos-install: waiting 10s for network settle..."; sleep 10'
ExecStart=/usr/local/sbin/install-kairos.sh
TimeoutStartSec=1800
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
SERVICE

# Enable the service (use systemctl --root for proper enablement, plus manual symlink as fallback)
chroot "${IMAGE_ROOT}" systemctl enable kairos-install.service 2>&1 || {
    echo "[WARN] chroot systemctl enable failed, creating symlink manually"
    WANTS="${IMAGE_ROOT}/etc/systemd/system/multi-user.target.wants"
    mkdir -p "$WANTS"
    ln -sf /etc/systemd/system/kairos-install.service "${WANTS}/kairos-install.service"
}

# Verify the service and script are in place
echo "Verifying installer files in image..."
ls -la "${IMAGE_ROOT}/usr/local/sbin/install-kairos.sh"
ls -la "${IMAGE_ROOT}/etc/systemd/system/kairos-install.service"
ls -la "${IMAGE_ROOT}/etc/systemd/system/multi-user.target.wants/kairos-install.service" 2>/dev/null || echo "[WARN] symlink not found in multi-user.target.wants"
# Also check if service is enabled
chroot "${IMAGE_ROOT}" systemctl is-enabled kairos-install.service 2>&1 || true

echo "[OK] Installer script and service installed"
INSTALL_DD

    # Step 5: Patch PXE template
    echo "[5/7] Patching PXE template..."
    ${SSH_CMD} << 'TEMPLATE_PATCH' | filter_motd
for tmpl in /tftpboot/pxelinux.cfg/template /tftpboot/x86_64/bios/pxelinux.cfg/template; do
    if [ -f "$tmpl" ] && grep -q "IPAPPEND 3" "$tmpl"; then
        sed -i 's/IPAPPEND 3/IPAPPEND 2/g' "$tmpl"
        echo "[OK] Patched $tmpl: IPAPPEND 3 -> 2"
    fi
done
TEMPLATE_PATCH

    # Step 6: Configure node001 with the installer image
    echo "[6/7] Configuring node001..."
    ${SSH_CMD} << CONFIGURE_NODE | filter_motd
# Ensure the kernel referenced by the cloned image actually exists in the image filesystem.
# The cloned default-image may reference a kernel that is in the base image. We find the
# actual kernel in the installer image and update the softwareimage's kernelVersion.
IMAGE_ROOT="/cm/images/kairos-installer"
ACTUAL_KERNEL=\$(ls "\${IMAGE_ROOT}/boot/vmlinuz-"* 2>/dev/null | head -1 | sed 's|.*/vmlinuz-||')
if [[ -n "\$ACTUAL_KERNEL" ]]; then
    echo "Found kernel in installer image: \${ACTUAL_KERNEL}"
    cmsh -c "softwareimage; use kairos-installer; set kernelversion \${ACTUAL_KERNEL}; commit" 2>&1 || true
fi

# Now configure node001
cmsh << 'CMSHEOF'
device
use node001
set mac ${COMPUTE_MAC}
set installmode FULL
set softwareimage kairos-installer
set kernelparameters "console=tty0 console=ttyS0,115200n8"
commit
CMSHEOF
echo "[OK] node001: MAC=${COMPUTE_MAC}, installmode=FULL, image=kairos-installer"
CONFIGURE_NODE

    # Step 7: Generate ramdisks
    echo "[7/7] Waiting for ramdisk generation..."
    ${SSH_CMD} << 'WAIT_RAMDISK' | filter_motd
# Generate ramdisks for the installer image
cmsh -c "softwareimage; use kairos-installer; createramdisk" 2>&1 || true
sleep 15
cmsh -c "device; use node001; createramdisk" 2>&1 || true
sleep 15
echo "[OK] Ramdisks generated"
WAIT_RAMDISK

    echo ""
    echo "[OK] BCM configured to provision installer image on node001"
fi

if [[ "$NO_LAUNCH" == "true" ]]; then
    echo ""
    echo "============================================"
    echo " Deploy complete (--no-launch specified)"
    echo "============================================"
    echo " node001 will PXE boot, get installer image, then dd Kairos."
    echo " To launch: $0 --skip-upload"
    echo "============================================"
    exit 0
fi

# ---- Launch compute node VM ----
echo ""
echo "============================================"
echo " Launching Kairos Compute Node VM (Option B)"
echo "============================================"

KVM_FLAG=""
if [[ -e /dev/kvm ]]; then
    KVM_FLAG="-enable-kvm"
fi

# Kairos raw image is EFI-only — require OVMF firmware
OVMF_FW=""
for fw in /usr/share/ovmf/OVMF.fd /usr/share/qemu/OVMF.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do
    if [[ -f "$fw" ]]; then
        OVMF_FW="$fw"
        break
    fi
done
if [[ -z "$OVMF_FW" ]]; then
    echo "ERROR: OVMF EFI firmware not found. Install with: sudo apt install ovmf"
    exit 1
fi

if [[ "$RESET_COMPUTE" == "true" ]] && [[ -f "$COMPUTE_DISK" ]]; then
    echo "Removing existing compute node disk..."
    rm -f "$COMPUTE_DISK"
fi

if [[ ! -f "$COMPUTE_DISK" ]]; then
    echo "Creating ${COMPUTE_DISK_SIZE} compute node disk..."
    qemu-img create -f qcow2 "$COMPUTE_DISK" "$COMPUTE_DISK_SIZE"
fi

echo " Mode:      PXE → installer image → dd → Kairos"
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
echo "Boot sequence:"
echo "  1. PXE boot → BCM rsyncs installer image → reboot from disk"
echo "  2. Installer boots → downloads raw image → dd to disk → reboot"
echo "  3. Kairos boots with COS partitions → recovery creates STATE+PERSISTENT → reboot"
echo "  4. Kairos active partition → stylus-agent registers with Palette"
echo ""
echo "Tip: tail -f ${SERIAL_LOG}"
echo ""

> "${SERIAL_LOG}"

qemu-system-x86_64 \
    ${KVM_FLAG} \
    -m "${COMPUTE_RAM}" \
    -smp "${COMPUTE_CPUS}" \
    -cpu host \
    -name "Kairos-ComputeNode" \
    -bios "${OVMF_FW}" \
    -smbios type=1,uuid=52540000-0201-0000-0000-525400000201 \
    -drive file="${COMPUTE_DISK}",format=qcow2,if=virtio \
    -netdev socket,id=intnet,connect=:31337 \
    -device virtio-net-pci,netdev=intnet,mac=${COMPUTE_MAC} \
    -vga virtio \
    -display "${QEMU_DISPLAY:-none}" \
    -chardev socket,id=ser0,host=localhost,port=4321,server=on,wait=off,telnet=on,logfile="${SERIAL_LOG}" \
    -serial chardev:ser0 \
    -pidfile "${PROJECT_DIR}/build/.kairos-qemu.pid" \
    -daemonize \
    -boot order=cn

echo "[..] Compute node VM started"

# ---- Phase 1: Wait for BCM to provision installer image ----
echo "[..] Phase 1: Waiting for BCM to provision installer image..."
elapsed=0
timeout=900
while true; do
    if ! pgrep -f "qemu-system.*Kairos-ComputeNode" >/dev/null 2>&1; then
        echo ""
        echo "[FAIL] Compute node QEMU exited unexpectedly"
        exit 1
    fi

    NODE_STATUS=$(${SSH_CMD} "cmsh -c 'device; use node001; status' 2>/dev/null" 2>/dev/null | filter_motd || true)
    if echo "$NODE_STATUS" | grep -q "UP"; then
        echo ""
        echo "[OK] Phase 1: Node provisioned by BCM (${elapsed}s)"
        break
    fi

    elapsed=$((elapsed + 10))
    if [[ $elapsed -ge $timeout ]]; then
        echo ""
        echo "[FAIL] Node not provisioned after ${timeout}s"
        exit 1
    fi
    printf "\r  [%dm%02ds] Waiting... %s" $((elapsed / 60)) $((elapsed % 60)) "$(echo "$NODE_STATUS" | tr -d '[:space:]' | head -c 40)"
    sleep 10
done

# ---- Phase 2: Wait for dd to complete + Kairos to boot ----
echo "[..] Phase 2: Waiting for installer to dd raw image and reboot into Kairos..."
echo "     (Node will: boot installer → dd image → reboot → Kairos recovery → reboot → active)"

# The node will reboot multiple times:
# 1. After BCM provisioning (boots installer)
# 2. After dd completes (boots Kairos recovery)
# 3. After recovery creates partitions (boots Kairos active)
#
# We detect success by waiting for SSH access where /etc/kairos-release exists
# and the root filesystem is NOT the installer image.

dd_elapsed=0
dd_timeout=1800  # 30 minutes for dd + multiple reboots
kairos_booted=false

while true; do
    if ! pgrep -f "qemu-system.*Kairos-ComputeNode" >/dev/null 2>&1; then
        echo ""
        echo "[FAIL] Compute node QEMU exited unexpectedly during dd phase"
        exit 1
    fi

    # Get node IP from cmsh (reliable) or fall back to DHCP leases
    KAIROS_IP=$(${SSH_CMD} "cmsh -c 'device; use node001; get ip' 2>/dev/null" 2>/dev/null | filter_motd | grep -oP '10\.\d+\.\d+\.\d+' || true)
    if [[ -z "$KAIROS_IP" ]]; then
        KAIROS_IP=$(${SSH_CMD} "grep -oP '(?<=lease )10\\.141\\.[0-9]+\\.[0-9]+' /var/lib/dhcpd/dhcpd.leases 2>/dev/null | tail -1" 2>/dev/null | filter_motd || true)
    fi

    if [[ -n "$KAIROS_IP" ]]; then
        # Check if it's Kairos (not the installer) by looking for /etc/kairos-release
        # Try root key auth from BCM, then sshpass with kairos user
        HAS_KAIROS=$(${SSH_CMD} "ssh ${SSH_OPTS} -o ConnectTimeout=3 root@${KAIROS_IP} 'test -f /etc/kairos-release && echo yes || echo no'" 2>/dev/null | filter_motd || echo "no")
        if [[ "$HAS_KAIROS" != "yes" ]]; then
            # Install sshpass on BCM if not present (needed for kairos user password auth)
            ${SSH_CMD} "command -v sshpass >/dev/null 2>&1 || apt-get install -y -qq sshpass >/dev/null 2>&1" 2>/dev/null || true
            HAS_KAIROS=$(${SSH_CMD} "sshpass -p kairos ssh ${SSH_OPTS} -o ConnectTimeout=3 -o PreferredAuthentications=password -o PubkeyAuthentication=no kairos@${KAIROS_IP} 'test -f /etc/kairos-release && echo yes || echo no'" 2>/dev/null | filter_motd || echo "no")
        fi
        if [[ "$HAS_KAIROS" == "yes" ]]; then
            echo ""
            echo "[OK] Phase 2: Kairos booted successfully at ${KAIROS_IP} (${dd_elapsed}s)"
            kairos_booted=true
            break
        fi
    fi

    dd_elapsed=$((dd_elapsed + 15))
    if [[ $dd_elapsed -ge $dd_timeout ]]; then
        echo ""
        echo "[FAIL] Kairos not detected after ${dd_timeout}s"
        echo "       Check serial log: tail -f ${SERIAL_LOG}"
        exit 1
    fi
    # Show last serial log line for visibility
    LAST_SERIAL=$(tail -1 "${SERIAL_LOG}" 2>/dev/null | tr -d '\r' | head -c 60 || true)
    printf "\r  [%dm%02ds] Waiting for Kairos boot... (IP: %s) %s" $((dd_elapsed / 60)) $((dd_elapsed % 60)) "${KAIROS_IP:-detecting}" "${LAST_SERIAL:+| $LAST_SERIAL}"
    sleep 15
done

# ---- Phase 3: Set NOSYNC and validate ----
if [[ "$kairos_booted" == "true" ]]; then
    echo "[..] Phase 3: Setting installmode NOSYNC to prevent re-provisioning..."
    ${SSH_CMD} "echo -e 'device\nuse node001\nset installmode NOSYNC\ncommit' | cmsh" 2>/dev/null | filter_motd || true
    echo "[OK] installmode set to NOSYNC"

    # Helper: SSH to Kairos node via BCM head node (try root key auth, then kairos password auth)
    kairos_ssh() {
        local result
        result=$(${SSH_CMD} "ssh ${SSH_OPTS} -o ConnectTimeout=5 root@${KAIROS_IP} '$1'" 2>/dev/null | filter_motd) && echo "$result" && return 0
        result=$(${SSH_CMD} "sshpass -p kairos ssh ${SSH_OPTS} -o ConnectTimeout=5 -o PreferredAuthentications=password -o PubkeyAuthentication=no kairos@${KAIROS_IP} 'sudo $1'" 2>/dev/null | filter_motd) && echo "$result" && return 0
        return 1
    }

    # Post-provisioning validation
    echo "[..] Validating services on Kairos node..."

    # Check stylus-agent service
    if kairos_ssh "systemctl is-active stylus-agent" 2>/dev/null | grep -q "active"; then
        echo "[OK] stylus-agent is active"
    else
        echo "[WARN] stylus-agent is not active (may still be starting)"
    fi

    # Check for COS partitions (single blkid call, grep for labels)
    BLKID_OUT=$(kairos_ssh "blkid" 2>/dev/null || true)
    for label in COS_OEM COS_RECOVERY COS_STATE COS_PERSISTENT; do
        if echo "$BLKID_OUT" | grep -q "LABEL=\"${label}\""; then
            echo "[OK] ${label} partition present"
        else
            echo "[WARN] ${label} partition not detected"
        fi
    done

    # Check root is read-only (immutable)
    ROOT_MOUNT=$(kairos_ssh "mount | grep ' / '" 2>/dev/null || true)
    if echo "$ROOT_MOUNT" | grep -q "\bro\b"; then
        echo "[OK] Root filesystem is read-only (immutable)"
    else
        echo "[WARN] Root filesystem is NOT read-only"
    fi

    # Wait for Palette registration
    echo "[..] Waiting for Palette registration..."
    reg_elapsed=0
    reg_timeout=300
    while true; do
        REG_LOGS=$(kairos_ssh "journalctl -u stylus-agent --no-pager -n 50" 2>/dev/null || true)
        if echo "$REG_LOGS" | grep -q "registering edge host device with hubble"; then
            echo ""
            echo "[OK] stylus-agent registered with Palette"
            break
        fi
        reg_elapsed=$((reg_elapsed + 10))
        if [[ $reg_elapsed -ge $reg_timeout ]]; then
            echo ""
            echo "[WARN] Palette registration not detected after ${reg_timeout}s"
            break
        fi
        printf "\r  [%dm%02ds] Waiting for registration..." $((reg_elapsed / 60)) $((reg_elapsed % 60))
        sleep 10
    done

    total_elapsed=$((elapsed + dd_elapsed + reg_elapsed))
    echo ""
    echo "[OK] Kairos compute node deployed with COS partitions (total: ${total_elapsed}s)"
fi
