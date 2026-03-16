#!/bin/bash
# install-kairos.sh
#
# Runs on the BCM-provisioned compute node on first boot.
# Downloads the Kairos raw disk image from the BCM head node
# and writes it directly to disk via dd, then reboots.
#
# IMPORTANT: This script dd's over the same disk it's running from.
# All binaries are staged to /dev/shm (tmpfs/RAM) first so the dd
# pipeline and reboot can complete after the on-disk filesystem is gone.
#
# Placed at /usr/local/sbin/install-kairos.sh in the BCM installer image.

set -euo pipefail

LOG="/dev/shm/kairos-install.log"
exec > >(tee -a "$LOG") 2>&1

HEAD_IP="10.141.255.254"
RAW_URL="http://${HEAD_IP}:8888/disk.raw.gz"
DISK=$(lsblk -ndo NAME,TYPE | awk '$2=="disk" && $1!~/^fd[0-9]/{print "/dev/"$1; exit}')

echo "[$(date)] ============================================"
echo "[$(date)] Kairos Raw Image Installer"
echo "[$(date)] ============================================"
echo "[$(date)] Head node:  ${HEAD_IP}"
echo "[$(date)] Image URL:  ${RAW_URL}"
echo "[$(date)] Target:     ${DISK:-NOT FOUND}"

# Validate target disk
if [[ -z "$DISK" || ! -b "$DISK" ]]; then
    echo "[$(date)] ERROR: No disk device found"
    lsblk 2>/dev/null || true
    exit 1
fi

# Wait for the HTTP server to be ready (head node may still be starting services)
echo "[$(date)] Waiting for image server..."
RETRIES=0
MAX_RETRIES=60
while ! curl --fail --silent --head "$RAW_URL" >/dev/null 2>&1; do
    RETRIES=$((RETRIES + 1))
    if [[ $RETRIES -ge $MAX_RETRIES ]]; then
        echo "[$(date)] ERROR: Image server not available after ${MAX_RETRIES} attempts"
        exit 1
    fi
    sleep 10
done
echo "[$(date)] Image server ready"

# Get compressed image size for progress
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
/dev/shm/kinstall/reboot -f
DDEOF
chmod +x "$RAMDIR/run-dd.sh"

echo "[$(date)] Starting dd from RAM..."
export LD_LIBRARY_PATH="$RAMDIR/lib"
exec "$RAMDIR/bash" "$RAMDIR/run-dd.sh"
