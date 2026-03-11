#!/bin/bash
# bcm-compat-fixes.sh — fixes for BCM provisioning compatibility
#
# BCM provisions Kairos differently from the native Kairos installer.
# Some system files need patching for BCM's environment.
#
# One-time fixes run once (marker file). Every-boot fixes run each boot.

# ---- Every-boot fixes ----

# Set hostname from /etc/hostname: BCM's node-installer writes this during
# provisioning, but after PXE callinginit pivot-root the hostname is empty.
# cmd daemon crashes without it ("BAD_VALUE, hostname").
if [ -f /etc/hostname ]; then
    EXPECTED=$(cat /etc/hostname | tr -d '[:space:]')
    CURRENT=$(hostname)
    if [ -n "$EXPECTED" ] && [ "$CURRENT" != "$EXPECTED" ]; then
        hostnamectl set-hostname "$EXPECTED" 2>/dev/null || hostname "$EXPECTED"
        echo "bcm-compat: set hostname to $EXPECTED"
    fi
fi

# ---- One-time fixes ----

MARKER="/var/lib/bcm-compat-fixes.done"
if [ -f "$MARKER" ]; then
    exit 0
fi

# Fix resolved hook: uses 'return' outside a function, crashes networking.service
RESOLVED="/etc/network/if-up.d/resolved"
if [ -f "$RESOLVED" ] && grep -q '^        return$' "$RESOLVED"; then
    sed -i 's/^        return$/        exit 0/' "$RESOLVED"
    echo "bcm-compat: fixed resolved hook (return -> exit 0)"
fi

# Fix resolv.conf: Kairos ships a symlink to systemd-resolved's stub resolver.
# BCM masks systemd-resolved, leaving a dead symlink and no DNS.
# Replace with a file that lets DHCP (dhclient) manage it directly.
if [ -L /etc/resolv.conf ] && [ ! -e /etc/resolv.conf ]; then
    rm -f /etc/resolv.conf
    # Use head node as fallback; dhclient will overwrite on lease renewal
    echo "nameserver 10.141.255.254" > /etc/resolv.conf
    echo "bcm-compat: fixed resolv.conf (replaced dead symlink)"
fi

touch "$MARKER"
echo "bcm-compat: one-time fixes applied"
