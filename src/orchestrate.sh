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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

LOG_DIR="./logs"
mkdir -p "$LOG_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Track background PIDs and their steps
declare -A PIDS
declare -A STEP_STATUS

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

# Run a make target, logging to file. Sets STEP_STATUS on completion.
run_step() {
    local step="$1"
    local logf
    logf=$(log_file "$step")
    > "$logf"

    STEP_STATUS[$step]="running"

    make "$step" > "$logf" 2>&1
    local rc=$?

    if [[ $rc -eq 0 ]]; then
        STEP_STATUS[$step]="done"
    else
        STEP_STATUS[$step]="fail"
    fi
    return $rc
}

# Run a step in the background, store PID
run_step_bg() {
    local step="$1"
    run_step "$step" &
    PIDS[$step]=$!
}

# Wait for a background step to finish, exit on failure
wait_step() {
    local step="$1"
    local pid="${PIDS[$step]}"
    if ! wait "$pid"; then
        echo ""
        echo -e "${RED}═══ Pipeline failed at: ${step} ═══${NC}"
        echo -e "${RED}Log: $(log_file "$step")${NC}"
        kill_bg
        exit 1
    fi
}

# Show compact rolling status for active logs (last 5 lines each)
show_status() {
    local steps=("$@")
    echo ""
    for s in "${steps[@]}"; do
        local logf
        logf=$(log_file "$s")
        local status="${STEP_STATUS[$s]:-pending}"
        local icon="⏳"
        [[ "$status" == "done" ]] && icon="✅"
        [[ "$status" == "fail" ]] && icon="❌"
        [[ "$status" == "pending" ]] && icon="⏸️ "
        [[ "$status" == "blocked" ]] && icon="🔒"
        echo -e "  ${icon} ${BOLD}${s}${NC} [${status}]"
        if [[ -s "$logf" ]]; then
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
            # Kill the entire process group spawned by the subshell
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
STEP_STATUS["download-iso"]="running"
STEP_STATUS["bcm-prepare"]="pending"
STEP_STATUS["bcm-run"]="pending"

# Track B (Kairos) — sequential steps in a subshell
(
    run_step "kairos-build" && \
    run_step "kairos-extract"
) &
PIDS["track-b"]=$!
STEP_STATUS["kairos-build"]="running"
STEP_STATUS["kairos-extract"]="pending"

# Downstream steps — blocked until Phase 1 completes
ALL_STEPS=("download-iso" "bcm-prepare" "bcm-run" "kairos-build" "kairos-extract" "kairos-deploy" "kairos-run" "validate")
STEP_STATUS["kairos-deploy"]="blocked"
STEP_STATUS["kairos-run"]="blocked"
STEP_STATUS["validate"]="blocked"

# Poll status while both tracks run
TRACK_A_OK=true
TRACK_B_OK=true

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
STEP_STATUS["kairos-deploy"]="running"
run_step "kairos-deploy"
if [[ "${STEP_STATUS["kairos-deploy"]}" == "fail" ]]; then
    show_status "${ALL_STEPS[@]}"
    echo -e "\n${RED}═══ kairos-deploy failed ═══${NC}"
    exit 1
fi

# kairos-run (background with rolling status)
run_step "kairos-run" &
PIDS["kairos-run"]=$!
STEP_STATUS["kairos-run"]="running"

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

STEP_STATUS["validate"]="running"
run_step "validate"
if [[ "${STEP_STATUS["validate"]}" == "fail" ]]; then
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
