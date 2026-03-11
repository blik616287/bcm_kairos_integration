#!/bin/bash
# bcm-sync-userdata.sh — sync BCM hostname to Palette edge name
#
# Called as ExecStartPre for stylus-agent.service.
# BCM sets the hostname during provisioning/sync. This script updates
# the Palette user-data so stylus-agent registers with the BCM node name.
#
# Also handles registration mode: BCM always PXE boots, so the
# stylus.registration kernel param (which we set in GRUB) never reaches
# the running kernel. We detect unregistered nodes and bind-mount a
# modified /proc/cmdline that includes stylus.registration.

USERDATA="/oem/99_userdata.yaml"

# ---- Registration mode ----
# stylus-agent checks /proc/cmdline for 'stylus.registration' to enter
# registration mode. BCM PXE boot doesn't include this param.
# If the node hasn't registered yet, inject it via bind mount.
if ! grep -q "stylus.registration" /proc/cmdline 2>/dev/null; then
    NEEDS_REGISTRATION=false
    if [ ! -f /oem/.stylus-state ]; then
        NEEDS_REGISTRATION=true
    elif ! grep -q "authToken" /oem/.stylus-state 2>/dev/null; then
        NEEDS_REGISTRATION=true
    fi

    if [ "$NEEDS_REGISTRATION" = "true" ]; then
        echo "$(cat /proc/cmdline) stylus.registration" > /tmp/cmdline-registration
        mount --bind /tmp/cmdline-registration /proc/cmdline
        echo "bcm-sync: enabled registration mode (no auth token found)"

        # 80_stylus.yaml in /oem/ triggers the upgrade path instead of registration,
        # which crashes on auth failure and poisons Palette rate limits.
        # Remove it so stylus-agent enters registration mode properly.
        if [ -f /oem/80_stylus.yaml ]; then
            rm -f /oem/80_stylus.yaml
            echo "bcm-sync: removed /oem/80_stylus.yaml (prevents upgrade-path crash)"
        fi
    fi
fi

# ---- Hostname sync ----
NODE_NAME=$(hostname)

if [ -z "$NODE_NAME" ] || [ "$NODE_NAME" = "localhost" ]; then
    echo "bcm-sync-userdata: hostname not set yet, skipping"
    exit 0
fi

if [ ! -f "$USERDATA" ]; then
    echo "bcm-sync-userdata: $USERDATA not found, skipping"
    exit 0
fi

# Check if name already matches
if grep -q "name: ${NODE_NAME}$" "$USERDATA" 2>/dev/null; then
    echo "bcm-sync-userdata: name already set to ${NODE_NAME}"
    exit 0
fi

# Update the name field in user-data
sed -i "s/^    name: .*/    name: ${NODE_NAME}/" "$USERDATA"

# Update /run/stylus/userdata if it exists (stylus reads from here)
if [ -f /run/stylus/userdata ]; then
    sed -i "s/^    name: .*/    name: ${NODE_NAME}/" /run/stylus/userdata
fi

# Update cached edge name so stylus doesn't use a stale value
if [ -f /oem/.stylus-state ]; then
    sed -i "s/^siteName: .*/siteName: ${NODE_NAME}/" /oem/.stylus-state
fi

echo "bcm-sync-userdata: edge name set to ${NODE_NAME}"
