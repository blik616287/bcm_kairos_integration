#!/bin/bash
# test-kairos-pxe.sh
#
# Option C: Deploys Kairos via BCM PXE boot with Kairos's own installer.
#
# Instead of BCM rsync-provisioning (Option A), this script:
#   1. Uploads boot artifacts (kernel, initrd, squashfs, cloud-config) to BCM
#   2. Starts an HTTP server on BCM to serve them
#   3. Injects a custom PXE label into BCM's pxelinux config
#   4. Configures node001 to PXE boot with the kairos-install label
#   5. Launches compute VM → Kairos installer partitions disk → reboots into installed system
#   6. Cleans up PXE label and HTTP server after install
#
# Kairos handles its own partitioning: COS_OEM, COS_STATE, COS_RECOVERY, COS_PERSISTENT.
# Result: immutable root, A/B upgrades, proper Kairos partition layout.
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

# HTTP server port for serving boot artifacts
HTTP_PORT=8080

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

Option C: Deploys Kairos via BCM PXE with Kairos's native installer.

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
  $0                   # Deploy + launch (Kairos installer via PXE)
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

# Filter BCM's MOTD noise from SSH command output.
# cmfirstboot injects messages into .bashrc that pollute every SSH stdout.
filter_motd() {
    grep -vE "cmfirstboot is still in progress|^$" || true
}

# ---- Preflight ----
if [[ "$SKIP_UPLOAD" != "true" ]]; then
    for artifact in vmlinuz initrd rootfs.squashfs install-config.yaml; do
        if [[ ! -f "${PXE_DIR}/${artifact}" ]]; then
            echo "ERROR: ${artifact} not found at ${PXE_DIR}/${artifact}"
            echo "Run ./extract-kairos-pxe.sh first."
            exit 1
        fi
    done

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
    CMFB_STATUS=$(${SSH_CMD} "systemctl is-active cmfirstboot" 2>/dev/null | filter_motd || echo "unknown")
    if [[ "$CMFB_STATUS" != "activating" && "$CMFB_STATUS" != "active" ]]; then
        break
    fi
    elapsed=$((elapsed + 10))
    printf "\r  [%dm%02ds] cmfirstboot still running..." $((elapsed / 60)) $((elapsed % 60))
    sleep 10
done
echo ""

# Verify cmfirstboot completed successfully (not failed)
CMFB_RESULT=$(${SSH_CMD} "systemctl show cmfirstboot --property=Result --value" 2>/dev/null | filter_motd || echo "unknown")
if [[ "$CMFB_RESULT" != "success" ]]; then
    echo "[WARN] cmfirstboot result: ${CMFB_RESULT}"
fi

# Wait for .bashrc MOTD noise to clear — cmfirstboot injects a status check
# into /root/.bashrc that poisons scp and non-interactive SSH sessions.
# Even after cmfirstboot finishes, there can be a brief race.
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

# Wait for key BCM services to be ready
# BCM's main daemon is "cmd" (Cluster Management Daemon). Also check cmsh is responsive.
echo "[..] Waiting for BCM services (cmd + cmsh)..."
elapsed=0
while true; do
    CMD_STATUS=$(${SSH_CMD} "systemctl is-active cmd" 2>/dev/null | filter_motd || echo "inactive")
    # Verify cmsh can actually talk to the daemon (not just that systemd says active)
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

# ---- Deploy Kairos boot artifacts for PXE ----
if [[ "$SKIP_UPLOAD" != "true" ]]; then
    echo ""
    echo "============================================"
    echo " Deploying Kairos Boot Artifacts (Option C)"
    echo "============================================"

    # Check if artifacts already uploaded and current
    NEEDS_UPLOAD=true
    EXISTING=$(${SSH_CMD} "ls /cm/shared/kairos/rootfs.squashfs 2>/dev/null && echo yes || echo no" | filter_motd)
    if [[ "$EXISTING" == "yes" ]]; then
        echo "[..] Kairos artifacts already on BCM, checking if current..."
        LOCAL_SIZE=$(stat -c%s "${PXE_DIR}/rootfs.squashfs")
        REMOTE_SIZE=$(${SSH_CMD} "stat -c%s /cm/shared/kairos/rootfs.squashfs 2>/dev/null || echo 0" | filter_motd)
        if [[ "$LOCAL_SIZE" == "$REMOTE_SIZE" ]]; then
            echo "[OK] Artifacts are up to date, skipping upload"
            NEEDS_UPLOAD=false
        else
            echo "[..] Squashfs changed, re-uploading..."
        fi
    fi

    if [[ "$NEEDS_UPLOAD" == "true" ]]; then
        echo "[1/4] Uploading boot artifacts to BCM..."
        ${SSH_CMD} "mkdir -p /cm/shared/kairos"
        for artifact in vmlinuz initrd rootfs.squashfs install-config.yaml; do
            echo "  Uploading ${artifact}..."
            ${SCP_CMD} "${PXE_DIR}/${artifact}" root@localhost:/cm/shared/kairos/${artifact}
        done
        echo "[OK] All artifacts uploaded to /cm/shared/kairos/"
    else
        echo "[1/4] Upload: skipped (artifacts up to date)"
    fi

    echo "[2/4] Starting HTTP server on BCM (${HEAD_NODE_IP}:${HTTP_PORT})..."
    ${SSH_CMD} << HTTPSERVER | filter_motd
# Kill any existing server on this port
pkill -f "python3.*http.server.*${HTTP_PORT}" 2>/dev/null || true
sleep 1

# Start HTTP server serving /cm/shared/kairos/ on internal interface
cd /cm/shared/kairos
nohup python3 -m http.server ${HTTP_PORT} --bind ${HEAD_NODE_IP} > /var/log/kairos-http.log 2>&1 &
echo \$! > /var/run/kairos-http.pid

# Verify it's serving
sleep 2
if curl -sf http://${HEAD_NODE_IP}:${HTTP_PORT}/vmlinuz -o /dev/null; then
    echo "[OK] HTTP server running on ${HEAD_NODE_IP}:${HTTP_PORT}"
else
    echo "[FAIL] HTTP server not responding"
    cat /var/log/kairos-http.log 2>/dev/null || true
    exit 1
fi
HTTPSERVER

    echo "[3/4] Injecting PXE label into BCM pxelinux config..."
    ${SSH_CMD} << PXELABEL | filter_motd
for tmpl in /tftpboot/pxelinux.cfg/template /tftpboot/x86_64/bios/pxelinux.cfg/template; do
    if [ -f "\$tmpl" ]; then
        # Remove existing kairos-install label if present (idempotent)
        # Delete from LABEL kairos-install to the next blank line or LABEL
        sed -i '/^LABEL kairos-install/,/^\$/d' "\$tmpl"

        # Append the Kairos installer PXE entry
        cat >> "\$tmpl" << 'PXEENTRY'

LABEL kairos-install
  KERNEL http://${HEAD_NODE_IP}:${HTTP_PORT}/vmlinuz
  INITRD http://${HEAD_NODE_IP}:${HTTP_PORT}/initrd
  APPEND ip=dhcp rd.neednet=1 netboot install-mode config_url=http://${HEAD_NODE_IP}:${HTTP_PORT}/install-config.yaml live-img-url=http://${HEAD_NODE_IP}:${HTTP_PORT}/rootfs.squashfs console=tty0 console=ttyS0,115200
PXEENTRY
        echo "[OK] Injected kairos-install label into \$tmpl"
    fi
done
PXELABEL

    echo "[4/4] Configuring node001 with PXE label..."
    ${SSH_CMD} "echo -e 'device\nuse node001\nset mac ${COMPUTE_MAC}\nset pxelabel kairos-install\ncommit' | cmsh && echo '[OK] node001: MAC=${COMPUTE_MAC}, pxelabel=kairos-install'" | filter_motd

    echo ""
    echo "[OK] BCM configured for Kairos PXE install on node001"
fi

if [[ "$NO_LAUNCH" == "true" ]]; then
    echo ""
    echo "============================================"
    echo " Deploy complete (--no-launch specified)"
    echo "============================================"
    echo " node001 will PXE boot into the Kairos installer."
    echo " Kairos will partition the disk and reboot."
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

echo " Mode:      Kairos PXE installer → COS partitions → disk boot"
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
echo "First boot: empty disk → PXE → Kairos installer → COS partitions → reboot → Palette registration"
echo ""
echo "Tip: tail -f ${SERIAL_LOG}"
echo ""

> "${SERIAL_LOG}"

# Boot order: disk first, network fallback
# First boot: disk is empty → falls through to PXE → Kairos installer runs
# After install: boots from disk → Kairos with COS partitions
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

echo "[..] Compute node VM started"

# ---- Phase 1: Wait for Kairos installer to complete ----
echo "[..] Waiting for Kairos installer to complete..."
elapsed=0
timeout=900
while true; do
    # Check if QEMU is still running
    if ! pgrep -f "qemu-system.*Kairos-ComputeNode" >/dev/null 2>&1; then
        echo ""
        echo "[FAIL] Compute node QEMU exited unexpectedly"
        exit 1
    fi

    # Check for installer completion markers in serial log
    if grep -qiE "installation completed|reboot: restarting system|starting reboot" "${SERIAL_LOG}" 2>/dev/null; then
        echo ""
        echo "[OK] Kairos installer completed, node is rebooting into installed system..."
        break
    fi

    # Check for failure
    if grep -qiE "installation failed|panic|fatal error" "${SERIAL_LOG}" 2>/dev/null; then
        echo ""
        echo "[FAIL] Kairos installer failed. Check: tail ${SERIAL_LOG}"
        exit 1
    fi

    elapsed=$((elapsed + 10))
    if [[ $elapsed -ge $timeout ]]; then
        echo ""
        echo "[FAIL] Installer timeout (${timeout}s). Check: tail ${SERIAL_LOG}"
        exit 1
    fi
    printf "\r  [%dm%02ds] Installing..." $((elapsed / 60)) $((elapsed % 60))
    sleep 10
done

install_elapsed=$elapsed

# ---- Phase 2: Wait for installed system to boot and SSH to be reachable ----
echo "[..] Waiting for Kairos to boot from disk..."
elapsed=0
timeout=600
KAIROS_IP=""
while true; do
    # Check if QEMU is still running
    if ! pgrep -f "qemu-system.*Kairos-ComputeNode" >/dev/null 2>&1; then
        echo ""
        echo "[FAIL] Compute node QEMU exited unexpectedly"
        exit 1
    fi

    # Detect compute node IP from ARP table on BCM head node
    if [[ -z "$KAIROS_IP" ]]; then
        KAIROS_IP=$(${SSH_CMD} "arp -an 2>/dev/null | grep '${COMPUTE_MAC}' | grep -oP '\\d+\\.\\d+\\.\\d+\\.\\d+'" 2>/dev/null | filter_motd || true)
    fi

    # Try SSH to compute node through BCM head node
    if [[ -n "$KAIROS_IP" ]]; then
        if ${SSH_CMD} "sshpass -p kairos ssh ${SSH_OPTS} -o ConnectTimeout=3 kairos@${KAIROS_IP} 'echo ok'" >/dev/null 2>&1; then
            echo ""
            echo "[OK] Kairos compute node is up and SSH-ready at ${KAIROS_IP} (${elapsed}s)"
            break
        fi
    fi

    elapsed=$((elapsed + 10))
    if [[ $elapsed -ge $timeout ]]; then
        echo ""
        echo "[FAIL] Compute node not SSH-ready after ${timeout}s"
        echo "  IP detected: ${KAIROS_IP:-none}"
        exit 1
    fi
    printf "\r  [%dm%02ds] Waiting for SSH... (IP: %s)" $((elapsed / 60)) $((elapsed % 60)) "${KAIROS_IP:-detecting}"
    sleep 10
done

boot_elapsed=$elapsed

# ---- Post-install cleanup ----
echo "[..] Cleaning up PXE label and HTTP server..."

# Clear pxelabel and set installmode SKIP so BCM doesn't re-provision on reboot
${SSH_CMD} "echo -e 'device\nuse node001\nclear pxelabel\nset installmode SKIP\ncommit' | cmsh && echo '[OK] Cleared pxelabel, set installmode=SKIP'" | filter_motd

# Stop HTTP server — no longer needed after install
${SSH_CMD} "pkill -f 'python3.*http.server.*${HTTP_PORT}' 2>/dev/null; rm -f /var/run/kairos-http.pid; echo '[OK] HTTP server stopped'" | filter_motd

# ---- Wait for Palette registration ----
echo "[..] Waiting for Palette registration..."
reg_elapsed=0
reg_timeout=300
while true; do
    REG_LOGS=$(${SSH_CMD} "sshpass -p kairos ssh ${SSH_OPTS} kairos@${KAIROS_IP} 'sudo journalctl -u stylus-agent --no-pager'" 2>/dev/null | filter_motd || true)
    if echo "$REG_LOGS" | grep -q "registering edge host device with hubble"; then
        echo ""
        echo "[OK] stylus-agent registered with Palette"
        break
    fi
    reg_elapsed=$((reg_elapsed + 10))
    if [[ $reg_elapsed -ge $reg_timeout ]]; then
        echo ""
        echo "[WARN] Palette registration not detected after ${reg_timeout}s"
        echo "  stylus-agent may still be starting. Check manually:"
        echo "  ssh kairos@${KAIROS_IP} 'sudo journalctl -u stylus-agent -f'"
        break
    fi
    printf "\r  [%dm%02ds] Waiting for registration..." $((reg_elapsed / 60)) $((reg_elapsed % 60))
    sleep 10
done

total_elapsed=$((install_elapsed + boot_elapsed + reg_elapsed))
echo ""
echo "============================================"
echo " Kairos Compute Node Ready (Option C)"
echo "============================================"
echo " Install time:  ${install_elapsed}s"
echo " Boot time:     ${boot_elapsed}s"
echo " Registration:  ${reg_elapsed}s"
echo " Total:         ${total_elapsed}s"
echo ""
echo " IP:    ${KAIROS_IP}"
echo " SSH:   sshpass -p kairos ssh kairos@${KAIROS_IP} (via BCM)"
echo " COS partitions: run 'lsblk -o NAME,LABEL' on compute node"
echo "============================================"
