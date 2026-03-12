#!/bin/bash
# validate-kairos.sh
#
# Validates that a Kairos compute node booted correctly via BCM PXE.
# Connects through the BCM head node and runs a series of checks.
#
# Usage:
#   ./validate-kairos.sh [OPTIONS]
#
# Prerequisites:
#   1. BCM head node running (SSH at localhost:10022)
#   2. Kairos compute node booted (via test-kairos-pxe.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# BCM head node
SSH_PORT=10022
BCM_PASSWORD="${BCM_PASSWORD:?ERROR: BCM_PASSWORD not set. Set in env.json or export BCM_PASSWORD}"

# Kairos node
KAIROS_USER="kairos"
KAIROS_PASSWORD="kairos"
KAIROS_IP=""
COS_CHECKS=false

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Validates a Kairos compute node booted via BCM PXE.

Options:
  --ssh-port PORT      BCM head node SSH port (default: 10022)
  --password PASS      BCM root password (default: Br1ghtClust3r)
  --kairos-ip IP       Kairos node IP (default: auto-detect from DHCP leases)
  --kairos-user USER   Kairos SSH user (default: kairos)
  --kairos-pass PASS   Kairos SSH password (default: kairos)
  --cos-checks         Run COS partition + immutability checks (Option B)
  -h, --help           Show this help
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ssh-port)     SSH_PORT="$2"; shift 2 ;;
        --password)     BCM_PASSWORD="$2"; shift 2 ;;
        --kairos-ip)    KAIROS_IP="$2"; shift 2 ;;
        --kairos-user)  KAIROS_USER="$2"; shift 2 ;;
        --kairos-pass)  KAIROS_PASSWORD="$2"; shift 2 ;;
        --cos-checks)   COS_CHECKS=true; shift ;;
        -h|--help)      usage ;;
        *)              echo "Unknown option: $1"; usage ;;
    esac
done

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
BCM_SSH="sshpass -p ${BCM_PASSWORD} ssh ${SSH_OPTS} -p ${SSH_PORT} root@localhost"

# Filter BCM's MOTD noise from SSH command output
filter_motd() {
    grep -vE "cmfirstboot is still in progress|^$" || true
}

PASS=0
FAIL=0
WARN=0

check() {
    local name="$1"
    local result="$2"
    local detail="$3"

    if [[ "$result" == "PASS" ]]; then
        echo "  [PASS] ${name}"
        [[ -n "$detail" ]] && echo "         ${detail}"
        PASS=$((PASS + 1))
    elif [[ "$result" == "WARN" ]]; then
        echo "  [WARN] ${name}"
        [[ -n "$detail" ]] && echo "         ${detail}"
        WARN=$((WARN + 1))
    else
        echo "  [FAIL] ${name}"
        [[ -n "$detail" ]] && echo "         ${detail}"
        FAIL=$((FAIL + 1))
    fi
}

# ---- Preflight ----
if ! command -v sshpass &>/dev/null; then
    echo "ERROR: sshpass not found. Install with: sudo apt install sshpass"
    exit 1
fi

echo "============================================"
echo " Kairos Node Validation"
echo "============================================"
echo ""

# ---- Connect to head node ----
echo "[..] Connecting to BCM head node..."
if ! ${BCM_SSH} "echo ok" &>/dev/null; then
    echo "ERROR: Cannot SSH to BCM head node at localhost:${SSH_PORT}"
    exit 1
fi
echo "[OK] BCM head node reachable"
echo ""

# ---- Find Kairos node IP ----
if [[ -z "$KAIROS_IP" ]]; then
    echo "[..] Auto-detecting Kairos node IP from DHCP leases..."
    KAIROS_IP=$(${BCM_SSH} "arp -an 2>/dev/null | grep '52:54:00:00:02:01' | grep -oP '\\d+\\.\\d+\\.\\d+\\.\\d+'" 2>/dev/null | filter_motd)
    if [[ -z "$KAIROS_IP" ]]; then
        echo "ERROR: Could not find Kairos node in DHCP leases."
        echo "Is the compute node running? (./test-kairos-pxe.sh --direct)"
        exit 1
    fi
fi
echo "[OK] Kairos node IP: ${KAIROS_IP}"
echo ""

# ---- SSH to Kairos node through head node ----
# BCM provisioning provides root SSH via key-based auth from the head node.
# The kairos user may not exist (user-data boot stages don't run under BCM).
echo "[..] Testing SSH to Kairos node (root@${KAIROS_IP})..."
KAIROS_SSH="${BCM_SSH} \"ssh ${SSH_OPTS} root@${KAIROS_IP}\""

# Test SSH connectivity
SSH_TEST=$(${BCM_SSH} "ssh ${SSH_OPTS} root@${KAIROS_IP} 'echo CONNECTED' 2>&1" 2>/dev/null | filter_motd || true)
if [[ "$SSH_TEST" != *"CONNECTED"* ]]; then
    echo "ERROR: Cannot SSH to Kairos node at ${KAIROS_IP}"
    echo "SSH output: ${SSH_TEST}"
    echo ""
    echo "The node may still be booting, or user-data was not applied."
    echo "Try again in a minute, or check the console."
    exit 1
fi
echo "[OK] SSH connected"
echo ""

# ---- Run validation checks ----
echo "============================================"
echo " Running Checks"
echo "============================================"
echo ""

# Collect all info in one SSH session to minimize round-trips
VALIDATION=$(${BCM_SSH} "ssh ${SSH_OPTS} root@${KAIROS_IP} '
echo \"===OS_RELEASE===\"
cat /etc/os-release 2>/dev/null
echo \"===KAIROS_RELEASE===\"
cat /etc/kairos-release 2>/dev/null || echo MISSING
echo \"===KAIROS_VERSION===\"
kairos-agent version 2>/dev/null || echo MISSING
echo \"===HOSTNAME===\"
hostname 2>/dev/null
echo \"===KERNEL===\"
uname -r 2>/dev/null
echo \"===CMDLINE===\"
cat /proc/cmdline 2>/dev/null
echo \"===K3S_BIN===\"
ls -la /usr/local/bin/k3s 2>/dev/null || which k3s 2>/dev/null || echo MISSING
echo \"===K3S_VERSION===\"
k3s --version 2>/dev/null || echo MISSING
echo \"===KUBECTL===\"
which kubectl 2>/dev/null || echo MISSING
echo \"===SYSTEMD_KAIROS===\"
systemctl list-units --all --no-pager 2>/dev/null | grep -iE \"kairos|k3s|stylus\" || echo NONE
echo \"===SERVICES===\"
systemctl is-active kairos-agent 2>/dev/null || echo inactive
echo \"---\"
systemctl is-active stylus 2>/dev/null || echo inactive
echo \"===NETWORK===\"
ip -4 addr show 2>/dev/null | grep inet
echo \"===IMMUCORE===\"
journalctl -u immucore 2>/dev/null | grep -i \"version\" | head -1 || echo MISSING
echo \"===SQUASHFS===\"
mount 2>/dev/null | grep squashfs || echo NOT_MOUNTED
echo \"===LIVE_BOOT===\"
cat /run/cos/cos-layout.env 2>/dev/null || echo MISSING
echo \"===USERS===\"
grep kairos /etc/passwd 2>/dev/null || echo MISSING
echo \"===ISSUE===\"
cat /etc/issue 2>/dev/null || echo MISSING
echo \"===COS_PARTITIONS===\"
lsblk -o NAME,LABEL,FSTYPE,SIZE,MOUNTPOINT 2>/dev/null || echo MISSING
echo \"===COS_OEM===\"
blkid -L COS_OEM 2>/dev/null || echo MISSING
echo \"===COS_STATE===\"
blkid -L COS_STATE 2>/dev/null || echo MISSING
echo \"===COS_RECOVERY===\"
blkid -L COS_RECOVERY 2>/dev/null || echo MISSING
echo \"===COS_PERSISTENT===\"
blkid -L COS_PERSISTENT 2>/dev/null || echo MISSING
echo \"===ROOT_MOUNT===\"
mount | grep \" / \" | head -1 || echo MISSING
echo \"===COS_LAYOUT===\"
cat /run/cos/cos-layout.env 2>/dev/null || echo MISSING
echo \"===END===\"
'" 2>/dev/null | filter_motd)

# Parse results
get_section() {
    echo "$VALIDATION" | sed -n "/===${1}===/,/===.*===/p" | grep -v "^===" | head -20 || true
}

# 1. OS Release
echo "-- Operating System --"
OS_NAME=$(get_section "OS_RELEASE" | grep "^PRETTY_NAME=" | cut -d'"' -f2)
if [[ -n "$OS_NAME" ]]; then check "OS identified" "PASS" "$OS_NAME"; else check "OS identified" "FAIL" ""; fi

# 2. Kairos Release
KAIROS_REL=$(get_section "KAIROS_RELEASE")
if [[ "$KAIROS_REL" != "MISSING" ]] && [[ -n "$KAIROS_REL" ]]; then
    KAIROS_VER_STR=$(echo "$KAIROS_REL" | grep "KAIROS_VERSION" | head -1 | cut -d'=' -f2)
    check "Kairos release file" "PASS" "${KAIROS_VER_STR:-present}"
else
    check "Kairos release file" "FAIL" "/etc/kairos-release not found"
fi

# 3. Kairos Agent
KAIROS_AGENT=$(get_section "KAIROS_VERSION")
if [[ "$KAIROS_AGENT" != "MISSING" ]] && [[ -n "$KAIROS_AGENT" ]]; then
    check "kairos-agent binary" "PASS" "$KAIROS_AGENT"
else
    check "kairos-agent binary" "FAIL" "not found in PATH"
fi


# 5. Kernel
echo ""
echo "-- Kernel & Boot --"
KERNEL=$(get_section "KERNEL")
if [[ -n "$KERNEL" ]]; then check "Kernel" "PASS" "$KERNEL"; else check "Kernel" "FAIL" ""; fi

CMDLINE=$(get_section "CMDLINE")
# BCM provisioning uses its own kernel cmdline — check for stylus.registration instead
if echo "$CMDLINE" | grep -q "stylus.registration"; then
    check "Registration cmdline" "PASS" "stylus.registration present"
else
    check "Registration cmdline" "WARN" "stylus.registration not in cmdline (may already be registered)"
fi

# 7. Network
echo ""
echo "-- Networking --"
NETWORK=$(get_section "NETWORK")
if [[ -n "$NETWORK" ]]; then
    KAIROS_NET_IP=$(echo "$NETWORK" | grep -v "127.0.0" | head -1 | awk '{print $2}')
    check "Network interface" "PASS" "$KAIROS_NET_IP"
else
    check "Network interface" "FAIL" "no IPv4 address"
fi

# 8. Kubernetes

# 9. Services
echo ""
echo "-- Services --"
SERVICES=$(get_section "SYSTEMD_KAIROS")
if [[ "$SERVICES" != "NONE" ]] && [[ -n "$SERVICES" ]]; then
    SVC_COUNT=$(echo "$SERVICES" | wc -l)
    check "Kairos/Stylus services" "PASS" "${SVC_COUNT} service(s) found"
    echo "$SERVICES" | while read -r line; do
        echo "         $line"
    done
else
    check "Kairos/Stylus services" "FAIL" "no kairos/stylus services"
fi

# Check stylus-agent specifically (the key service for BCM provisioning)
if echo "$SERVICES" | grep -q "stylus-agent.*running"; then
    check "stylus-agent" "PASS" "active"
else
    check "stylus-agent" "FAIL" "not running"
fi

# Check cmd (BCM compute daemon)
if echo "$SERVICES" | grep -q "cmd.*running" || ${BCM_SSH} "ssh ${SSH_OPTS} root@${KAIROS_IP} 'systemctl is-active cmd'" 2>/dev/null | filter_motd | grep -q "active"; then
    check "cmd service" "PASS" "active"
else
    check "cmd service" "FAIL" "not running"
fi

# 10. User
echo ""
echo "-- User Config --"
check "SSH login" "PASS" "root@${KAIROS_IP} (via BCM head node)"

# Check user-data was applied
USERDATA_CHECK=$(${BCM_SSH} "ssh ${SSH_OPTS} root@${KAIROS_IP} 'test -f /oem/99_userdata.yaml && echo present || echo missing'" 2>/dev/null | filter_motd || true)
if [[ "$USERDATA_CHECK" == *"present"* ]]; then
    check "user-data" "PASS" "/oem/99_userdata.yaml present"
else
    check "user-data" "FAIL" "/oem/99_userdata.yaml missing"
fi

# Check Palette registration
REG_LOGS=$(${BCM_SSH} "ssh ${SSH_OPTS} root@${KAIROS_IP} 'journalctl -u stylus-agent --no-pager'" 2>/dev/null | filter_motd || true)
if echo "$REG_LOGS" | grep -q "registering edge host device with hubble"; then
    check "Palette registration" "PASS" "registered with Palette"
else
    check "Palette registration" "WARN" "registration not detected"
fi

# ---- COS Partition Checks (Option B) ----
# Auto-detect: if COS_OEM exists, enable COS checks automatically
COS_OEM_DEV=$(get_section "COS_OEM")
if [[ "$COS_CHECKS" == "true" ]] || [[ "$COS_OEM_DEV" != "MISSING" && -n "$COS_OEM_DEV" ]]; then
    echo ""
    echo "-- COS Partitions (Option B) --"

    if [[ "$COS_OEM_DEV" != "MISSING" && -n "$COS_OEM_DEV" ]]; then
        check "COS_OEM partition" "PASS" "$COS_OEM_DEV"
    else
        check "COS_OEM partition" "FAIL" "not found"
    fi

    COS_RECOVERY_DEV=$(get_section "COS_RECOVERY")
    if [[ "$COS_RECOVERY_DEV" != "MISSING" && -n "$COS_RECOVERY_DEV" ]]; then
        check "COS_RECOVERY partition" "PASS" "$COS_RECOVERY_DEV"
    else
        check "COS_RECOVERY partition" "FAIL" "not found"
    fi

    COS_STATE_DEV=$(get_section "COS_STATE")
    if [[ "$COS_STATE_DEV" != "MISSING" && -n "$COS_STATE_DEV" ]]; then
        check "COS_STATE partition" "PASS" "$COS_STATE_DEV"
    else
        check "COS_STATE partition" "WARN" "not found (created on first Kairos boot)"
    fi

    COS_PERSISTENT_DEV=$(get_section "COS_PERSISTENT")
    if [[ "$COS_PERSISTENT_DEV" != "MISSING" && -n "$COS_PERSISTENT_DEV" ]]; then
        check "COS_PERSISTENT partition" "PASS" "$COS_PERSISTENT_DEV"
    else
        check "COS_PERSISTENT partition" "WARN" "not found (created on first Kairos boot)"
    fi

    # Check root filesystem immutability
    ROOT_MOUNT=$(get_section "ROOT_MOUNT")
    if echo "$ROOT_MOUNT" | grep -q "ro,\|ro "; then
        check "Root filesystem immutable" "PASS" "mounted read-only"
    elif [[ -n "$ROOT_MOUNT" && "$ROOT_MOUNT" != "MISSING" ]]; then
        check "Root filesystem immutable" "WARN" "mounted read-write: $ROOT_MOUNT"
    else
        check "Root filesystem immutable" "WARN" "could not determine mount mode"
    fi

    # Check cos-layout.env
    COS_LAYOUT=$(get_section "COS_LAYOUT")
    if [[ "$COS_LAYOUT" != "MISSING" && -n "$COS_LAYOUT" ]]; then
        check "COS layout config" "PASS" "cos-layout.env present"
    else
        check "COS layout config" "WARN" "/run/cos/cos-layout.env missing"
    fi
fi

# ---- Summary ----
TOTAL=$((PASS + FAIL + WARN))
echo ""
echo "============================================"
echo " Validation Summary"
echo "============================================"
echo " PASS: ${PASS}/${TOTAL}"
echo " WARN: ${WARN}/${TOTAL}"
echo " FAIL: ${FAIL}/${TOTAL}"
echo "============================================"

if [[ $FAIL -gt 0 ]]; then
    echo " Result: SOME CHECKS FAILED"
    exit 1
else
    echo " Result: ALL CHECKS PASSED"
    exit 0
fi
