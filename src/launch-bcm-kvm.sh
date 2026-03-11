#!/bin/bash
# launch-bcm-kvm.sh
#
# Launches BCM 11.0 in a KVM virtual machine.
#
# Two modes:
#   Interactive:  ./launch-bcm-kvm.sh
#   Auto-install: ./launch-bcm-kvm.sh --auto
#                 (requires running prepare-bcm-autoinstall.sh first)
#
# Two NICs are configured:
#   eth0 - Internal cluster network (isolated)
#   eth1 - External network (QEMU user-mode NAT with port forwarding)

set -euo pipefail

BCM_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ISO="${ISO_PATH:-${BCM_DIR}/dist/bcm-11.0-ubuntu2404.iso}"
DISK="${BCM_DIR}/build/bcm-disk.qcow2"
DISK_SIZE="100G"
RAM="8192"
CPUS="4"
VM_NAME="BCM-11.0"

# Display: use gtk if DISPLAY or WAYLAND_DISPLAY is set, otherwise headless
if [[ -z "${QEMU_DISPLAY:-}" ]]; then
    if [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
        QEMU_DISPLAY="gtk"
    else
        QEMU_DISPLAY="none"
    fi
fi

# Port forwarding (host -> VM)
SSH_PORT=10022
HTTPS_PORT=10443

# Auto-install artifacts (produced by prepare-bcm-autoinstall.sh)
AUTO_KERNEL="${BCM_DIR}/build/.bcm-kernel"
AUTO_ROOTFS="${BCM_DIR}/build/.bcm-rootfs-auto.cgz"
AUTO_INITIMG="${BCM_DIR}/build/.bcm-init.img"

AUTO_INSTALL=false
DISK_BOOT=false
TEXT_MODE=false
RESET=false

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --auto              Fully automated install (run prepare-bcm-autoinstall.sh first)
  --disk              Boot from existing disk image (skip install)
  --text              Use text installer in interactive mode
  --ram MB            RAM in MB (default: 8192)
  --cpus N            Number of CPUs (default: 4)
  --disk-size SIZE    Disk size (default: 100G)
  --ssh-port PORT     Host SSH port (default: 10022)
  --https-port PORT   Host HTTPS port (default: 10443)
  --reset             Delete existing disk image and start fresh
  -h, --help          Show this help

Examples:
  $0                    # Interactive graphical install
  $0 --auto             # Fully automated (hands-free) install
  $0 --auto --reset     # Fresh automated install
  $0 --text             # Interactive text install
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto)        AUTO_INSTALL=true; shift ;;
        --disk)        DISK_BOOT=true; shift ;;
        --text)        TEXT_MODE=true; shift ;;
        --ram)         RAM="$2"; shift 2 ;;
        --cpus)        CPUS="$2"; shift 2 ;;
        --disk-size)   DISK_SIZE="$2"; shift 2 ;;
        --ssh-port)    SSH_PORT="$2"; shift 2 ;;
        --https-port)  HTTPS_PORT="$2"; shift 2 ;;
        --reset)       RESET=true; shift ;;
        -h|--help)     usage ;;
        *)             echo "Unknown option: $1"; usage ;;
    esac
done

# ---- Preflight ----
if [[ "$DISK_BOOT" == "true" ]]; then
    if [[ ! -f "$DISK" ]]; then
        echo "ERROR: Disk image not found at $DISK. Run: make bcm-run"
        exit 1
    fi
elif [[ ! -f "$ISO" ]]; then
    echo "ERROR: ISO not found at $ISO"
    exit 1
fi

if ! command -v qemu-system-x86_64 &>/dev/null; then
    echo "ERROR: qemu-system-x86_64 not found"
    exit 1
fi

if [[ "$AUTO_INSTALL" == "true" ]]; then
    for f in "$AUTO_KERNEL" "$AUTO_ROOTFS" "$AUTO_INITIMG"; do
        if [[ ! -f "$f" ]]; then
            echo "ERROR: Auto-install artifact not found: $f"
            echo "Run ./prepare-bcm-autoinstall.sh first."
            exit 1
        fi
    done
fi

KVM_FLAG=""
if [[ -e /dev/kvm ]]; then
    KVM_FLAG="-enable-kvm"
else
    echo "WARNING: /dev/kvm not available, VM will be slow."
fi

# ---- Disk ----
if [[ "$RESET" == "true" ]] && [[ -f "$DISK" ]]; then
    echo "Removing existing disk image..."
    rm -f "$DISK"
fi

if [[ ! -f "$DISK" ]]; then
    echo "Creating ${DISK_SIZE} disk image..."
    qemu-img create -f qcow2 "$DISK" "$DISK_SIZE"
fi

echo ""
echo "========================================"
echo " BCM 11.0 KVM"
echo "========================================"
echo " RAM:       ${RAM} MB"
echo " CPUs:      ${CPUS}"
echo " Disk:      ${DISK}"
if [[ "$DISK_BOOT" == "true" ]]; then
echo " Mode:      Disk boot (existing install)"
elif [[ "$AUTO_INSTALL" == "true" ]]; then
echo " Mode:      Automated (hands-free)"
else
echo " Mode:      $([ "$TEXT_MODE" == "true" ] && echo "Text" || echo "Graphical")"
fi
mkdir -p "${BCM_DIR}/logs"
SERIAL_LOG="${BCM_DIR}/logs/bcm-serial.log"
echo " SSH:       localhost:${SSH_PORT} -> vm:22"
echo " HTTPS:     localhost:${HTTPS_PORT} -> vm:443"
echo " Serial:    ${SERIAL_LOG}"
echo "========================================"
echo ""
echo "Tip: tail -f ${SERIAL_LOG}"
echo ""

# Common QEMU args (NIC order matters: first = eth0 internal, second = eth1 external)
QEMU_COMMON=(
    ${KVM_FLAG}
    -m "${RAM}"
    -smp "${CPUS}"
    -cpu host
    -name "${VM_NAME}"
    -drive file="${DISK}",format=qcow2,if=virtio
    -netdev socket,id=intnet,listen=:31337
    -device virtio-net-pci,netdev=intnet,mac=52:54:00:00:01:01
    -netdev user,id=extnet,hostfwd=tcp::${SSH_PORT}-:22,hostfwd=tcp::${HTTPS_PORT}-:443
    -device virtio-net-pci,netdev=extnet,mac=52:54:00:00:01:02
    -vga virtio
    -display "${QEMU_DISPLAY:-none}"
    -chardev stdio,id=char0,mux=on,logfile="${SERIAL_LOG}"
    -serial chardev:char0
    -mon chardev=char0
)

if [[ "$DISK_BOOT" == "true" ]]; then
    # ---- Boot from existing disk ----
    exec qemu-system-x86_64 \
        "${QEMU_COMMON[@]}" \
        -boot c

elif [[ "$AUTO_INSTALL" == "true" ]]; then
    # ---- Phase 1: Run installer ----
    echo "[..] Phase 1: Running automated installer..."
    > "${SERIAL_LOG}"  # Clear log

    qemu-system-x86_64 \
        "${QEMU_COMMON[@]}" \
        -cdrom "${ISO}" \
        -boot d \
        -drive file="${AUTO_INITIMG}",format=raw,if=virtio \
        -kernel "${AUTO_KERNEL}" \
        -initrd "${AUTO_ROOTFS}" \
        -append "dvdinstall nokeymap root=/dev/ram0 rw vga=normal bcmblacklist=nouveau systemd.unit=multi-user.target console=tty0 console=ttyS0,115200 net.ifnames=0 biosdevname=0" \
        &
    QEMU_PID=$!

    # Monitor serial log for install completion
    while true; do
        if grep -q "INSTALLATION COMPLETE" "${SERIAL_LOG}" 2>/dev/null; then
            echo ""
            echo "[OK] Installation complete — stopping installer VM..."
            kill "${QEMU_PID}" 2>/dev/null
            wait "${QEMU_PID}" 2>/dev/null || true
            break
        fi
        if grep -q "INSTALLATION FAILED" "${SERIAL_LOG}" 2>/dev/null; then
            echo ""
            echo "[FAIL] Installation failed. Check: tail ${SERIAL_LOG}"
            kill "${QEMU_PID}" 2>/dev/null
            wait "${QEMU_PID}" 2>/dev/null || true
            exit 1
        fi
        if ! kill -0 "${QEMU_PID}" 2>/dev/null; then
            echo ""
            echo "[FAIL] QEMU exited unexpectedly. Check: tail ${SERIAL_LOG}"
            exit 1
        fi
        sleep 5
    done

    sleep 2

    # ---- Phase 2: Boot from disk ----
    echo ""
    echo "========================================"
    echo " Phase 2: Booting from installed disk"
    echo "========================================"
    echo ""
    > "${SERIAL_LOG}"  # Clear log for disk boot

    exec qemu-system-x86_64 \
        "${QEMU_COMMON[@]}" \
        -boot c

else
    # ---- Interactive install from ISO ----
    exec qemu-system-x86_64 \
        "${QEMU_COMMON[@]}" \
        -cdrom "${ISO}" \
        -boot d
fi
