#!/bin/bash
# orchestrate.sh — Run the full BCM + Kairos pipeline as a parallel DAG
#
# DAG:
#   clean-all ──┬── download-iso → bcm-prepare → bcm-run ──┐
#               │                                           ├── kairos-deploy → kairos-run → validate
#               └── kairos-build → kairos-extract ──────────┘
#
# Each step logs to ./logs/orchestrate-<step>.log
# Shows a compact rolling status (last 5 lines per step, refreshing every 5s).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

LOG_DIR="./logs"
STATUS_DIR="./logs/.status"
mkdir -p "$LOG_DIR" "$STATUS_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Track background PIDs
declare -A PIDS

# File-based status (works across subshells)
set_status() {
    echo "$2" > "${STATUS_DIR}/$1"
}

get_status() {
    cat "${STATUS_DIR}/$1" 2>/dev/null || echo "pending"
}

banner() {
    echo ""
    echo -e "${BOLD}════════════════════════════════════════════════${NC}"
    echo -e "${BOLD} $1${NC}"
    echo -e "${BOLD}════════════════════════════════════════════════${NC}"
    echo ""
}

log_file() {
    echo "${LOG_DIR}/orchestrate-${1}.log"
}

# Run a make target, logging to file. Updates status file on completion.
run_step() {
    local step="$1"
    local logf
    logf=$(log_file "$step")
    > "$logf"

    set_status "$step" "running"

    make "$step" > "$logf" 2>&1
    local rc=$?

    if [[ $rc -eq 0 ]]; then
        set_status "$step" "done"
    else
        set_status "$step" "fail"
    fi
    return $rc
}

# Show compact rolling status for active logs (last 5 lines each)
show_status() {
    local steps=("$@")
    echo ""
    for s in "${steps[@]}"; do
        local logf
        logf=$(log_file "$s")
        local status
        status=$(get_status "$s")
        local icon="⏳"
        [[ "$status" == "done" ]] && icon="✅"
        [[ "$status" == "fail" ]] && icon="❌"
        [[ "$status" == "pending" ]] && icon="⏸️ "
        [[ "$status" == "blocked" ]] && icon="🔒"

        # Special handling: show download progress for download-iso
        if [[ "$s" == "download-iso" && "$status" == "running" ]]; then
            local iso_path="dist/${ISO_FILENAME:-bcm-11.0-ubuntu2404.iso}"
            if [[ -f "$iso_path" ]]; then
                local cur_bytes
                cur_bytes=$(stat -c%s "$iso_path" 2>/dev/null || echo 0)
                local cur_mb=$(( cur_bytes / 1048576 ))
                if [[ -n "${ISO_TOTAL_MB:-}" && "$ISO_TOTAL_MB" -gt 0 ]]; then
                    local pct=$(( cur_mb * 100 / ISO_TOTAL_MB ))
                    echo -e "  ${icon} ${BOLD}${s}${NC} [${status}] — ${cur_mb}MB / ${ISO_TOTAL_MB}MB (${pct}%)"
                else
                    echo -e "  ${icon} ${BOLD}${s}${NC} [${status}] — ${cur_mb}MB downloaded"
                fi
            else
                echo -e "  ${icon} ${BOLD}${s}${NC} [${status}]"
            fi
        else
            echo -e "  ${icon} ${BOLD}${s}${NC} [${status}]"
        fi

        if [[ "$status" == "running" ]] && [[ -s "$logf" ]]; then
            tail -n 5 "$logf" 2>/dev/null | cut -c1-80 | sed 's/^/     │ /'
        fi
    done
}

# Cleanup on exit: kill all child processes and QEMU VMs
cleanup() {
    local exit_code=$?
    # Avoid recursive traps
    trap - EXIT INT TERM HUP

    if [[ $exit_code -ne 0 ]] || [[ "${ORCHESTRATE_INTERRUPTED:-}" == "true" ]]; then
        echo ""
        echo -e "${RED}═══ Orchestrate interrupted — cleaning up ═══${NC}"
    fi

    # Kill all tracked background PIDs and their process trees
    for pid in "${PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            pkill -P "$pid" 2>/dev/null || true
            kill "$pid" 2>/dev/null || true
        fi
    done

    # Stop any QEMU VMs started during this run
    for pidfile in build/.bcm-qemu.pid build/.kairos-qemu.pid; do
        if [[ -f "$pidfile" ]]; then
            local qpid
            qpid=$(cat "$pidfile" 2>/dev/null)
            if [[ -n "$qpid" ]] && kill -0 "$qpid" 2>/dev/null; then
                echo -e "  ${YELLOW}Stopping VM ($pidfile)${NC}"
                kill "$qpid" 2>/dev/null || true
                rm -f "$pidfile"
            fi
        fi
    done

    # Kill any remaining children of this script
    jobs -p 2>/dev/null | xargs -r kill 2>/dev/null || true
    wait 2>/dev/null || true

    # Clean up status files
    rm -rf "$STATUS_DIR"

    if [[ $exit_code -ne 0 ]] || [[ "${ORCHESTRATE_INTERRUPTED:-}" == "true" ]]; then
        echo -e "${RED}═══ Cleanup complete ═══${NC}"
    fi
}

on_signal() {
    ORCHESTRATE_INTERRUPTED="true"
    exit 1
}

trap cleanup EXIT
trap on_signal INT TERM HUP

# ---- Read config for download progress ----
ISO_FILENAME=$(jq -r '.iso_filename // "bcm-11.0-ubuntu2404.iso"' env.json 2>/dev/null || echo "bcm-11.0-ubuntu2404.iso")
JFROG_INSTANCE=$(jq -r '.jfrog_instance // "insightsoftmax.jfrog.io"' env.json 2>/dev/null || echo "insightsoftmax.jfrog.io")
JFROG_REPO=$(jq -r '.jfrog_repo // "iso-releases"' env.json 2>/dev/null || echo "iso-releases")
JFROG_TOKEN=$(jq -r '.jfrog_token // empty' env.json 2>/dev/null || true)

# Get ISO size via HEAD request for download progress
ISO_TOTAL_MB=0
if [[ -n "$JFROG_TOKEN" ]]; then
    ISO_TOTAL_BYTES=$(curl --silent --head --fail --location \
        -H "Authorization: Bearer ${JFROG_TOKEN}" \
        "https://${JFROG_INSTANCE}/artifactory/${JFROG_REPO}/${ISO_FILENAME}" 2>/dev/null \
        | grep -i content-length | tail -1 | tr -d '[:space:]' | cut -d: -f2)
    if [[ -n "$ISO_TOTAL_BYTES" && "$ISO_TOTAL_BYTES" -gt 0 ]] 2>/dev/null; then
        ISO_TOTAL_MB=$(( ISO_TOTAL_BYTES / 1048576 ))
    fi
fi

# All pipeline steps
ALL_STEPS=("download-iso" "bcm-prepare" "bcm-run" "kairos-build" "kairos-extract" "kairos-deploy" "kairos-run" "validate")

# Initialize all statuses
for s in "${ALL_STEPS[@]}"; do
    set_status "$s" "pending"
done
set_status "kairos-deploy" "blocked"
set_status "kairos-run" "blocked"
set_status "validate" "blocked"

# ════════════════════════════════════════════════
#  Phase 0: Clean
# ════════════════════════════════════════════════
banner "Phase 0: Clean slate"
run_step "clean-all"

# ════════════════════════════════════════════════
#  Phase 1: Parallel — BCM track + Kairos track
# ════════════════════════════════════════════════
banner "Phase 1: Build (parallel)"
echo -e "${YELLOW}Track A:${NC} download-iso → bcm-prepare → bcm-run"
echo -e "${YELLOW}Track B:${NC} kairos-build → kairos-extract"
echo ""

# Track A (BCM) — sequential steps in a subshell
(
    run_step "download-iso" && \
    run_step "bcm-prepare" && \
    run_step "bcm-run"
) &
PIDS["track-a"]=$!

# Track B (Kairos) — sequential steps in a subshell
(
    run_step "kairos-build" && \
    run_step "kairos-extract"
) &
PIDS["track-b"]=$!

# Poll status while both tracks run
while true; do
    if ! kill -0 "${PIDS["track-a"]}" 2>/dev/null && ! kill -0 "${PIDS["track-b"]}" 2>/dev/null; then
        break
    fi
    show_status "${ALL_STEPS[@]}"
    echo -e "\n  ${CYAN}(refreshing every 5s)${NC}"
    sleep 5
    clear
    banner "Pipeline Status"
done

TRACK_A_OK=true
TRACK_B_OK=true

if ! wait "${PIDS["track-a"]}"; then
    TRACK_A_OK=false
fi
if ! wait "${PIDS["track-b"]}"; then
    TRACK_B_OK=false
fi

# Final Phase 1 status
show_status "${ALL_STEPS[@]}"
echo ""

if [[ "$TRACK_A_OK" != "true" ]]; then
    echo -e "${RED}═══ Track A (BCM) failed ═══${NC}"
    exit 1
fi
if [[ "$TRACK_B_OK" != "true" ]]; then
    echo -e "${RED}═══ Track B (Kairos build) failed ═══${NC}"
    exit 1
fi

echo -e "${GREEN}═══ Phase 1 complete: BCM running + Kairos built ═══${NC}"
sleep 2

# ════════════════════════════════════════════════
#  Phase 2: Deploy + Run (sequential)
# ════════════════════════════════════════════════

# kairos-deploy (foreground, blocks until done)
run_step "kairos-deploy"
if [[ "$(get_status "kairos-deploy")" == "fail" ]]; then
    show_status "${ALL_STEPS[@]}"
    echo -e "\n${RED}═══ kairos-deploy failed ═══${NC}"
    exit 1
fi

# kairos-run (background with rolling status)
run_step "kairos-run" &
PIDS["kairos-run"]=$!

while kill -0 "${PIDS["kairos-run"]}" 2>/dev/null; do
    show_status "${ALL_STEPS[@]}"
    echo -e "\n  ${CYAN}(refreshing every 5s)${NC}"
    sleep 5
    clear
    banner "Pipeline Status"
done

if ! wait "${PIDS["kairos-run"]}"; then
    show_status "${ALL_STEPS[@]}"
    echo -e "\n${RED}═══ kairos-run failed ═══${NC}"
    exit 1
fi

echo -e "${GREEN}═══ Phase 2 complete: Compute node provisioned ═══${NC}"
sleep 2

# ════════════════════════════════════════════════
#  Phase 3: Validate
# ════════════════════════════════════════════════

run_step "validate"
if [[ "$(get_status "validate")" == "fail" ]]; then
    show_status "${ALL_STEPS[@]}"
    echo -e "\n${RED}═══ validate failed ═══${NC}"
    exit 1
fi

# ════════════════════════════════════════════════
#  Summary
# ════════════════════════════════════════════════
banner "Pipeline Complete"
show_status "${ALL_STEPS[@]}"
echo ""
echo -e "${GREEN} All steps passed.${NC}"
echo ""
echo " Logs:"
for f in "$LOG_DIR"/orchestrate-*.log; do
    step=$(basename "$f" .log | sed 's/orchestrate-//')
    size=$(du -h "$f" | cut -f1)
    echo "   ${step}: ${f} (${size})"
done
echo ""
echo " VMs running:"
echo "   BCM head node:  localhost:10022 (SSH), localhost:10443 (HTTPS)"
echo "   Kairos compute: 10.141.0.1 (via BCM)"
echo ""
echo " To tear down:"
echo "   make kairos-stop && make bcm-stop"
