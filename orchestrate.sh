#!/bin/bash
# orchestrate.sh — Run the full BCM + Kairos pipeline as a parallel DAG
#
# DAG:
#   clean-all ──┬── download-iso → bcm-prepare → bcm-run ──┐
#               │                                           ├── kairos-deploy → kairos-run → validate
#               └── kairos-build → kairos-extract ──────────┘
#
# Each step logs to ./logs/orchestrate-<step>.log
# The script tails the currently active log(s) in real time.

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

    echo -e "${CYAN}[START]${NC} ${step} → ${logf}"
    STEP_STATUS[$step]="running"

    make "$step" > "$logf" 2>&1
    local rc=$?

    if [[ $rc -eq 0 ]]; then
        STEP_STATUS[$step]="done"
        echo -e "${GREEN}[PASS]${NC}  ${step} ($(tail -1 "$logf"))"
    else
        STEP_STATUS[$step]="fail"
        echo -e "${RED}[FAIL]${NC}  ${step} — see ${logf}"
        echo -e "${RED}        Last 5 lines:${NC}"
        tail -5 "$logf" | sed 's/^/        /'
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

# Tail active logs until all listed steps are done
tail_active() {
    local steps=("$@")
    local logfiles=()
    for s in "${steps[@]}"; do
        logfiles+=("$(log_file "$s")")
    done

    # Start tail in background
    tail -f "${logfiles[@]}" 2>/dev/null &
    local tail_pid=$!

    # Wait for all listed steps
    local all_done=false
    while [[ "$all_done" == "false" ]]; do
        all_done=true
        for s in "${steps[@]}"; do
            if [[ "${STEP_STATUS[$s]:-pending}" == "running" ]]; then
                all_done=false
                break
            fi
        done
        sleep 1
    done

    kill "$tail_pid" 2>/dev/null || true
    wait "$tail_pid" 2>/dev/null || true
}

# Kill all background jobs on exit
kill_bg() {
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
}
trap kill_bg EXIT

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

# Tail all active logs while both tracks run
echo -e "${CYAN}─── Live logs (both tracks) ───${NC}"
tail -f \
    "$(log_file download-iso)" \
    "$(log_file bcm-prepare)" \
    "$(log_file bcm-run)" \
    "$(log_file kairos-build)" \
    "$(log_file kairos-extract)" \
    2>/dev/null &
TAIL_PID=$!

# Wait for both tracks
TRACK_A_OK=true
TRACK_B_OK=true

if ! wait "${PIDS["track-a"]}"; then
    TRACK_A_OK=false
fi
if ! wait "${PIDS["track-b"]}"; then
    TRACK_B_OK=false
fi

kill "$TAIL_PID" 2>/dev/null || true
wait "$TAIL_PID" 2>/dev/null || true
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

# ════════════════════════════════════════════════
#  Phase 2: Deploy + Run (sequential)
# ════════════════════════════════════════════════
banner "Phase 2: Deploy + Provision"

run_step "kairos-deploy" || exit 1

echo ""
echo -e "${CYAN}─── Live log: kairos-run ───${NC}"

run_step "kairos-run" &
PIDS["kairos-run"]=$!

tail -f "$(log_file kairos-run)" 2>/dev/null &
TAIL_PID=$!

if ! wait "${PIDS["kairos-run"]}"; then
    kill "$TAIL_PID" 2>/dev/null || true
    echo -e "${RED}═══ kairos-run failed ═══${NC}"
    exit 1
fi

kill "$TAIL_PID" 2>/dev/null || true
wait "$TAIL_PID" 2>/dev/null || true

echo -e "${GREEN}═══ Phase 2 complete: Compute node provisioned ═══${NC}"

# ════════════════════════════════════════════════
#  Phase 3: Validate
# ════════════════════════════════════════════════
banner "Phase 3: Validate"
run_step "validate" || exit 1

# ════════════════════════════════════════════════
#  Summary
# ════════════════════════════════════════════════
banner "Pipeline Complete"
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
