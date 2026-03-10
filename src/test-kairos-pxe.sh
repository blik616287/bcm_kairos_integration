#!/bin/bash
# test-kairos-pxe.sh
#
# Deploys Kairos PXE artifacts to the running BCM head node and
# launches a compute node QEMU VM that boots the Kairos image.
#
# Prerequisites:
#   1. BCM head node running in KVM (launch-bcm-kvm.sh --disk or --auto)
#   2. Kairos PXE artifacts extracted (extract-kairos-pxe.sh)
#
# Two boot modes:
#   --direct   QEMU direct kernel boot (bypasses iPXE, fastest test)
#   (default)  Full PXE boot from BCM DHCP/TFTP
#
# Usage:
#   ./test-kairos-pxe.sh [OPTIONS]
#
# Examples:
#   ./test-kairos-pxe.sh --direct       # Quick test: direct kernel boot
#   ./test-kairos-pxe.sh                 # Full PXE boot chain
#   ./test-kairos-pxe.sh --no-launch     # Upload only, don't start VM

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PXE_DIR="${PROJECT_DIR}/build/pxe"

# BCM head node connection
SSH_PORT=10022
BCM_PASSWORD="${BCM_PASSWORD:?ERROR: BCM_PASSWORD not set. Set in env.json or export BCM_PASSWORD}"

# Head node internal IP
HEAD_NODE_IP="10.141.255.254"
HTTP_PORT="8888"

# Compute node VM settings
COMPUTE_RAM="4096"
COMPUTE_CPUS="2"
COMPUTE_DISK_SIZE="80G"
COMPUTE_DISK="${PROJECT_DIR}/build/compute-node-disk.qcow2"
COMPUTE_MAC="52:54:00:00:02:01"

# Mode
DIRECT_BOOT=false
NO_LAUNCH=false
SKIP_UPLOAD=false
RESET_COMPUTE=false

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Deploys Kairos PXE artifacts to BCM head node and launches a compute node VM.

Options:
  --direct             Direct kernel boot (bypass iPXE, fastest test)
  --no-launch          Upload and configure only, don't launch compute VM
  --skip-upload        Skip upload, only launch compute VM
  --pxe-dir DIR        PXE artifacts directory (default: build/pxe/)
  --ssh-port PORT      BCM head node SSH port (default: 10022)
  --password PASS      BCM root password (default: Br1ghtClust3r)
  --head-ip IP         Head node internal IP (default: 10.141.255.254)
  --http-port PORT     HTTP server port (default: 8888)
  --compute-ram MB     Compute node RAM (default: 4096)
  --compute-cpus N     Compute node CPUs (default: 2)
  --compute-disk-size  Compute node disk size (default: 40G)
  --reset-compute      Delete existing compute node disk
  -h, --help           Show this help

Examples:
  $0 --direct          # Quick test with direct kernel boot
  $0                   # Full PXE boot from BCM
  $0 --no-launch       # Upload artifacts only
  $0 --skip-upload     # Launch VM only (artifacts already uploaded)
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --direct)           DIRECT_BOOT=true; shift ;;
        --no-launch)        NO_LAUNCH=true; shift ;;
        --skip-upload)      SKIP_UPLOAD=true; shift ;;
        --pxe-dir)          PXE_DIR="$2"; shift 2 ;;
        --ssh-port)         SSH_PORT="$2"; shift 2 ;;
        --password)         BCM_PASSWORD="$2"; shift 2 ;;
        --head-ip)          HEAD_NODE_IP="$2"; shift 2 ;;
        --http-port)        HTTP_PORT="$2"; shift 2 ;;
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
    for f in vmlinuz initrd-combined rootfs.squashfs; do
        if [[ ! -f "${PXE_DIR}/${f}" ]]; then
            echo "ERROR: PXE artifact not found: ${PXE_DIR}/${f}"
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

# ---- Phase 1: Upload artifacts ----
if [[ "$SKIP_UPLOAD" != "true" ]]; then
    echo ""
    echo "============================================"
    echo " Uploading Kairos PXE Artifacts"
    echo "============================================"

    ${SSH_CMD} "mkdir -p /tftpboot/kairos"

    echo "[1/5] Uploading vmlinuz..."
    ${SCP_CMD} "${PXE_DIR}/vmlinuz" root@localhost:/tftpboot/kairos/

    echo "[2/5] Uploading initrd (combined with user-data overlay)..."
    ${SCP_CMD} "${PXE_DIR}/initrd-combined" "root@localhost:/tftpboot/kairos/initrd"

    echo "[3/5] Uploading rootfs.squashfs (this may take a while)..."
    ${SCP_CMD} "${PXE_DIR}/rootfs.squashfs" root@localhost:/tftpboot/kairos/

    echo "[4/5] Uploading user-data cloud-config..."
    ${SCP_CMD} "${PXE_DIR}/user-data.yaml" root@localhost:/tftpboot/kairos/

    echo "[5/5] Uploading iPXE script..."
    ${SCP_CMD} "${PXE_DIR}/kairos-boot.ipxe" root@localhost:/tftpboot/kairos/

    echo "[OK] All artifacts uploaded to /tftpboot/kairos/"

    # ---- Start HTTP server on head node ----
    echo ""
    echo "[..] Starting HTTP server on head node..."

    ${SSH_CMD} << REMOTE_SETUP
# Kill any existing kairos HTTP server
pkill -f "python3 -m http.server ${HTTP_PORT}" 2>/dev/null || true
sleep 1

# Start HTTP server to serve PXE artifacts
cd /tftpboot
nohup python3 -m http.server ${HTTP_PORT} --bind ${HEAD_NODE_IP} > /var/log/kairos-http.log 2>&1 &
echo "HTTP server PID: \$!"

# Verify it started
sleep 1
if curl -s -o /dev/null "http://${HEAD_NODE_IP}:${HTTP_PORT}/kairos/vmlinuz"; then
    echo "[OK] HTTP server responding on ${HEAD_NODE_IP}:${HTTP_PORT}"
else
    echo "[WARN] HTTP server may not be ready yet"
fi
REMOTE_SETUP

    echo "[OK] HTTP server started on ${HEAD_NODE_IP}:${HTTP_PORT}"
fi

if [[ "$NO_LAUNCH" == "true" ]]; then
    echo ""
    echo "============================================"
    echo " Upload complete (--no-launch specified)"
    echo "============================================"
    echo " Artifacts served at: http://${HEAD_NODE_IP}:${HTTP_PORT}/kairos/"
    echo " To launch compute node: $0 --skip-upload [--direct]"
    echo "============================================"
    exit 0
fi

# ---- Phase 2: Launch compute node VM ----
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

if [[ "$DIRECT_BOOT" == "true" ]]; then
    echo " Mode:      Direct kernel boot (bypasses PXE)"
else
    echo " Mode:      PXE boot from BCM head node"
fi
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
echo "Tip: tail -f ${SERIAL_LOG}"
echo ""

if [[ "$DIRECT_BOOT" == "true" ]]; then
    # Direct kernel boot: load Kairos kernel/initrd directly in QEMU,
    # fetch squashfs via HTTP from head node at boot time
    exec qemu-system-x86_64 \
        ${KVM_FLAG} \
        -m "${COMPUTE_RAM}" \
        -smp "${COMPUTE_CPUS}" \
        -cpu host \
        -name "Kairos-ComputeNode" \
        -drive file="${COMPUTE_DISK}",format=qcow2,if=virtio \
        -netdev socket,id=intnet,connect=:31337 \
        -device virtio-net-pci,netdev=intnet,mac=${COMPUTE_MAC} \
        -kernel "${PXE_DIR}/vmlinuz" \
        -initrd "${PXE_DIR}/initrd-combined" \
        -append "rd.neednet=1 ip=dhcp rd.cos.disable root=live:http://${HEAD_NODE_IP}:${HTTP_PORT}/kairos/rootfs.squashfs rd.live.dir=/ rd.live.squashimg=rootfs.squashfs net.ifnames=1 console=tty1 console=ttyS0 rd.live.overlay.overlayfs selinux=0 rd.immucore.sysrootwait=600 config_url=http://${HEAD_NODE_IP}:${HTTP_PORT}/kairos/user-data.yaml" \
        -vga virtio \
        -display gtk \
        -chardev stdio,id=char0,mux=on,logfile="${SERIAL_LOG}" \
        -serial chardev:char0 \
        -mon chardev=char0
else
    # Full PXE boot: compute node boots from BCM DHCP/TFTP
    exec qemu-system-x86_64 \
        ${KVM_FLAG} \
        -m "${COMPUTE_RAM}" \
        -smp "${COMPUTE_CPUS}" \
        -cpu host \
        -name "Kairos-ComputeNode" \
        -drive file="${COMPUTE_DISK}",format=qcow2,if=virtio \
        -netdev socket,id=intnet,connect=:31337 \
        -device virtio-net-pci,netdev=intnet,mac=${COMPUTE_MAC} \
        -boot n \
        -vga virtio \
        -display gtk \
        -chardev stdio,id=char0,mux=on,logfile="${SERIAL_LOG}" \
        -serial chardev:char0 \
        -mon chardev=char0
fi
