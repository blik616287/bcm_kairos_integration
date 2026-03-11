#!/bin/bash
# orchestrate.sh — Run the full BCM + Kairos pipeline as a parallel DAG
#
# DAG:
#   download-iso → bcm-prepare → bcm-run ──┐
#                                           ├── kairos-deploy → kairos-run → validate
#   kairos-build → kairos-extract ──────────┘
#
# Steps with existing artifacts are skipped automatically.
# Use --clean to force a full rebuild from scratch.
#
# Each step logs to ./logs/orchestrate-<step>.log
# Shows a compact rolling status (last 5 lines per step, refreshing every 5s).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

LOG_DIR="./logs"
STATUS_DIR="./logs/.status"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Parse args
FORCE_CLEAN=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean) FORCE_CLEAN=true; shift ;;
        -h|--help)
            echo "Usage: $0 [--clean]"
            echo "  --clean   Force full rebuild (runs make clean-all first)"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Track background PIDs
declare -A PIDS

# ---- Status tracking (file-based, works across subshells) ----
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

# ---- Dirty file detection ----
# Maps uncommitted file changes to the steps they would invalidate.
# Populates DIRTY_STEPS associative array.
declare -A DIRTY_STEPS

detect_dirty_steps() {
    # Collect all uncommitted changes (staged, unstaged, untracked)
    local changed
    changed=$(
        git diff --name-only HEAD 2>/dev/null
        git diff --name-only --cached 2>/dev/null
        git ls-files --others --exclude-standard 2>/dev/null
    ) || true

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        case "$file" in
            src/prepare-bcm-autoinstall.sh)
                DIRTY_STEPS[bcm-prepare]=1; DIRTY_STEPS[bcm-run]=1 ;;
            src/launch-bcm-kvm.sh)
                DIRTY_STEPS[bcm-run]=1 ;;
            src/build-canvos.sh|src/canvos/*|src/canvos/**)
                DIRTY_STEPS[kairos-build]=1; DIRTY_STEPS[kairos-extract]=1 ;;
            src/extract-kairos-pxe.sh)
                DIRTY_STEPS[kairos-extract]=1 ;;
            src/test-kairos-pxe.sh)
                DIRTY_STEPS[kairos-deploy]=1; DIRTY_STEPS[kairos-run]=1 ;;
            src/validate-kairos.sh)
                DIRTY_STEPS[validate]=1 ;;
            Makefile)
                DIRTY_STEPS[bcm-prepare]=1; DIRTY_STEPS[bcm-run]=1
                DIRTY_STEPS[kairos-build]=1; DIRTY_STEPS[kairos-extract]=1
                DIRTY_STEPS[kairos-deploy]=1 ;;
            env.json)
                DIRTY_STEPS[download-iso]=1; DIRTY_STEPS[kairos-extract]=1
                DIRTY_STEPS[kairos-deploy]=1 ;;
        esac
    done <<< "$changed"
}

is_dirty() {
    [[ -n "${DIRTY_STEPS[$1]:-}" ]]
}

# Cascade: if a step is dirty, downstream build steps must also rebuild.
# bcm-run and kairos-run are live VM steps — skip if already running, never invalidated.
# validate always runs regardless.
# DAG edges (build-only cascade):
#   download-iso → bcm-prepare
#   kairos-build → kairos-extract → kairos-deploy
cascade_dirty() {
    local changed=true
    while [[ "$changed" == "true" ]]; do
        changed=false
        is_dirty "download-iso"   && [[ -z "${DIRTY_STEPS[bcm-prepare]:-}" ]]    && DIRTY_STEPS[bcm-prepare]=1    && changed=true
        is_dirty "kairos-build"   && [[ -z "${DIRTY_STEPS[kairos-extract]:-}" ]] && DIRTY_STEPS[kairos-extract]=1  && changed=true
        is_dirty "kairos-extract" && [[ -z "${DIRTY_STEPS[kairos-deploy]:-}" ]]  && DIRTY_STEPS[kairos-deploy]=1   && changed=true
        is_dirty "kairos-deploy" && [[ -z "${DIRTY_STEPS[kairos-run]:-}" ]]   && DIRTY_STEPS[kairos-run]=1      && changed=true
    done
}

# ---- Skip detection ----
# Returns 0 (true) if a step can be skipped.
# A step is skipped only if artifacts exist AND no uncommitted changes affect it.
# Exception: download-iso only checks file existence + size (never invalidated by code changes).
can_skip() {
    local step="$1"

    # If files that affect this step have changed, force re-run
    # Exceptions: download-iso (checked by sha256), bcm-run/kairos-run (live VM state),
    #             validate (always runs)
    if [[ "$step" != "download-iso" && "$step" != "bcm-run" && "$step" != "validate" ]] && is_dirty "$step"; then
        return 1
    fi

    case "$step" in
        download-iso)
            # Skip if ISO exists and sha256 matches JFrog
            if [[ -f "dist/${ISO_FILENAME}" ]]; then
                if [[ -n "$ISO_REMOTE_SHA256" ]]; then
                    local local_sha256
                    local_sha256=$(sha256sum "dist/${ISO_FILENAME}" 2>/dev/null | awk '{print $1}')
                    [[ "$local_sha256" == "$ISO_REMOTE_SHA256" ]]
                else
                    # No remote checksum available — skip if file is non-trivial size
                    local actual_size
                    actual_size=$(stat -c%s "dist/${ISO_FILENAME}" 2>/dev/null || echo 0)
                    [[ "$actual_size" -gt 104857600 ]]
                fi
            else
                return 1
            fi
            ;;
        bcm-prepare)
            [[ -f "build/.bcm-kernel" ]] && [[ -f "build/.bcm-rootfs-auto.cgz" ]] && [[ -f "build/.bcm-init.img" ]]
            ;;
        bcm-run)
            # Skip if disk exists AND BCM VM is already SSH-reachable
            if [[ -f "build/bcm-disk.qcow2" ]]; then
                if [[ -f "build/.bcm-qemu.pid" ]] && kill -0 "$(cat build/.bcm-qemu.pid 2>/dev/null)" 2>/dev/null; then
                    sshpass -p "${BCM_PASSWORD:-}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                        -o LogLevel=ERROR -o ConnectTimeout=3 -p 10022 root@localhost "echo ok" >/dev/null 2>&1
                    return $?
                fi
                return 1
            fi
            return 1
            ;;
        kairos-build)
            [[ -f "build/palette-edge-installer.iso" ]]
            ;;
        kairos-extract)
            [[ -d "build/pxe" ]] && [[ -f "build/pxe/rootfs.squashfs" ]] && [[ -f "build/pxe/vmlinuz" ]] && [[ -f "build/pxe/user-data.yaml" ]]
            ;;
        kairos-run)
            # Skip if VM is already running and SSH-reachable via BCM
            if [[ -f "build/.kairos-qemu.pid" ]] && kill -0 "$(cat build/.kairos-qemu.pid 2>/dev/null)" 2>/dev/null; then
                return 0
            fi
            return 1
            ;;
        kairos-deploy|validate)
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

# Run a make target, or skip if artifacts exist.
run_step() {
    local step="$1"
    local logf
    logf=$(log_file "$step")

    # Check if we can skip
    if can_skip "$step"; then
        set_status "$step" "skipped"
        echo "Skipped: artifacts already present" > "$logf"
        return 0
    fi

    > "$logf"
    set_status "$step" "running"

    # Special case: if bcm-run can be replaced with bcm-start (disk exists, VM not running)
    if [[ "$step" == "bcm-run" ]] && [[ -f "build/bcm-disk.qcow2" ]]; then
        make bcm-start > "$logf" 2>&1
    else
        make "$step" > "$logf" 2>&1
    fi
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
        [[ "$status" == "skipped" ]] && icon="⏭️ "
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
        elif [[ "$status" == "skipped" ]]; then
            echo -e "  ${icon} ${BOLD}${s}${NC} [${status}]"
        else
            echo -e "  ${icon} ${BOLD}${s}${NC} [${status}]"
        fi

        if [[ "$status" == "running" ]] && [[ -s "$logf" ]]; then
            tail -n 5 "$logf" 2>/dev/null | cut -c1-80 | sed 's/^/     │ /'
        fi
    done
}

# ---- Cleanup on exit ----
cleanup() {
    local exit_code=$?
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

# ---- Read config ----
ISO_FILENAME=$(jq -r '.iso_filename // "bcm-11.0-ubuntu2404.iso"' env.json 2>/dev/null || echo "bcm-11.0-ubuntu2404.iso")
JFROG_INSTANCE=$(jq -r '.jfrog_instance // "insightsoftmax.jfrog.io"' env.json 2>/dev/null || echo "insightsoftmax.jfrog.io")
JFROG_REPO=$(jq -r '.jfrog_repo // "iso-releases"' env.json 2>/dev/null || echo "iso-releases")
JFROG_TOKEN=$(jq -r '.jfrog_token // empty' env.json 2>/dev/null || true)
BCM_PASSWORD=$(jq -r '.bcm_password // empty' env.json 2>/dev/null || true)

# Get ISO metadata from JFrog (size + sha256) for skip detection and download progress
ISO_TOTAL_MB=0
ISO_REMOTE_SHA256=""
if [[ -n "$JFROG_TOKEN" ]]; then
    # JFrog storage API returns checksums and size
    ISO_INFO=$(curl --silent --fail \
        -H "Authorization: Bearer ${JFROG_TOKEN}" \
        "https://${JFROG_INSTANCE}/artifactory/api/storage/${JFROG_REPO}/${ISO_FILENAME}" 2>/dev/null || true)
    if [[ -n "$ISO_INFO" ]]; then
        ISO_TOTAL_BYTES=$(echo "$ISO_INFO" | jq -r '.size // empty' 2>/dev/null || true)
        ISO_REMOTE_SHA256=$(echo "$ISO_INFO" | jq -r '.checksums.sha256 // empty' 2>/dev/null || true)
        if [[ -n "$ISO_TOTAL_BYTES" && "$ISO_TOTAL_BYTES" -gt 0 ]] 2>/dev/null; then
            ISO_TOTAL_MB=$(( ISO_TOTAL_BYTES / 1048576 ))
        fi
    fi
fi

# All pipeline steps
ALL_STEPS=("download-iso" "bcm-prepare" "bcm-run" "kairos-build" "kairos-extract" "kairos-deploy" "kairos-run" "validate")

# ---- Initialize ----
mkdir -p "$LOG_DIR" "$STATUS_DIR"

# Clear old status files and orchestrate logs
rm -rf "$STATUS_DIR"
mkdir -p "$STATUS_DIR"
for s in "${ALL_STEPS[@]}"; do
    rm -f "$(log_file "$s")"
done

# Set initial statuses
for s in "${ALL_STEPS[@]}"; do
    set_status "$s" "pending"
done
set_status "kairos-deploy" "blocked"
set_status "kairos-run" "blocked"
set_status "validate" "blocked"

# ════════════════════════════════════════════════
#  Phase 0: Clean (optional)
# ════════════════════════════════════════════════
if [[ "$FORCE_CLEAN" == "true" ]]; then
    banner "Phase 0: Clean slate"
    make clean-all > "$(log_file clean-all)" 2>&1
    echo -e "${GREEN}[DONE]${NC} clean-all"
fi

# ---- Detect uncommitted changes ----
detect_dirty_steps
cascade_dirty

# ---- Pre-flight skip detection ----
banner "Checking existing artifacts"

# Show dirty files if any
if [[ ${#DIRTY_STEPS[@]} -gt 0 ]]; then
    echo -e "${YELLOW}Uncommitted changes detected affecting:${NC}"
    for s in "${!DIRTY_STEPS[@]}"; do
        echo -e "  ${YELLOW}→ ${s}${NC} (will rebuild)"
    done
    echo ""
fi

SKIPPABLE=0
for s in "${ALL_STEPS[@]}"; do
    if can_skip "$s"; then
        echo -e "  ⏭️  ${CYAN}${s}${NC} — skip (artifacts present, no changes)"
        SKIPPABLE=$((SKIPPABLE + 1))
    elif is_dirty "$s" && [[ "$s" != "download-iso" ]]; then
        echo -e "  🔄 ${YELLOW}${s}${NC} — rebuild (uncommitted changes)"
    else
        echo -e "  ⏳ ${s} — needs to run"
    fi
done
echo ""
if [[ $SKIPPABLE -gt 0 ]]; then
    echo -e "Skipping ${SKIPPABLE} step(s). Use --clean to force full rebuild."
fi

# Clean artifacts for dirty steps so they rebuild cleanly
for s in "${!DIRTY_STEPS[@]}"; do
    case "$s" in
        bcm-prepare)
            rm -f build/.bcm-kernel build/.bcm-rootfs-auto.cgz build/.bcm-init.img ;;
        bcm-run)
            # Don't delete disk — bcm-run will handle reinstall vs restart
            ;;
        kairos-build)
            rm -f build/palette-edge-installer.iso ;;
        kairos-extract)
            rm -rf build/pxe/ ;;
    esac
done

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

echo -e "${GREEN}═══ Phase 1 complete ═══${NC}"
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

echo -e "${GREEN}═══ Phase 2 complete ═══${NC}"
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
#  Report
# ════════════════════════════════════════════════
banner "Pipeline Complete"
show_status "${ALL_STEPS[@]}"
echo ""
echo -e "${GREEN} All steps passed.${NC}"
echo ""

echo -e "${BOLD}── Report ──${NC}"
echo ""

# Step durations
echo -e "${BOLD} Step Durations:${NC}"
for s in "${ALL_STEPS[@]}"; do
    logf=$(log_file "$s")
    status=$(get_status "$s")
    if [[ "$status" == "skipped" ]]; then
        printf "   %-20s skipped\n" "$s"
    elif [[ -f "$logf" ]]; then
        start_ts=$(stat -c%W "$logf" 2>/dev/null || echo 0)
        end_ts=$(stat -c%Y "$logf" 2>/dev/null || echo 0)
        if [[ "$start_ts" -gt 0 && "$end_ts" -gt 0 && "$end_ts" -ge "$start_ts" ]]; then
            duration_s=$(( end_ts - start_ts ))
            printf "   %-20s %dm%02ds\n" "$s" $((duration_s / 60)) $((duration_s % 60))
        else
            printf "   %-20s --\n" "$s"
        fi
    fi
done
echo ""

# Artifacts
echo -e "${BOLD} Artifacts:${NC}"
if [[ -f "dist/${ISO_FILENAME}" ]]; then
    echo "   BCM ISO:          dist/${ISO_FILENAME} ($(du -h "dist/${ISO_FILENAME}" | cut -f1))"
fi
if [[ -f "build/bcm-disk.qcow2" ]]; then
    echo "   BCM disk:         build/bcm-disk.qcow2 ($(du -h "build/bcm-disk.qcow2" | cut -f1))"
fi
if [[ -f "build/compute-node-disk.qcow2" ]]; then
    echo "   Compute disk:     build/compute-node-disk.qcow2 ($(du -h "build/compute-node-disk.qcow2" | cut -f1))"
fi
if [[ -d "build/pxe" ]]; then
    echo "   PXE artifacts:    build/pxe/ ($(du -sh "build/pxe" | cut -f1))"
fi
echo ""

# VM status
echo -e "${BOLD} VMs Running:${NC}"
if [[ -f "build/.bcm-qemu.pid" ]] && kill -0 "$(cat build/.bcm-qemu.pid 2>/dev/null)" 2>/dev/null; then
    echo "   BCM head node:    localhost:10022 (SSH), localhost:10443 (HTTPS)"
else
    echo "   BCM head node:    not running"
fi
if [[ -f "build/.kairos-qemu.pid" ]] && kill -0 "$(cat build/.kairos-qemu.pid 2>/dev/null)" 2>/dev/null; then
    echo "   Kairos compute:   running (via BCM internal network)"
else
    echo "   Kairos compute:   not running"
fi
echo ""

# Validation summary
validate_log=$(log_file "validate")
if [[ -f "$validate_log" ]]; then
    echo -e "${BOLD} Validation Summary:${NC}"
    grep -E "^\s*(PASS|WARN|FAIL|Result):" "$validate_log" 2>/dev/null | sed 's/^/   /' || true
    echo ""
fi

# Logs
echo -e "${BOLD} Logs:${NC}"
for f in "$LOG_DIR"/orchestrate-*.log; do
    [[ -f "$f" ]] || continue
    step=$(basename "$f" .log | sed 's/orchestrate-//')
    size=$(du -h "$f" | cut -f1)
    echo "   ${step}: ${f} (${size})"
done
echo ""

echo " To tear down:"
echo "   make kairos-stop && make bcm-stop"
