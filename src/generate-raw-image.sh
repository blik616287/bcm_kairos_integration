#!/bin/bash
# generate-raw-image.sh
#
# Generates a fully-installed Kairos raw disk image by running kairos-agent
# install inside a QEMU VM. The resulting disk boots directly into active mode
# with all 5 COS partitions pre-created (no recovery reset needed).
#
# Requires: the CanvOS ISO from build-canvos.sh
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

# Palette registration (from env vars or env.json via Makefile)
PALETTE_ENDPOINT="${PALETTE_ENDPOINT:-api.spectrocloud.com}"
PALETTE_TOKEN="${PALETTE_TOKEN:?ERROR: PALETTE_TOKEN not set. Set in env.json or export PALETTE_TOKEN}"
PALETTE_PROJECT_UID="${PALETTE_PROJECT_UID:?ERROR: PALETTE_PROJECT_UID not set. Set in env.json or export PALETTE_PROJECT_UID}"

# BCM integration
BCM_PASSWORD="${BCM_PASSWORD:-}"
HEAD_NODE_IP="${HEAD_NODE_IP:-10.141.255.254}"
BCM_SSH_KEY="${BCM_SSH_KEY:-}"  # Path to private key for SSH to BCM head node

# Disk config
DISK_SIZE="${DISK_SIZE:-81920}"  # MB

# ISO from kairos-build
ISO_NAME="${ISO_NAME:-palette-edge-installer}"
KAIROS_ISO="${BUILD_DIR}/${ISO_NAME}.iso"

CLEAN=false

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Generates a Kairos raw disk image by running kairos-agent install in QEMU.
The resulting disk boots directly into active mode (no recovery reset needed).

Options:
  --disk-size MB       Raw disk size in MB (default: 81920)
  --clean              Remove existing artifacts first
  -h, --help           Show this help

Outputs:
  build/kairos-disk.raw          Raw disk image (all 5 COS partitions)
  build/kairos-disk.raw.sha256   Checksum
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --disk-size)   DISK_SIZE="$2"; shift 2 ;;
        --clean)       CLEAN=true; shift ;;
        -h|--help)     usage ;;
        *)             echo "Unknown option: $1"; usage ;;
    esac
done

# ---- Preflight ----
if [[ ! -f "$KAIROS_ISO" ]]; then
    echo "ERROR: Kairos ISO not found at $KAIROS_ISO"
    echo "Build it first: make kairos-build"
    exit 1
fi

if ! command -v qemu-system-x86_64 &>/dev/null; then
    echo "ERROR: qemu-system-x86_64 not found."
    exit 1
fi

# ---- Clean ----
if [[ "$CLEAN" == "true" ]]; then
    echo "Cleaning existing artifacts..."
    rm -f "${BUILD_DIR}/kairos-disk.raw" "${BUILD_DIR}/kairos-disk.raw.sha256"
    rm -f "${BUILD_DIR}/cloud-init.iso"
fi

echo "============================================"
echo " Generating Kairos Raw Disk Image (QEMU)"
echo "============================================"
echo " ISO:       ${KAIROS_ISO}"
echo " Disk size: ${DISK_SIZE} MB"
echo "============================================"
echo ""

# ---- Read BCM SSH private key ----
BCM_SSH_KEY_CONTENT=""
if [[ -n "$BCM_SSH_KEY" && -f "$BCM_SSH_KEY" ]]; then
    BCM_SSH_KEY_CONTENT=$(cat "$BCM_SSH_KEY")
    echo "  BCM SSH key: ${BCM_SSH_KEY}"
elif [[ -f "${BUILD_DIR}/bcm-kairos-key" ]]; then
    BCM_SSH_KEY_CONTENT=$(cat "${BUILD_DIR}/bcm-kairos-key")
    echo "  BCM SSH key: ${BUILD_DIR}/bcm-kairos-key"
fi

# ---- Build BCM integration stages ----
BCM_STAGES=""
if [[ -n "$BCM_SSH_KEY_CONTENT" ]]; then
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
    - name: "BCM integration: set NOSYNC + start cmd"
      commands:
        - |
          # Wait for network to be ready
          for i in \$(seq 1 30); do
            ping -c1 -W2 ${HEAD_NODE_IP} >/dev/null 2>&1 && break
            sleep 2
          done

          # Get BCM-assigned node name by querying BCM via MAC address
          NODE_MAC=\$(ip link show ens3 2>/dev/null | awk '/ether/{print \$2}')
          export NODE_NAME=\$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
              -o ConnectTimeout=10 -i /var/lib/bcm/bcm-key \
              root@${HEAD_NODE_IP} \
              "echo -e 'device\nlist' | cmsh 2>/dev/null | grep -i '\${NODE_MAC}' | awk '{print \\\$2}'" \
              2>/dev/null)
          if [ -z "\${NODE_NAME}" ]; then
            export NODE_NAME=\$(hostname)
          fi
          hostnamectl set-hostname "\${NODE_NAME}" 2>/dev/null || hostname "\${NODE_NAME}" 2>/dev/null || true

          # Write Palette edge name for stylus-agent
          printf '#cloud-config\nstylus:\n  site:\n    name: %s\n' "\${NODE_NAME}" > /oem/91_palette_name.yaml

          # Install BCM head node's root SSH key so BCM can SSH to this node
          BCM_ROOT_PUBKEY=\$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
              -o ConnectTimeout=10 -i /var/lib/bcm/bcm-key \
              root@${HEAD_NODE_IP} 'cat /root/.ssh/id_ecdsa.pub' 2>/dev/null)
          if [ -n "\${BCM_ROOT_PUBKEY}" ]; then
            mkdir -p /root/.ssh
            grep -qF "\${BCM_ROOT_PUBKEY}" /root/.ssh/authorized_keys 2>/dev/null || \
              echo "\${BCM_ROOT_PUBKEY}" >> /root/.ssh/authorized_keys
            chmod 600 /root/.ssh/authorized_keys
          fi

          # Configure node on BCM head node
          ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
              -o ConnectTimeout=10 -i /var/lib/bcm/bcm-key \
              root@${HEAD_NODE_IP} \
              "echo -e 'device\nuse \${NODE_NAME}\nset installmode NOSYNC\ncommit' | cmsh" \
              >/dev/null 2>&1 || true

          # Create kairos category and disable irrelevant health checks
          ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
              -o ConnectTimeout=10 -i /var/lib/bcm/bcm-key \
              root@${HEAD_NODE_IP} \
              "cmsh -c 'category; list' | grep -q kairos || cmsh -c 'category; clone default kairos; commit'
          cmsh -c 'category; use kairos; monitoring; setup; healthconf; use interfaces; set disabled yes; commit'
          cmsh -c 'category; use kairos; monitoring; setup; healthconf; use mounts; set disabled yes; commit'
          cmsh -c 'category; use kairos; monitoring; setup; healthconf; use ntp; set disabled yes; commit'
          cmsh -c 'device; use \${NODE_NAME}; set category kairos; commit'" \
              >/dev/null 2>&1 || true

          # NFS mount BCM default-image rootfs
          mkdir -p /var/lib/cm/rootfs
          mount -t nfs -o ro,nolock,vers=3 ${HEAD_NODE_IP}:/cm/images/default-image /var/lib/cm/rootfs 2>/dev/null || {
            exit 0
          }

          # Prepare cmd config with correct Master IP + SSL certs
          mkdir -p /var/lib/cm/cmd-etc
          cp -a /var/lib/cm/rootfs/cm/local/apps/cmd/etc/. /var/lib/cm/cmd-etc/ 2>/dev/null || true
          sed -i "s/Master = master/Master = ${HEAD_NODE_IP}/" /var/lib/cm/cmd-etc/cmd.conf
          NODE_MAC=\$(ip link show ens3 2>/dev/null | awk '/ether/{print \$2}' | tr ':' '-')
          scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
              -i /var/lib/bcm/bcm-key \
              root@${HEAD_NODE_IP}:/cm/node-installer/certificates/\${NODE_MAC}/cert \
              /var/lib/cm/cmd-etc/cert.pem 2>/dev/null || true
          scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
              -i /var/lib/bcm/bcm-key \
              root@${HEAD_NODE_IP}:/cm/node-installer/certificates/\${NODE_MAC}/key \
              /var/lib/cm/cmd-etc/cert.key 2>/dev/null || true

          # Run cmd in isolated mount namespace via unshare
          unshare --mount --fork /bin/bash -c "
            mount --bind /var/lib/cm/cmd-etc /var/lib/cm/rootfs/cm/local/apps/cmd/etc
            mount -t proc proc /var/lib/cm/rootfs/proc 2>/dev/null || true
            mount -t sysfs sysfs /var/lib/cm/rootfs/sys 2>/dev/null || true
            mount -t tmpfs tmpfs /var/lib/cm/rootfs/tmp 2>/dev/null || true
            mount -t tmpfs tmpfs /var/lib/cm/rootfs/var/run 2>/dev/null || true
            mount -t tmpfs tmpfs /var/lib/cm/rootfs/var/spool/cmd 2>/dev/null || true
            cp /etc/resolv.conf /var/lib/cm/rootfs/tmp/resolv.conf 2>/dev/null || true
            mount --bind /var/lib/cm/rootfs/tmp/resolv.conf /var/lib/cm/rootfs/etc/resolv.conf 2>/dev/null || true
            echo \${NODE_NAME} > /var/lib/cm/rootfs/tmp/hostname 2>/dev/null || true
            mount --bind /var/lib/cm/rootfs/tmp/hostname /var/lib/cm/rootfs/etc/hostname 2>/dev/null || true
            exec chroot /var/lib/cm/rootfs /bin/bash -c '
              export HOSTNAME=\$(cat /etc/hostname)
              /cm/local/apps/cmd/sbin/cmd -s -n
            '
          " &
BCMEOF
    )
fi

# ---- Generate cloud-config for install ----
echo "[1/3] Generating cloud-config..."

CLOUD_CONFIG_DIR=$(mktemp -d)
mkdir -p "${CLOUD_CONFIG_DIR}"

cat > "${CLOUD_CONFIG_DIR}/config.yaml" <<CLOUDCONFIG
#cloud-config

# Auto-install: kairos-agent install runs automatically and powers off
install:
  auto: true
  poweroff: true

# Palette Edge Registration
stylus:
  site:
    paletteEndpoint: ${PALETTE_ENDPOINT}
    edgeHostToken: ${PALETTE_TOKEN}
    projectUid: ${PALETTE_PROJECT_UID}

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

# Create a FAT32 disk image with user-data (Kairos scans all block devices)
echo "  Creating user-data disk..."
USERDATA_IMG="${BUILD_DIR}/userdata.img"
dd if=/dev/zero of="${USERDATA_IMG}" bs=1M count=4 status=none
mkfs.vfat -n CIDATA "${USERDATA_IMG}" >/dev/null
mcopy -i "${USERDATA_IMG}" "${CLOUD_CONFIG_DIR}/config.yaml" "::user-data"
rm -rf "${CLOUD_CONFIG_DIR}"

# ---- Create blank disk ----
echo "[2/3] Creating blank disk (${DISK_SIZE}MB)..."
truncate -s "${DISK_SIZE}M" "${BUILD_DIR}/kairos-disk.raw"

# ---- Run QEMU install ----
echo "[3/3] Running kairos-agent install in QEMU..."
echo "  Boots CanvOS ISO, runs kairos-agent install via serial, powers off."

QEMU_LOG="${PROJECT_DIR}/logs/qemu-install.log"
mkdir -p "${PROJECT_DIR}/logs"

# Find OVMF firmware
OVMF=""
for f in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd; do
    [[ -f "$f" ]] && OVMF="$f" && break
done
if [[ -z "$OVMF" ]]; then
    echo "ERROR: OVMF/UEFI firmware not found"
    exit 1
fi

# Launch QEMU in background with serial socket
QEMU_SERIAL_SOCK="${BUILD_DIR}/.qemu-install.sock"
rm -f "$QEMU_SERIAL_SOCK"

qemu-system-x86_64 \
    -enable-kvm \
    -m 4096 \
    -smp 2 \
    -cpu host \
    -bios "$OVMF" \
    -display none \
    -chardev socket,id=ser0,path="${QEMU_SERIAL_SOCK}",server=on,wait=off \
    -serial chardev:ser0 \
    -drive if=virtio,format=raw,media=disk,file="${BUILD_DIR}/kairos-disk.raw" \
    -drive if=virtio,format=raw,readonly=on,file="${BUILD_DIR}/userdata.img" \
    -drive format=raw,media=cdrom,readonly=on,file="${KAIROS_ISO}" \
    -boot d \
    -pidfile "${BUILD_DIR}/.qemu-install.pid" \
    -daemonize

QEMU_PID=$(cat "${BUILD_DIR}/.qemu-install.pid")
echo "  QEMU started (PID ${QEMU_PID})"

# Wait for ISO to boot to root shell, then drive install via serial
echo "  Waiting for CanvOS ISO to boot..."
sleep 90  # GRUB timeout + kernel boot + systemd init

echo "  Running kairos-agent install via serial..."
# Send install commands: copy cloud-config to /oem/, run kairos-agent install
# kairos-agent install reads config from /oem/*.yaml, creates all partitions,
# deploys active+recovery images, then powers off the VM.
(
    sleep 2
    # Copy config to /oem/ for kairos-agent install to read (stylus validation requires it),
    # AND save a backup to /tmp/ since the install may overwrite /oem/90_custom.yaml
    printf 'mount /dev/vdb /mnt 2>/dev/null && cp /mnt/user-data /oem/90_custom.yaml && cp /mnt/user-data /tmp/99_bcm.yaml\r\n'
    sleep 3
    # Run install, then restore our config as 99_bcm.yaml (kairos-agent overwrites 90_custom.yaml), then poweroff
    printf 'kairos-agent --debug install 2>&1; mount /dev/vda2 /oem 2>/dev/null; cp /tmp/99_bcm.yaml /oem/99_bcm.yaml; poweroff\r\n'
    sleep 600
) | nc -U "$QEMU_SERIAL_SOCK" 2>&1 | tee "$QEMU_LOG" &
SERIAL_PID=$!

# Wait for QEMU to exit (install completes then VM powers off)
echo "  Waiting for install to complete..."
while kill -0 "$QEMU_PID" 2>/dev/null; do
    sleep 10
    # Show progress dots
    printf "."
done
echo ""

pkill -P "$SERIAL_PID" 2>/dev/null || true
kill "$SERIAL_PID" 2>/dev/null || true
wait "$SERIAL_PID" 2>/dev/null || true
rm -f "$QEMU_SERIAL_SOCK" "${BUILD_DIR}/.qemu-install.pid" "${BUILD_DIR}/userdata.img"

echo "  Install complete."

# ---- Validate ----
echo ""
echo "Validating partition layout..."

FDISK_OUT=$(fdisk -l "${BUILD_DIR}/kairos-disk.raw" 2>/dev/null || true)
echo "$FDISK_OUT"

PART_COUNT=$(echo "$FDISK_OUT" | grep -c "^${BUILD_DIR}/kairos-disk.raw" || true)
if [[ "$PART_COUNT" -ge 5 ]]; then
    echo ""
    echo "  [OK] Found ${PART_COUNT} partitions (all 5 COS partitions present)"
else
    echo ""
    echo "  [WARN] Found ${PART_COUNT} partitions (expected 5: GRUB, OEM, RECOVERY, STATE, PERSISTENT)"
    echo "  The install may have failed. Check ${QEMU_LOG}"
fi

# ---- Trim disk image ----
# The QEMU install creates an 80GB disk but most of COS_PERSISTENT is empty zeros.
# Punch holes to make it sparse — gzip compresses zeros to nearly nothing.
echo ""
echo "Trimming disk image..."
ORIG_SIZE=$(du -h "${BUILD_DIR}/kairos-disk.raw" | cut -f1)
fallocate --dig-holes "${BUILD_DIR}/kairos-disk.raw" 2>/dev/null || true
TRIMMED_SIZE=$(du -h "${BUILD_DIR}/kairos-disk.raw" | cut -f1)
echo "  Disk: ${ORIG_SIZE} -> ${TRIMMED_SIZE} (sparse)"

# ---- Generate checksum ----
cd "${BUILD_DIR}"
sha256sum kairos-disk.raw > kairos-disk.raw.sha256

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
