#!/bin/bash
#
# Full Test Suite Runner with Network Emulation
# Runs all scenarios across all profiles with pcap capture and full report generation
#
# Run natively on Linux:
#   cd aitestbed
#   bash run_full_tests.sh --quick
#
# Requires: sudo access for tc/netem, Python venv with dependencies installed.
#

set -e

# Load environment variables from .env if it exists
if [[ -f ".env" ]]; then
    set -a
    source .env
    set +a
fi

# Configuration
RUNS_PER_SCENARIO=${RUNS_PER_SCENARIO:-10}
INTER_SCENARIO_DELAY=${INTER_SCENARIO_DELAY:-2}  # Seconds between scenarios
INTER_PROVIDER_DELAY=${INTER_PROVIDER_DELAY:-5}  # Seconds between providers
TRACE_PAYLOADS=${TRACE_PAYLOADS:-1}
TRACE_LOG_DIR=${TRACE_LOG_DIR:-logs/traces}
CAPTURE_PCAP=${CAPTURE_PCAP:-true}  # Enable L3/L4 packet capture by default
CAPTURE_DIR=${CAPTURE_DIR:-results/captures}
CAPTURE_FILTER=${CAPTURE_FILTER:-"port 443 or port 80 or port 8080 or port 8000"}  # HTTPS, HTTP, proxy, and vLLM
CAPTURE_LOOPBACK=${CAPTURE_LOOPBACK:-true}  # Secondary tcpdump on lo for MCP-over-HTTP frames
MCP_TRANSPORT=${MCP_TRANSPORT:-http}  # MCP server transport: http (default, netem-shaped) or stdio
ANONYMIZE_DB=${ANONYMIZE_DB:-true}  # Anonymize provider/model names by default
CLEAN_START=${CLEAN_START:-true}  # Start from a clean database by default
NETWORK_INTERFACE=${NETWORK_INTERFACE:-auto}  # Network interface for emulation + capture (auto = detect)
RUN_TIMEOUT_SEC=${RUN_TIMEOUT_SEC:-600}  # Per-run timeout in seconds (0 = no timeout). 600s = head-room for streaming multi-prompt chat (deepseek-coder, deepseek-reasoner).
STOP_ON_ERROR=${STOP_ON_ERROR:-true}  # Stop on first failed run (default: true)
RESUME_MODE=${RESUME_MODE:-false}  # Resume from last successful run
QUIET_MODE=${QUIET_MODE:-true}  # Show progress bar instead of verbose output

export TRACE_PAYLOADS TRACE_LOG_DIR

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { [[ "$QUIET_MODE" == "true" ]] && return; echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_phase() { [[ "$QUIET_MODE" == "true" ]] && return; echo -e "\n${BLUE}════════════════════════════════════════${NC}"; echo -e "${BLUE}  $1${NC}"; echo -e "${BLUE}════════════════════════════════════════${NC}"; }

# Progress bar state
PROGRESS_DONE=0
PROGRESS_TOTAL=0

progress_bar() {
    # Usage: progress_bar <done> <total> <label>
    local done=$1 total=$2 label=$3
    local cols=${COLUMNS:-80}
    local pct=0
    if [[ "$total" -gt 0 ]]; then
        pct=$((done * 100 / total))
    fi

    # Build bar
    local bar_width=$((cols - 20))
    [[ "$bar_width" -lt 10 ]] && bar_width=10
    [[ "$bar_width" -gt 60 ]] && bar_width=60
    local filled=$((bar_width * done / (total > 0 ? total : 1)))
    local empty=$((bar_width - filled))
    local bar=$(printf '%0.s█' $(seq 1 "$filled" 2>/dev/null))
    local space=$(printf '%0.s ' $(seq 1 "$empty" 2>/dev/null))

    # Truncate label to fit
    local max_label=$((cols - bar_width - 12))
    [[ "$max_label" -lt 10 ]] && max_label=10
    if [[ ${#label} -gt $max_label ]]; then
        label="${label:0:$((max_label - 3))}..."
    fi

    printf '\r\033[K%3d%%|%s%s| %s' "$pct" "$bar" "$space" "$label"
}

record_scenario_failure() {
    local scenario=$1
    local detail=$2
    local logfile=$3
    FAILED_SCENARIOS+=("$scenario")
    FAILED_DETAILS+=("$detail")
    FAILED_LOGS+=("$logfile")
}

# Phase toggle: comma-separated lists. Empty = no filter.
ENABLED_PHASES=""
DISABLED_PHASES=""

# Feature flags for optional scenarios
HAS_GOOGLE_API=false
HAS_PLAYWRIGHT=false
HAS_MULTIMODAL_IMAGES=false
HAS_SPOTIFY=false
HAS_ALPACA=false
HAS_VLLM=false
RUN_STRESS_TESTS=false

# vLLM lifecycle. When MANAGE_VLLM=true (default), this script starts vllm
# before the vllm phase and stops it on exit (including INT/TERM/error).
# Set MANAGE_VLLM=false to skip auto-management — useful when an operator
# already runs a long-lived vllm server independently and the script should
# only probe reachability. The managed server stays loaded across the whole
# run; if one is already up at ${VLLM_HOST}:${VLLM_PORT}, it is reused.
#
# VLLM_BACKEND selects how the server is launched:
#   docker (default)  — runs vllm/vllm-openai container; needs docker + nvidia-container-toolkit
#   host              — spawns `vllm serve` directly; needs `vllm` on PATH and working CUDA
MANAGE_VLLM=${MANAGE_VLLM:-true}
VLLM_BACKEND=${VLLM_BACKEND:-docker}
VLLM_MODEL=${VLLM_MODEL:-Qwen/Qwen3-VL-30B-A3B-Instruct}
VLLM_HOST=${VLLM_HOST:-127.0.0.1}
VLLM_PORT=${VLLM_PORT:-8000}
VLLM_GPU_MEM_UTIL=${VLLM_GPU_MEM_UTIL:-0.95}
VLLM_MAX_MODEL_LEN=${VLLM_MAX_MODEL_LEN:-32768}  # 32K context. 128K OOMs KV-cache on single-GPU boxes.
VLLM_EXTRA_ARGS=${VLLM_EXTRA_ARGS:---trust-remote-code --tensor-parallel-size 1}
VLLM_LOG=${VLLM_LOG:-logs/vllm_server.log}
VLLM_PID_FILE=${VLLM_PID_FILE:-logs/vllm_server.pid}
VLLM_STARTUP_TIMEOUT_SEC=${VLLM_STARTUP_TIMEOUT_SEC:-600}
VLLM_SHUTDOWN_TIMEOUT_SEC=${VLLM_SHUTDOWN_TIMEOUT_SEC:-30}
VLLM_STARTED_BY_US=false
# Docker backend knobs
VLLM_IMAGE=${VLLM_IMAGE:-vllm/vllm-openai:latest}
VLLM_CONTAINER_NAME=${VLLM_CONTAINER_NAME:-vllm-testbed}
VLLM_HF_CACHE=${VLLM_HF_CACHE:-$HOME/.cache/huggingface}

ALL_PROFILES=()
TEST_MATRIX_ENTRIES=()
FAILED_SCENARIOS=()
FAILED_DETAILS=()
FAILED_LOGS=()
LAST_INTERFACE=""

# ---------------------------------------------------------------------------
# Phase toggle helper
# ---------------------------------------------------------------------------
phase_enabled() {
    local phase=$1
    # --enable takes precedence: only listed phases run
    if [[ -n "$ENABLED_PHASES" ]]; then
        [[ ",$ENABLED_PHASES," == *",$phase,"* ]] && return 0 || return 1
    fi
    # --disable: listed phases are skipped
    if [[ -n "$DISABLED_PHASES" ]]; then
        [[ ",$DISABLED_PHASES," == *",$phase,"* ]] && return 1 || return 0
    fi
    return 0
}

# Check optional prerequisites
check_optional_prereqs() {
    log_info "Checking optional prerequisites..."

    # Check Google Search API
    if [[ -n "${GOOGLE_SEARCH_API_KEY:-}" && -n "${GOOGLE_SEARCH_CX:-}" ]]; then
        HAS_GOOGLE_API=true
        log_info "  + Google Search API configured"
    else
        log_warn "  - Google Search API not configured (set GOOGLE_SEARCH_API_KEY and GOOGLE_SEARCH_CX)"
    fi

    # Check Playwright
    if python -c "import playwright" 2>/dev/null; then
        if python -c "from playwright.sync_api import sync_playwright; p = sync_playwright().start(); b = p.chromium.launch(headless=True); b.close(); p.stop()" 2>/dev/null; then
            HAS_PLAYWRIGHT=true
            log_info "  + Playwright with Chromium ready"
        else
            log_warn "  - Playwright installed but Chromium missing (run: playwright install chromium)"
        fi
    else
        log_warn "  - Playwright not installed (run: pip install playwright && playwright install chromium)"
    fi

    # Check multimodal image files
    if [[ -f "examples/assets/network_diagram.png" ]]; then
        HAS_MULTIMODAL_IMAGES=true
        log_info "  + Multimodal test images found"
    else
        log_warn "  - Multimodal test images not found (examples/assets/network_diagram.png)"
    fi

    # Check Spotify
    if [[ -n "${SPOTIFY_CLIENT_ID:-}" && -n "${SPOTIFY_CLIENT_SECRET:-}" ]]; then
        HAS_SPOTIFY=true
        log_info "  + Spotify API configured"
    else
        log_warn "  - Spotify API not configured (set SPOTIFY_CLIENT_ID and SPOTIFY_CLIENT_SECRET)"
    fi

    # Check Alpaca Market Data
    if [[ -n "${ALPACA_API_KEY:-}" && -n "${ALPACA_SECRET_KEY:-}" ]]; then
        HAS_ALPACA=true
        log_info "  + Alpaca Market Data API configured"
    else
        log_warn "  - Alpaca not configured (set ALPACA_API_KEY and ALPACA_SECRET_KEY)"
    fi

    # Check vLLM server
    if vllm_reachable; then
        HAS_VLLM=true
        log_info "  + vLLM server reachable at ${VLLM_HOST}:${VLLM_PORT}"
    else
        log_warn "  - vLLM server not reachable at ${VLLM_HOST}:${VLLM_PORT}"
        if [[ "$MANAGE_VLLM" == "true" ]]; then
            # Auto-management is on but the server didn't come up — most
            # likely the vllm phase is disabled, so start_vllm_server was
            # skipped. vllm scenarios will be skipped by the prereq check.
            log_warn "    (MANAGE_VLLM=true but the vllm phase is disabled, so no server was started)"
        else
            log_warn "    Start it manually (vllm serve ${VLLM_MODEL} --host ${VLLM_HOST} --port ${VLLM_PORT} ...)"
            log_warn "    or unset MANAGE_VLLM=false to let this script auto-start it"
        fi
    fi

    log_warn "  - Azure scenarios disabled in this runner"

    echo ""
}

phase_explicitly_enabled() {
    local phase=$1
    [[ -n "$ENABLED_PHASES" && ",$ENABLED_PHASES," == *",$phase,"* ]]
}

phase_title() {
    case "$1" in
        chat) echo "PHASE 1: OpenAI Chat Scenarios" ;;
        realtime) echo "PHASE 2: OpenAI Realtime Scenarios (latency-sensitive)" ;;
        image) echo "PHASE 3: OpenAI Image Generation (bandwidth-sensitive)" ;;
        search) echo "PHASE 4: Direct Web Search Scenarios" ;;
        deepseek) echo "PHASE 5: DeepSeek Scenarios" ;;
        gemini) echo "PHASE 6: Gemini Scenarios" ;;
        music) echo "PHASE 7: Music Agent Scenarios (Spotify MCP)" ;;
        trading) echo "PHASE 7b: Trading / Market Data Scenarios (Alpaca MCP)" ;;
        computer_use) echo "PHASE 8: Computer Use Scenarios" ;;
        playwright) echo "PHASE 8b: Playwright MCP Browser Automation" ;;
        multimodal) echo "PHASE 9: Multimodal Scenarios" ;;
        google_search) echo "PHASE 10: Alternative Search Engines" ;;
        stress) echo "PHASE 11: Stress Tests (Optional)" ;;
        vllm) echo "PHASE 12: vLLM Local Inference Scenarios" ;;
        *) echo "PHASE: $1" ;;
    esac
}

load_test_matrix() {
    log_info "Loading test matrix from configs/scenarios.yaml..."
    mapfile -t TEST_MATRIX_ENTRIES < <(
        python - <<'PY'
import yaml
from pathlib import Path

config = yaml.safe_load(Path("configs/scenarios.yaml").read_text())
scenarios = config.get("scenarios") or {}
matrix = config.get("test_matrix") or []

for entry in matrix:
    scenario_name = entry["scenario"]
    scenario_def = scenarios.get(scenario_name, {})
    fields = [
        entry.get("phase", ""),
        scenario_name,
        "true" if entry.get("runner_enabled_by_default", True) else "false",
        "true" if scenario_def.get("disabled", False) else "false",
        ",".join(entry.get("profiles", [])),
        ",".join(entry.get("prereqs", [])),
    ]
    print("\t".join(fields))
PY
    )

    if [[ ${#TEST_MATRIX_ENTRIES[@]} -eq 0 ]]; then
        log_error "No test-matrix entries loaded from configs/scenarios.yaml"
        exit 1
    fi

    mapfile -t ALL_PROFILES < <(
        python - <<'PY'
import yaml
from pathlib import Path

config = yaml.safe_load(Path("configs/scenarios.yaml").read_text())
seen = []
for entry in config.get("test_matrix") or []:
    for profile in entry.get("profiles", []):
        if profile not in seen:
            seen.append(profile)
for profile in seen:
    print(profile)
PY
    )

    log_info "Loaded ${#TEST_MATRIX_ENTRIES[@]} matrix entries across ${#ALL_PROFILES[@]} profiles: ${ALL_PROFILES[*]}"

    # Count total runnable combos for progress tracking
    PROGRESS_TOTAL=0
    for entry in "${TEST_MATRIX_ENTRIES[@]}"; do
        local _phase _scenario _runner_enabled _scenario_disabled _profiles_csv _prereqs_csv
        IFS=$'\t' read -r _phase _scenario _runner_enabled _scenario_disabled _profiles_csv _prereqs_csv <<< "$entry"
        local _skip
        _skip=$(entry_skip_reason "$_phase" "$_scenario" "$_runner_enabled" "$_scenario_disabled" "$_prereqs_csv" || true)
        if [[ -z "$_skip" ]] && phase_enabled "$_phase"; then
            IFS=',' read -r -a _profiles <<< "$_profiles_csv"
            PROGRESS_TOTAL=$(( PROGRESS_TOTAL + ${#_profiles[@]} ))
        fi
    done
    PROGRESS_DONE=0
}

# Filter out already-completed scenario/profile combos from the test matrix.
# Only useful in resume mode — queries the DB once up front so the main loop
# never even sees entries that have nothing left to run.
filter_completed_from_matrix() {
    local db="logs/traffic_logs.db"
    if [[ ! -f "$db" ]]; then
        return
    fi

    local original_count=${#TEST_MATRIX_ENTRIES[@]}
    local filtered=()

    # Build a lookup of completed counts: "scenario|profile" -> count
    # Single DB query for all combos.
    declare -A completed_counts
    while IFS=$'\t' read -r scenario profile count; do
        completed_counts["${scenario}|${profile}"]=$count
    done < <(
        python - "$db" "$RUNS_PER_SCENARIO" <<'PY'
import sqlite3, sys

db_path, runs_needed = sys.argv[1], int(sys.argv[2])
try:
    conn = sqlite3.connect(db_path)
    rows = conn.execute("""
        SELECT scenario_id, network_profile, COUNT(DISTINCT session_id)
        FROM traffic_logs
        WHERE session_id NOT LIKE 'pcap_%'
          AND (
              session_id LIKE 'timeout_%'
              OR session_id NOT IN (
                  SELECT DISTINCT session_id FROM traffic_logs
                  WHERE success = 0
              )
          )
        GROUP BY scenario_id, network_profile
    """).fetchall()
    for scenario, profile, count in rows:
        print(f"{scenario}\t{profile}\t{count}")
except Exception:
    pass
PY
    )

    local skipped_combos=0
    local skipped_entries=0

    for entry in "${TEST_MATRIX_ENTRIES[@]}"; do
        local phase scenario runner_enabled scenario_disabled profiles_csv prereqs_csv
        IFS=$'\t' read -r phase scenario runner_enabled scenario_disabled profiles_csv prereqs_csv <<< "$entry"

        IFS=',' read -r -a profiles <<< "$profiles_csv"
        local remaining=()
        for profile in "${profiles[@]}"; do
            local key="${scenario}|${profile}"
            local done=${completed_counts[$key]:-0}
            if [[ "$done" -ge "$RUNS_PER_SCENARIO" ]]; then
                skipped_combos=$(( skipped_combos + 1 ))
            else
                remaining+=("$profile")
            fi
        done

        if [[ ${#remaining[@]} -eq 0 ]]; then
            skipped_entries=$(( skipped_entries + 1 ))
            continue
        fi

        # Rebuild entry with only the remaining profiles
        local new_profiles_csv
        new_profiles_csv=$(IFS=','; echo "${remaining[*]}")
        filtered+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s' \
            "$phase" "$scenario" "$runner_enabled" "$scenario_disabled" \
            "$new_profiles_csv" "$prereqs_csv")")
    done

    TEST_MATRIX_ENTRIES=("${filtered[@]}")

    # Recount progress total
    PROGRESS_TOTAL=0
    for entry in "${TEST_MATRIX_ENTRIES[@]}"; do
        local _phase _scenario _runner_enabled _scenario_disabled _profiles_csv _prereqs_csv
        IFS=$'\t' read -r _phase _scenario _runner_enabled _scenario_disabled _profiles_csv _prereqs_csv <<< "$entry"
        local _skip
        _skip=$(entry_skip_reason "$_phase" "$_scenario" "$_runner_enabled" "$_scenario_disabled" "$_prereqs_csv" || true)
        if [[ -z "$_skip" ]] && phase_enabled "$_phase"; then
            IFS=',' read -r -a _profiles <<< "$_profiles_csv"
            PROGRESS_TOTAL=$(( PROGRESS_TOTAL + ${#_profiles[@]} ))
        fi
    done

    if [[ "$skipped_combos" -gt 0 ]]; then
        log_info "Resume: $skipped_combos scenario/profile combos already completed, $skipped_entries entries fully done"
        log_info "Resume: ${#TEST_MATRIX_ENTRIES[@]} entries remaining (from $original_count)"
    fi
}

# Check sudo access for tc
check_sudo() {
    log_info "Checking sudo access for network emulation..."
    if sudo -n tc qdisc show dev lo &>/dev/null; then
        log_info "sudo access for tc confirmed (passwordless)"
        return 0
    else
        log_error "Cannot run tc commands without passwordless sudo."
        log_warn "To fix: echo '$USER ALL=(ALL) NOPASSWD: /sbin/tc, /usr/sbin/tc' | sudo tee /etc/sudoers.d/tc-netem"
        log_warn "Continuing without network emulation..."
        return 1
    fi
}

cleanup_network_state() {
    local interface=${1:-}
    local ifb_device=${IFB_DEVICE:-ifb0}

    if [[ -n "$interface" && "$interface" != "auto" ]]; then
        sudo tc qdisc del dev "$interface" root >/dev/null 2>&1 || true
        sudo tc qdisc del dev "$interface" ingress >/dev/null 2>&1 || true
    fi

    sudo tc qdisc del dev lo root >/dev/null 2>&1 || true
    sudo tc qdisc del dev lo ingress >/dev/null 2>&1 || true
    sudo tc qdisc del dev "$ifb_device" root >/dev/null 2>&1 || true
    sudo ip link set dev "$ifb_device" down >/dev/null 2>&1 || true
}

cleanup_on_exit() {
    # vLLM teardown first — kill the server before tearing down lo qdiscs
    # so its workers see a clean loopback during shutdown.
    stop_vllm_server || true
    cleanup_network_state "${LAST_INTERFACE:-}"
}

# ---------------------------------------------------------------------------
# vLLM server lifecycle
# ---------------------------------------------------------------------------
#
# vllm scenarios target http://${VLLM_HOST}:${VLLM_PORT} on the loopback
# interface. The orchestrator applies tc/netem to lo *per scenario* via the
# scenarios.yaml `network_interface: lo` setting, so the server itself sees
# unshaped lo at startup/shutdown — netem only kicks in while a scenario
# runs. We therefore clear lo before launching vllm to make sure no stale
# qdisc from a prior crashed run interferes with model load.

vllm_reachable() {
    curl -sf "http://${VLLM_HOST}:${VLLM_PORT}/v1/models" > /dev/null 2>&1
}

start_vllm_server() {
    # No-op when not in managed mode.
    if [[ "$MANAGE_VLLM" != "true" ]]; then
        return 0
    fi

    # If something is already serving on the port, reuse it. The operator may
    # have started it themselves and forgotten to unset MANAGE_VLLM.
    if vllm_reachable; then
        log_info "vLLM already reachable at ${VLLM_HOST}:${VLLM_PORT} — reusing existing server"
        HAS_VLLM=true
        return 0
    fi

    case "$VLLM_BACKEND" in
        docker) _start_vllm_docker ;;
        host)   _start_vllm_host   ;;
        *)
            log_error "Unknown VLLM_BACKEND=${VLLM_BACKEND} (expected: docker|host)"
            return 1
            ;;
    esac
}

_start_vllm_host() {
    if ! command -v vllm > /dev/null 2>&1; then
        log_error "VLLM_BACKEND=host but 'vllm' is not on PATH (pip install vllm)"
        return 1
    fi

    # Make sure lo is unshaped before vllm initializes its sockets.
    sudo tc qdisc del dev lo root    >/dev/null 2>&1 || true
    sudo tc qdisc del dev lo ingress >/dev/null 2>&1 || true

    mkdir -p "$(dirname "$VLLM_LOG")"
    : > "$VLLM_LOG"

    log_info "Starting vLLM (host): model=${VLLM_MODEL} host=${VLLM_HOST} port=${VLLM_PORT}"
    log_info "  log: $VLLM_LOG  (timeout ${VLLM_STARTUP_TIMEOUT_SEC}s for model load)"

    # setsid puts vllm in its own process group so we can SIGTERM the whole
    # tree (vllm spawns worker procs) on shutdown.
    setsid vllm serve "$VLLM_MODEL" \
        --host "$VLLM_HOST" \
        --port "$VLLM_PORT" \
        --gpu-memory-utilization "$VLLM_GPU_MEM_UTIL" \
        --max-model-len "$VLLM_MAX_MODEL_LEN" \
        $VLLM_EXTRA_ARGS \
        > "$VLLM_LOG" 2>&1 &
    local pid=$!
    echo "$pid" > "$VLLM_PID_FILE"
    VLLM_STARTED_BY_US=true

    local waited=0
    while (( waited < VLLM_STARTUP_TIMEOUT_SEC )); do
        if ! kill -0 "$pid" 2>/dev/null; then
            log_error "vLLM exited during startup (pid $pid). Tail of $VLLM_LOG:"
            tail -n 40 "$VLLM_LOG" | sed 's/^/    /' >&2 || true
            rm -f "$VLLM_PID_FILE"
            VLLM_STARTED_BY_US=false
            return 1
        fi
        if vllm_reachable; then
            log_info "vLLM ready at ${VLLM_HOST}:${VLLM_PORT} (pid $pid, ${waited}s)"
            HAS_VLLM=true
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
        if (( waited % 30 == 0 )); then
            log_info "  still waiting for vLLM (${waited}s / ${VLLM_STARTUP_TIMEOUT_SEC}s)..."
        fi
    done

    log_error "vLLM did not become ready within ${VLLM_STARTUP_TIMEOUT_SEC}s. Tail of $VLLM_LOG:"
    tail -n 40 "$VLLM_LOG" | sed 's/^/    /' >&2 || true
    stop_vllm_server || true
    return 1
}

_start_vllm_docker() {
    # Preflight
    if ! command -v docker > /dev/null 2>&1; then
        log_error "VLLM_BACKEND=docker but 'docker' is not on PATH"
        return 1
    fi
    if ! docker info > /dev/null 2>&1; then
        log_error "Cannot access the Docker daemon (is it running? are you in the 'docker' group?)"
        log_error "  Fix: sudo usermod -aG docker \$USER && newgrp docker"
        return 1
    fi

    # Adopt or clean up any existing container with the same name.
    local existing_status
    existing_status=$(docker inspect -f '{{.State.Status}}' "$VLLM_CONTAINER_NAME" 2>/dev/null || echo "")
    if [[ "$existing_status" == "running" ]]; then
        log_info "Adopting already-running container '${VLLM_CONTAINER_NAME}'"
        VLLM_STARTED_BY_US=true
    elif [[ -n "$existing_status" ]]; then
        log_info "Removing stale container '${VLLM_CONTAINER_NAME}' (status=${existing_status})"
        docker rm -f "$VLLM_CONTAINER_NAME" > /dev/null 2>&1 || true
        existing_status=""
    fi

    if [[ "$existing_status" != "running" ]]; then
        # Unshape lo before container-side socket setup.
        sudo tc qdisc del dev lo root    >/dev/null 2>&1 || true
        sudo tc qdisc del dev lo ingress >/dev/null 2>&1 || true

        mkdir -p "$(dirname "$VLLM_LOG")"
        : > "$VLLM_LOG"

        # Ensure the HF cache mount target exists on the host — docker will
        # create it if missing, but if your Docker install is rootless or
        # the parent perms are odd the mount will fail silently.
        mkdir -p "$VLLM_HF_CACHE" 2>/dev/null || true

        log_info "Starting vLLM (docker): image=${VLLM_IMAGE} name=${VLLM_CONTAINER_NAME}"
        log_info "  model=${VLLM_MODEL}  bind=${VLLM_HOST}:${VLLM_PORT}  HF cache=${VLLM_HF_CACHE}"
        log_info "  log: $VLLM_LOG  (timeout ${VLLM_STARTUP_TIMEOUT_SEC}s for model load)"

        # Capture stdout (container ID) and stderr (errors / image-pull progress)
        # separately, and mirror stderr to $VLLM_LOG so pull/config errors are
        # visible instead of scrolling off.
        local _stderr_file cid rc
        _stderr_file=$(mktemp -t vllm-run-err.XXXXXX)
        cid=$(docker run -d --name "$VLLM_CONTAINER_NAME" \
                --gpus all --ipc=host \
                -v "${VLLM_HF_CACHE}:/root/.cache/huggingface" \
                -p "${VLLM_HOST}:${VLLM_PORT}:8000" \
                "$VLLM_IMAGE" \
                --model "$VLLM_MODEL" \
                --max-model-len "$VLLM_MAX_MODEL_LEN" \
                --gpu-memory-utilization "$VLLM_GPU_MEM_UTIL" \
                $VLLM_EXTRA_ARGS 2>"$_stderr_file")
        rc=$?
        # Fold stderr into the persistent log for later triage
        if [[ -s "$_stderr_file" ]]; then
            {
                echo "=== docker run stderr ==="
                cat "$_stderr_file"
                echo "=== end docker run stderr ==="
            } >> "$VLLM_LOG"
        fi

        if [[ "$rc" -ne 0 ]]; then
            log_error "docker run failed (rc=$rc). stderr:"
            sed 's/^/    /' "$_stderr_file" >&2 || true
            rm -f "$_stderr_file"
            # Clean up any half-created container so the next attempt adopts nothing stale
            docker rm -f "$VLLM_CONTAINER_NAME" >/dev/null 2>&1 || true
            return 1
        fi
        rm -f "$_stderr_file"

        if [[ -z "$cid" ]]; then
            log_error "docker run returned success but no container ID. Check Docker daemon."
            return 1
        fi
        log_info "Container started (id=${cid:0:12})"

        # Paranoia: verify the container is actually registered before we enter
        # the wait loop. If docker_proxy / daemon bridged the run but the
        # container vanished instantly, surface that now rather than 5 minutes later.
        if ! docker inspect "$VLLM_CONTAINER_NAME" >/dev/null 2>&1; then
            log_error "Container '${VLLM_CONTAINER_NAME}' not registered after docker run. "
            log_error "  Dumping last 40 lines of docker events for this container:"
            docker events --filter "container=${cid}" --since "1m" --until "0s" 2>&1 | tail -40 | sed 's/^/    /' >&2 || true
            return 1
        fi
        VLLM_STARTED_BY_US=true
    fi

    # Wait for /v1/models to respond. Also fail fast if the container dies.
    local waited=0
    while (( waited < VLLM_STARTUP_TIMEOUT_SEC )); do
        if ! docker inspect -f '{{.State.Running}}' "$VLLM_CONTAINER_NAME" 2>/dev/null | grep -q '^true$'; then
            _dump_vllm_container_diagnostics
            return 1
        fi
        if vllm_reachable; then
            log_info "vLLM ready at ${VLLM_HOST}:${VLLM_PORT} (container ${VLLM_CONTAINER_NAME}, ${waited}s)"
            # Snapshot startup logs so the operator can tail $VLLM_LOG later
            # (live tail: `docker logs -f ${VLLM_CONTAINER_NAME}`)
            docker logs --tail 100 "$VLLM_CONTAINER_NAME" > "$VLLM_LOG" 2>&1 || true
            HAS_VLLM=true
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
        if (( waited % 30 == 0 )); then
            log_info "  still waiting for vLLM container (${waited}s / ${VLLM_STARTUP_TIMEOUT_SEC}s)..."
        fi
    done

    log_error "vLLM container did not become ready within ${VLLM_STARTUP_TIMEOUT_SEC}s."
    _dump_vllm_container_diagnostics
    stop_vllm_server || true
    return 1
}

# Dump docker-side diagnostics for a vllm container that failed to come up.
# Shows State (running/exited/dead), ExitCode, OOMKilled, Error, and last 40
# log lines — or a clear "container does not exist" message if it vanished.
_dump_vllm_container_diagnostics() {
    if ! docker inspect "$VLLM_CONTAINER_NAME" >/dev/null 2>&1; then
        log_error "Container '${VLLM_CONTAINER_NAME}' no longer exists."
        log_error "  Most common causes:"
        log_error "    - docker run rejected by the daemon (check preceding stderr)"
        log_error "    - container was --rm'd elsewhere, or system OOM reaped it"
        log_error "    - '\$VLLM_CONTAINER_NAME' is in use by another testbed; try: docker ps -a"
        return
    fi

    log_error "Container '${VLLM_CONTAINER_NAME}' state:"
    docker inspect -f $'    status={{.State.Status}}  exit_code={{.State.ExitCode}}  oom={{.State.OOMKilled}}\n    error={{.State.Error}}\n    started_at={{.State.StartedAt}}  finished_at={{.State.FinishedAt}}' \
        "$VLLM_CONTAINER_NAME" 2>&1 >&2 || true

    log_error "  Tail of docker logs (40 lines):"
    docker logs --tail 40 "$VLLM_CONTAINER_NAME" 2>&1 | sed 's/^/    /' >&2 || true
    # Snapshot full log for post-mortem
    docker logs --tail 500 "$VLLM_CONTAINER_NAME" > "$VLLM_LOG" 2>&1 || true
}

stop_vllm_server() {
    if [[ "$VLLM_STARTED_BY_US" != "true" ]]; then
        return 0
    fi
    case "$VLLM_BACKEND" in
        docker) _stop_vllm_docker ;;
        host)   _stop_vllm_host   ;;
    esac
    VLLM_STARTED_BY_US=false
}

_stop_vllm_docker() {
    if ! docker inspect "$VLLM_CONTAINER_NAME" > /dev/null 2>&1; then
        return 0
    fi
    log_info "Stopping vLLM container '${VLLM_CONTAINER_NAME}' (timeout ${VLLM_SHUTDOWN_TIMEOUT_SEC}s)..."
    # Save final logs — but only if $VLLM_LOG doesn't already contain the
    # crash dump from _dump_vllm_container_diagnostics. Otherwise we'd wipe
    # it. We snapshot to a side file regardless so nothing is lost.
    docker logs --tail 500 "$VLLM_CONTAINER_NAME" > "${VLLM_LOG}.final" 2>&1 || true
    if [[ ! -s "$VLLM_LOG" ]]; then
        cp "${VLLM_LOG}.final" "$VLLM_LOG" 2>/dev/null || true
    fi
    if docker stop --time "$VLLM_SHUTDOWN_TIMEOUT_SEC" "$VLLM_CONTAINER_NAME" > /dev/null 2>&1; then
        log_info "vLLM container stopped cleanly"
    else
        log_warn "docker stop didn't complete cleanly — sending SIGKILL"
        docker kill "$VLLM_CONTAINER_NAME" > /dev/null 2>&1 || true
    fi
    docker rm "$VLLM_CONTAINER_NAME" > /dev/null 2>&1 || true
}

_stop_vllm_host() {
    if [[ ! -f "$VLLM_PID_FILE" ]]; then
        return 0
    fi

    local pid
    pid=$(cat "$VLLM_PID_FILE" 2>/dev/null || true)
    rm -f "$VLLM_PID_FILE"

    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
        return 0
    fi

    log_info "Stopping vLLM (pid $pid, group $pid)..."
    # SIGTERM the whole process group so vllm workers exit too.
    kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true

    local waited=0
    while (( waited < VLLM_SHUTDOWN_TIMEOUT_SEC )); do
        if ! kill -0 "$pid" 2>/dev/null; then
            log_info "vLLM stopped cleanly after ${waited}s"
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    log_warn "vLLM did not exit within ${VLLM_SHUTDOWN_TIMEOUT_SEC}s — sending SIGKILL"
    kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
}

# Helper: query sqlite via Python (no sqlite3 CLI dependency)
query_db() {
    local db=$1
    local sql=$2
    python -c "
import sqlite3, sys
try:
    conn = sqlite3.connect('$db')
    result = conn.execute(\"\"\"$sql\"\"\").fetchone()
    print(result[0] if result and result[0] is not None else '?')
except Exception:
    print('?')
" 2>/dev/null
}

get_scenario_config_value() {
    local scenario=$1
    local field=$2
    python - <<PY 2>/dev/null
import yaml
from pathlib import Path

config = yaml.safe_load(Path("configs/scenarios.yaml").read_text())
scenario = (config.get("scenarios") or {}).get("$scenario", {})
value = scenario.get("$field")
if value is None:
    raise SystemExit(1)
print(value)
PY
}

extract_failure_summary() {
    local logfile=$1
    python - <<'PY' "$logfile"
from pathlib import Path
import re
import sys

logfile = Path(sys.argv[1])
try:
    lines = logfile.read_text(errors="ignore").splitlines()
except Exception:
    print("unable to read failure log")
    raise SystemExit(0)

patterns = [
    r"\bERROR\b",
    r"Completed: success=False",
    r"Traceback",
    r"Exception",
    r"RuntimeError",
    r"ValueError",
    r"TypeError",
    r"AssertionError",
    r"failed",
    r"timed out",
    r"server_error",
    r"rate_limited",
    r"tool_failure",
    r"Errors:",
    r"Retry \d+/\d+ after .*\(",
    r"\b429\b",
    r"\b5\d\d\b",
]

matches = []
for line in lines:
    text = line.strip()
    if not text:
        continue
    if any(re.search(pattern, text, re.IGNORECASE) for pattern in patterns):
        if text not in matches:
            matches.append(text)

if matches:
    print(" | ".join(matches[-3:])[:800])
elif lines:
    tail = [line.strip() for line in lines[-5:] if line.strip()]
    print(" | ".join(tail)[:800] if tail else "non-zero exit without a recognizable error line")
else:
    print("non-zero exit without log output")
PY
}

scenario_reported_failure() {
    local logfile=$1
    python - <<'PY' "$logfile"
from pathlib import Path
import re
import sys

logfile = Path(sys.argv[1])
try:
    lines = logfile.read_text(errors="ignore").splitlines()
except Exception:
    raise SystemExit(1)

completed_lines = [line for line in lines if "Completed: success=" in line]
for line in completed_lines:
    match = re.search(r"Completed: success=(True|False)", line)
    if match and match.group(1) == "False":
        raise SystemExit(0)

error_lines = [line for line in lines if " - ERROR - " in line]
if error_lines:
    raise SystemExit(0)

raise SystemExit(1)
PY
}

prereq_satisfied() {
    local prereq=$1

    case "$prereq" in
        ALPACA_API_KEY|ALPACA_SECRET_KEY|GOOGLE_SEARCH_API_KEY|GOOGLE_SEARCH_CX|SPOTIFY_CLIENT_ID|SPOTIFY_CLIENT_SECRET)
            [[ -n "${!prereq:-}" ]]
            ;;
        playwright_chromium)
            [[ "$HAS_PLAYWRIGHT" == "true" ]]
            ;;
        examples/assets/network_diagram.png)
            [[ "$HAS_MULTIMODAL_IMAGES" == "true" ]]
            ;;
        http://localhost:8000/v1/models)
            [[ "$HAS_VLLM" == "true" ]]
            ;;
        cmd:*)
            command -v "${prereq#cmd:}" > /dev/null 2>&1
            ;;
        http://*|https://*)
            curl -sf "$prereq" > /dev/null 2>&1
            ;;
        */*|.*)
            [[ -e "$prereq" ]]
            ;;
        *)
            [[ -n "${!prereq:-}" ]]
            ;;
    esac
}

entry_skip_reason() {
    local phase=$1
    local scenario=$2
    local runner_enabled=$3
    local scenario_disabled=$4
    local prereqs_csv=$5
    local prereq=""
    local missing=()

    if [[ "$scenario_disabled" == "true" ]]; then
        echo "scenario is disabled in configs/scenarios.yaml"
        return 0
    fi

    if [[ "$runner_enabled" != "true" ]]; then
        if [[ "$phase" == "stress" ]]; then
            if [[ "$RUN_STRESS_TESTS" != "true" ]]; then
                echo "stress tests disabled (use --stress)"
                return 0
            fi
        elif ! phase_explicitly_enabled "$phase"; then
            echo "phase is optional in test_matrix; enable it explicitly to run"
            return 0
        fi
    fi

    IFS=',' read -r -a prereqs <<< "$prereqs_csv"
    for prereq in "${prereqs[@]}"; do
        [[ -z "$prereq" ]] && continue
        if ! prereq_satisfied "$prereq"; then
            missing+=("$prereq")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        printf 'missing prereqs: %s' "${missing[*]}"
        return 0
    fi

    return 1
}

# Run a single scenario with all its profiles.
# Sets LAST_SCENARIO_DID_WORK=true if any profile actually ran tests.
LAST_SCENARIO_DID_WORK=false

run_scenario() {
    local scenario=$1
    shift
    local profiles=("$@")
    local scenario_interface="$NETWORK_INTERFACE"
    local interface_override=""
    local loopback_interface=""
    local logfile=""
    local exit_code=0
    local failure_detail=""
    local scenario_did_work=false

    if [[ "$NETWORK_INTERFACE" == "auto" ]]; then
        interface_override=$(get_scenario_config_value "$scenario" "network_interface" || true)
        if [[ -n "$interface_override" ]]; then
            scenario_interface="$interface_override"
        fi
    fi
    loopback_interface=$(get_scenario_config_value "$scenario" "loopback_interface" || true)

    for profile in "${profiles[@]}"; do
        log_info "Running: $scenario with profile $profile ($RUNS_PER_SCENARIO runs, interface: $scenario_interface)"
        if [[ -n "$loopback_interface" ]]; then
            log_info "  Scenario-managed loopback shaping: $loopback_interface"
        fi
        logfile="logs/test_${scenario}_${profile}.log"
        LAST_INTERFACE="$scenario_interface"
        cleanup_network_state "$scenario_interface"

        if [[ "$QUIET_MODE" == "true" ]]; then
            progress_bar "$PROGRESS_DONE" "$PROGRESS_TOTAL" "$scenario/$profile"
        fi

        # Build command with pcap capture
        local cmd="python orchestrator.py \
            --scenario $scenario \
            --profile $profile \
            --runs $RUNS_PER_SCENARIO \
            --interface $scenario_interface \
            --mcp-transport $MCP_TRANSPORT"

        if [[ "$CAPTURE_PCAP" == "true" ]]; then
            cmd="$cmd --capture-pcap --capture-dir $CAPTURE_DIR"
            if [[ -n "$CAPTURE_FILTER" ]]; then
                cmd="$cmd --capture-filter '$CAPTURE_FILTER'"
            fi
            # Secondary loopback capture so MCP JSON-RPC frames (which traverse
            # http://127.0.0.1 between agent and MCP server) are visible in pcap.
            # Skipped automatically by orchestrator.py when the primary
            # interface is already lo or when --mcp-transport=stdio.
            if [[ "$CAPTURE_LOOPBACK" == "true" ]]; then
                cmd="$cmd --capture-loopback"
            else
                cmd="$cmd --no-capture-loopback"
            fi
        fi

        if [[ "$RUN_TIMEOUT_SEC" -gt 0 ]]; then
            cmd="$cmd --run-timeout $RUN_TIMEOUT_SEC"
        fi

        if [[ "$STOP_ON_ERROR" == "true" ]]; then
            cmd="$cmd --stop-on-error"
        fi

        if [[ "$RESUME_MODE" == "true" ]]; then
            cmd="$cmd --resume"
        fi

        if [[ "$QUIET_MODE" == "true" ]]; then
            eval "$cmd" > "$logfile" 2>&1
            exit_code=$?
        else
            eval "$cmd" 2>&1 | tee "$logfile"
            exit_code=${PIPESTATUS[0]}
        fi
        cleanup_network_state "$scenario_interface"

        PROGRESS_DONE=$(( PROGRESS_DONE + 1 ))

        if [[ "$exit_code" -ne 0 ]]; then
            [[ "$QUIET_MODE" == "true" ]] && echo ""  # newline after progress bar
            failure_detail="process exited with code $exit_code"
            log_warn "Scenario $scenario/$profile failed: $failure_detail"
            record_scenario_failure "$scenario/$profile" "$failure_detail" "$logfile"
            # Stop processing further profiles for this scenario
            return 1
        fi

        # Skip cooldown if the orchestrator skipped all runs (resume mode)
        if grep -q "all .* runs already completed" "$logfile" 2>/dev/null; then
            continue
        fi

        scenario_did_work=true
        log_info "Cooling down for ${INTER_SCENARIO_DELAY}s..."
        sleep "$INTER_SCENARIO_DELAY"
    done

    LAST_SCENARIO_DID_WORK="$scenario_did_work"
}

run_test_matrix_suite() {
    local current_phase=""
    local phase_started=false
    local phase_ran=false
    local phase_skip_logged=false
    local entry=""
    local phase=""
    local scenario=""
    local runner_enabled=""
    local scenario_disabled=""
    local profiles_csv=""
    local prereqs_csv=""
    local skip_reason=""
    local profiles=()

    for entry in "${TEST_MATRIX_ENTRIES[@]}"; do
        IFS=$'\t' read -r phase scenario runner_enabled scenario_disabled profiles_csv prereqs_csv <<< "$entry"

        if [[ "$phase" != "$current_phase" ]]; then
            if [[ -n "$current_phase" && "$phase_ran" == "true" ]]; then
                log_info "Provider cooldown: ${INTER_PROVIDER_DELAY}s before next phase..."
                sleep "$INTER_PROVIDER_DELAY"
            fi
            current_phase="$phase"
            phase_started=false
            phase_ran=false
            phase_skip_logged=false
        fi

        if ! phase_enabled "$phase"; then
            continue
        fi

        skip_reason=$(entry_skip_reason "$phase" "$scenario" "$runner_enabled" "$scenario_disabled" "$prereqs_csv" || true)
        if [[ -n "$skip_reason" ]]; then
            if [[ "$phase_skip_logged" != "true" ]]; then
                log_warn "Skipping ${phase}: $skip_reason"
                phase_skip_logged=true
            else
                log_warn "Skipping ${scenario}: $skip_reason"
            fi
            continue
        fi

        if [[ "$phase_started" != "true" ]]; then
            log_phase "$(phase_title "$phase")"
            phase_started=true
        fi

        IFS=',' read -r -a profiles <<< "$profiles_csv"
        if ! run_scenario "$scenario" "${profiles[@]}"; then
            log_error "Stopping: $scenario failed (use --resume to continue later)"
            return 1
        fi
        if [[ "$LAST_SCENARIO_DID_WORK" == "true" ]]; then
            phase_ran=true
        fi
    done
}

# Clean start: archive old data
clean_start() {
    local ts=$(date +%Y%m%d_%H%M%S)

    if [[ -f "logs/traffic_logs.db" ]]; then
        local n
        n=$(query_db logs/traffic_logs.db "SELECT COUNT(*) FROM traffic_logs")
        if [[ "$n" != "?" && "$n" -gt 0 ]]; then
            local backup="logs/traffic_logs_${ts}.db.bak"
            cp logs/traffic_logs.db "$backup"
            log_info "Archived existing database ($n records) to $backup"
            rm logs/traffic_logs.db
            log_info "Removed old database for clean start"
        fi
    fi

    # Archive old pcap captures
    if [[ -d "$CAPTURE_DIR" ]]; then
        local pcap_count=$(find "$CAPTURE_DIR" -name "*.pcap" 2>/dev/null | wc -l)
        if [[ "$pcap_count" -gt 0 ]]; then
            local archive="results/backup/captures_${ts}"
            mkdir -p results/backup
            mv "$CAPTURE_DIR" "$archive"
            log_info "Archived $pcap_count pcap files to $archive"
        fi
    fi
    mkdir -p "$CAPTURE_DIR"

    # Archive old reports
    if [[ -d "results/reports" ]]; then
        local archive="results/backup/reports_${ts}"
        mkdir -p results/backup
        mv results/reports "$archive"
        log_info "Archived old reports to $archive"
    fi
    mkdir -p results/reports/figures

    # Archive old trace logs
    if [[ -d "$TRACE_LOG_DIR" ]]; then
        local archive="${TRACE_LOG_DIR}_${ts}"
        mv "$TRACE_LOG_DIR" "$archive"
        log_info "Archived old traces to $archive"
    fi
    mkdir -p "$TRACE_LOG_DIR"

    # Clean per-scenario logs
    rm -f logs/test_*.log

    log_info "Clean start complete"
}

# Main test execution
main() {
    if [[ "$QUIET_MODE" != "true" ]]; then
        echo "========================================"
        echo "6G AI Traffic Testbed - Full Test Suite"
        echo "========================================"
        echo "Runs per scenario: $RUNS_PER_SCENARIO"
        echo "Packet capture:    $CAPTURE_PCAP"
        echo "Clean start:       $CLEAN_START"
        echo "Resume mode:       $RESUME_MODE"
        echo "Stop on error:     $STOP_ON_ERROR"
        echo "Inter-scenario:    ${INTER_SCENARIO_DELAY}s"
        echo "Inter-provider:    ${INTER_PROVIDER_DELAY}s"
        if [[ "$MANAGE_VLLM" == "true" ]]; then
            echo "vLLM:              auto-managed via ${VLLM_BACKEND} (model=${VLLM_MODEL}, bind=${VLLM_HOST}:${VLLM_PORT})"
        fi
        echo ""
    fi

    # Check prerequisites
    check_sudo || true

    # Register the EXIT/INT/TERM trap *before* starting vLLM so a Ctrl-C
    # during the (possibly several-minute) model load still triggers
    # stop_vllm_server via cleanup_on_exit.
    mkdir -p logs
    trap cleanup_on_exit EXIT INT TERM

    # Auto-start vLLM if requested AND the vllm phase is not disabled.
    # (No point loading a 24 GB model just to immediately shut it back down.)
    if [[ "$MANAGE_VLLM" == "true" ]] && phase_enabled "vllm"; then
        if ! start_vllm_server; then
            log_error "vLLM startup failed — aborting (set MANAGE_VLLM=false to skip vllm scenarios instead)"
            exit 1
        fi
    elif [[ "$MANAGE_VLLM" == "true" ]]; then
        log_info "MANAGE_VLLM=true but vllm phase is disabled — not starting server"
    fi

    # Check optional prerequisites (now sees the running server, if managed)
    if [[ "$QUIET_MODE" != "true" ]]; then
        check_optional_prereqs
    else
        check_optional_prereqs > /dev/null 2>&1
    fi
    load_test_matrix

    # In resume mode, filter out completed work before doing anything else
    if [[ "$RESUME_MODE" == "true" ]]; then
        filter_completed_from_matrix
        if [[ ${#TEST_MATRIX_ENTRIES[@]} -eq 0 ]]; then
            log_info "All scenario/profile combos already completed — nothing to do."
            exit 0
        fi
    fi

    # Clean start if requested
    if [[ "$CLEAN_START" == "true" ]]; then
        clean_start
    else
        # Just backup existing database
        if [[ -f "logs/traffic_logs.db" ]]; then
            EXISTING_RECORDS=$(query_db logs/traffic_logs.db "SELECT COUNT(*) FROM traffic_logs")
            if [[ "$EXISTING_RECORDS" != "?" && "$EXISTING_RECORDS" -gt 0 ]]; then
                PRE_BACKUP="logs/traffic_logs_pre_$(date +%Y%m%d_%H%M%S).db.bak"
                cp logs/traffic_logs.db "$PRE_BACKUP"
                log_info "Backed up existing database ($EXISTING_RECORDS records) to $PRE_BACKUP"
            fi
        fi
    fi

    START_TIME=$(date +%s)

    # =====================================================
    # Network Profiles referenced by configs/scenarios.yaml:test_matrix
    # (per S4-260848 Table C.Z-1):
    # - no_emulation:   reference case with no tc/netem impairment
    # - 6g_itu_hrllc:   1ms / 0.001% loss / 300Mbit (ITU IMT-2030 HRLLC)
    # - 5g_urban:       20ms / 0.1% loss / 100Mbit (mainstream cellular)
    # - wifi_good:      30ms / 0.1% loss / 50Mbit (non-3GPP local access)
    # - cell_edge:      120ms / 1% loss / 5Mbit (paretonormal jitter, gemodel loss)
    # - satellite_leo:  ASYMMETRIC — DL 22ms/100Mbit, UL 22ms/15Mbit
    # - satellite_geo:  ASYMMETRIC — DL 340ms/50Mbit, UL 340ms/3Mbit
    # - congested:      200ms / 3% loss / 1Mbit (bufferbloat / queue stress)
    # - 5qi_7:          80ms / 0.1% loss (Voice / Live Streaming, jitter-corrected PDB)
    # - 5qi_80:         8ms / 0.0001% loss (Low-latency eMBB / AR)
    # =====================================================

    if ! run_test_matrix_suite; then
        [[ "$QUIET_MODE" == "true" ]] && echo ""
        log_error "Test suite stopped due to failure. Re-run with --resume to continue."
        exit 1
    fi

    # Final progress bar at 100%
    if [[ "$QUIET_MODE" == "true" && "$PROGRESS_TOTAL" -gt 0 ]]; then
        progress_bar "$PROGRESS_TOTAL" "$PROGRESS_TOTAL" "done"
        echo ""
    fi

    # =====================================================
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))

    log_phase "TESTS COMPLETE - Generating Reports"
    log_info "Test suite completed in $(($DURATION / 3600))h $(($DURATION % 3600 / 60))m"

    # =====================================================
    # Report Generation Pipeline
    # =====================================================

    # Redirect verbose output in quiet mode
    local report_out="/dev/stdout"
    [[ "$QUIET_MODE" == "true" ]] && report_out="/dev/null"

    # 1. Generate all charts (including pcap network-layer analysis)
    log_info "Generating charts..."
    local chart_cmd="python generate_charts.py --since-timestamp $START_TIME"
    if [[ "$CAPTURE_PCAP" == "true" && -d "$CAPTURE_DIR" ]]; then
        chart_cmd="$chart_cmd --pcap-dir $CAPTURE_DIR"
    fi
    if eval "$chart_cmd" > "$report_out" 2>&1; then
        log_info "  Charts generated in results/reports/figures/"
    else
        log_warn "  Chart generation failed - continuing anyway"
    fi

    # 2. Export to Excel
    log_info "Exporting to Excel..."
    if python export_to_excel.py --since-timestamp "$START_TIME" > "$report_out" 2>&1; then
        log_info "  Excel exported to results/reports/chart_data.xlsx"
    else
        log_warn "  Excel export failed - continuing anyway"
    fi

    # 3. Generate RESULTS.md
    log_info "Generating RESULTS.md..."
    python generate_results_md.py \
        --db logs/traffic_logs.db \
        --since-timestamp "$START_TIME" \
        --duration-sec "$DURATION" \
        --output RESULTS.md \
        > "$report_out" 2>&1
    log_info "  RESULTS.md generated"

    # 4. Generate TRACES.md with sample traces for key scenarios
    log_info "Generating TRACES.md..."
    if python generate_traces_md.py \
        --db logs/traffic_logs.db \
        --output TRACES.md \
        --scenarios "chat_basic,chat_streaming,realtime_text,realtime_audio,image_generation,music_search,direct_web_search,computer_control_agent" \
        > "$report_out" 2>&1; then
        log_info "  TRACES.md generated"
    else
        log_warn "  TRACES.md generation failed - continuing anyway"
    fi

    # 5. Build ML dataset from pcap captures
    local ml_out="/dev/stdout"
    [[ "$QUIET_MODE" == "true" ]] && ml_out="/dev/null"

    if [[ "$CAPTURE_PCAP" == "true" && -d "$CAPTURE_DIR" ]]; then
        log_info "Building ML dataset from pcap captures..."
        if python -m ml.dataset \
            --captures-dir "$CAPTURE_DIR" \
            --db-path logs/traffic_logs.db \
            --output-dir ml/data \
            --classify-by auto \
            > "$ml_out" 2>&1; then
            log_info "  ML dataset built in ml/data/"

            # 6. Train traffic classifier
            log_info "Training traffic classifier (k=20)..."
            if python -m ml.train_classifier \
                --data-dir ml/data \
                --k 20 \
                --epochs 100 \
                --output-dir ml/models/classifier \
                > "$ml_out" 2>&1; then
                log_info "  Classifier trained - results in ml/results/classifier/"
            else
                log_warn "  Classifier training failed - continuing anyway"
            fi

            # 7. Run k-sweep for early classification analysis
            log_info "Running classifier k-sweep (5,10,15,20,30,50)..."
            if python -m ml.train_classifier \
                --data-dir ml/data \
                --sweep-k 5,10,15,20,30,50 \
                > "$ml_out" 2>&1; then
                log_info "  k-sweep complete - accuracy_vs_k.png in ml/results/classifier/"
            else
                log_warn "  k-sweep failed - continuing anyway"
            fi

            # 8. Train traffic generator
            log_info "Training traffic generator (CVAE)..."
            if python -m ml.train_generator \
                --data-dir ml/data \
                --epochs 200 \
                --output-dir ml/models/generator \
                > "$ml_out" 2>&1; then
                log_info "  Generator trained"

                # 9. Generate synthetic traces for all conditions
                log_info "Generating synthetic traffic traces..."
                if python -m ml.train_generator \
                    --generate \
                    --all-conditions \
                    --model-path ml/models/generator/best.pt \
                    --n-samples 100 \
                    --output-dir ml/synthetic \
                    > "$ml_out" 2>&1; then
                    log_info "  Synthetic traces in ml/synthetic/"
                fi

                # 10. Evaluate generator quality
                log_info "Evaluating generator quality..."
                if python -m ml.train_generator \
                    --evaluate \
                    --model-path ml/models/generator/best.pt \
                    --data-dir ml/data \
                    --output-dir ml/results/generator \
                    > "$ml_out" 2>&1; then
                    log_info "  Generator evaluation in ml/results/generator/"
                fi
            else
                log_warn "  Generator training failed - continuing anyway"
            fi
        else
            log_warn "  ML dataset build failed - skipping model training"
        fi
    fi

    # 11. Anonymize database
    if [[ "$ANONYMIZE_DB" == "true" ]]; then
        log_info "Anonymizing database..."
        if python anonymize_db.py --db logs/traffic_logs.db > "$report_out" 2>&1; then
            log_info "  Database anonymized (provider/model names aliased)"
        else
            log_warn "  Database anonymization failed - continuing anyway"
        fi
    fi

    # 12. Final database backup
    BACKUP_FILE="logs/traffic_logs_$(date +%Y%m%d_%H%M%S).db.bak"
    cp logs/traffic_logs.db "$BACKUP_FILE"
    log_info "  Database backed up to $BACKUP_FILE"

    # =====================================================
    # Final Summary
    # =====================================================
    echo ""
    echo "========================================"
    log_info "Full evaluation complete!"
    echo "========================================"

    # Count results
    TOTAL_RECORDS=$(query_db logs/traffic_logs.db "SELECT COUNT(*) FROM traffic_logs WHERE timestamp > $START_TIME")
    TOTAL_SCENARIOS=$(query_db logs/traffic_logs.db "SELECT COUNT(DISTINCT scenario_id) FROM traffic_logs WHERE timestamp > $START_TIME")
    TOTAL_PROFILES=$(query_db logs/traffic_logs.db "SELECT COUNT(DISTINCT network_profile) FROM traffic_logs WHERE timestamp > $START_TIME")
    SUCCESS_RATE=$(query_db logs/traffic_logs.db "SELECT ROUND(100.0 * SUM(success) / COUNT(*), 1) FROM traffic_logs WHERE timestamp > $START_TIME")

    echo "  Duration:    $(($DURATION / 3600))h $(($DURATION % 3600 / 60))m $(($DURATION % 60))s"
    echo "  Records:     $TOTAL_RECORDS"
    echo "  Scenarios:   $TOTAL_SCENARIOS"
    echo "  Profiles:    $TOTAL_PROFILES"
    echo "  Success:     ${SUCCESS_RATE}%"
    if [[ ${#FAILED_SCENARIOS[@]} -gt 0 ]]; then
        echo "  Failures:    ${#FAILED_SCENARIOS[@]}"
    fi
    echo ""
    echo "  Outputs:"
    echo "    Database:    logs/traffic_logs.db"
    echo "    Charts:      results/reports/figures/"
    echo "    Excel:       results/reports/chart_data.xlsx"
    echo "    Report:      RESULTS.md"
    echo "    Traces:      TRACES.md"
    echo "    Backup:      $BACKUP_FILE"

    if [[ "$CAPTURE_PCAP" == "true" ]]; then
        PCAP_COUNT=$(find "$CAPTURE_DIR" -name "*.pcap" 2>/dev/null | wc -l || echo "0")
        PCAP_SIZE=$(du -sh "$CAPTURE_DIR" 2>/dev/null | cut -f1 || echo "?")
        echo "    Pcaps:       $CAPTURE_DIR/ ($PCAP_COUNT files, $PCAP_SIZE)"
    fi

    if [[ -d "ml/models" ]]; then
        echo "    ML Models:   ml/models/"
        echo "    ML Results:  ml/results/"
        echo "    Synthetic:   ml/synthetic/"
    fi

    if [[ "$ANONYMIZE_DB" == "true" ]]; then
        echo "    Anonymized:  Yes (provider/model names aliased)"
    fi
    echo "========================================"

    if [[ ${#FAILED_SCENARIOS[@]} -gt 0 ]]; then
        echo ""
        log_warn "Scenario failures detected:"
        for i in "${!FAILED_SCENARIOS[@]}"; do
            echo "  - ${FAILED_SCENARIOS[$i]}: ${FAILED_DETAILS[$i]}"
            echo "    log: ${FAILED_LOGS[$i]}"
        done
    fi

    # Print per-scenario summary
    echo ""
    log_info "Per-scenario summary:"
    python -c "
import sqlite3
conn = sqlite3.connect('logs/traffic_logs.db')
cur = conn.execute('''
    SELECT scenario_id, network_profile,
           COUNT(*) as runs,
           SUM(CASE WHEN success=1 THEN 1 ELSE 0 END) as ok,
           ROUND(AVG(latency_sec), 2) as avg_lat
    FROM traffic_logs
    WHERE timestamp > $START_TIME
    GROUP BY scenario_id, network_profile
    ORDER BY scenario_id, network_profile
''')
header = [d[0] for d in cur.description]
rows = cur.fetchall()
if rows:
    widths = [max(len(str(h)), max(len(str(r[i])) for r in rows)) for i, h in enumerate(header)]
    fmt = '  '.join(f'{{:<{w}}}' for w in widths)
    print(fmt.format(*header))
    print(fmt.format(*['-'*w for w in widths]))
    for row in rows:
        print(fmt.format(*[str(v) for v in row]))
else:
    print('No records found.')
conn.close()
" 2>/dev/null || log_warn "Could not print per-scenario summary"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --quick)
            RUNS_PER_SCENARIO=3
            INTER_SCENARIO_DELAY=2
            INTER_PROVIDER_DELAY=5
            log_info "Quick mode: 3 runs, shorter delays"
            shift
            ;;
        --full)
            RUNS_PER_SCENARIO=30
            INTER_SCENARIO_DELAY=2
            INTER_PROVIDER_DELAY=5
            log_info "Full mode: 30 runs per scenario"
            shift
            ;;
        --stress)
            RUN_STRESS_TESTS=true
            log_info "Stress tests enabled"
            shift
            ;;
        --no-capture)
            CAPTURE_PCAP=false
            log_info "Packet capture disabled"
            shift
            ;;
        --no-anonymize)
            ANONYMIZE_DB=false
            log_info "Database anonymization disabled"
            shift
            ;;
        --no-clean)
            CLEAN_START=false
            log_info "Keeping existing data (no clean start)"
            shift
            ;;
        --resume)
            RESUME_MODE=true
            CLEAN_START=false
            log_info "Resume mode: skipping completed experiments, keeping existing data"
            shift
            ;;
        --verbose|-v)
            QUIET_MODE=false
            shift
            ;;
        --runs)
            RUNS_PER_SCENARIO=$2
            log_info "Runs per scenario: $RUNS_PER_SCENARIO"
            shift 2
            ;;
        --enable)
            ENABLED_PHASES=$2
            log_info "Enabled phases: $ENABLED_PHASES"
            shift 2
            ;;
        --disable)
            DISABLED_PHASES=$2
            log_info "Disabled phases: $DISABLED_PHASES"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Matrix source: configs/scenarios.yaml:test_matrix"
            echo ""
            echo "Options:"
            echo "  --quick        Run 3 iterations per scenario with shorter delays"
            echo "  --full         Run 30 iterations per scenario (default)"
            echo "  --runs N       Set exact number of runs per scenario"
            echo "  --stress       Enable stress tests (burst search, parallel benchmark)"
            echo "  --no-capture   Disable L3/L4 packet capture (enabled by default)"
            echo "  --no-anonymize Disable database anonymization (enabled by default)"
            echo "  --no-clean     Keep existing database and pcaps (default: clean start)"
            echo "  --resume       Resume from last successful run (implies --no-clean)"
            echo "  --verbose, -v  Show full output instead of progress bar"
            echo "  --enable LIST  Only run these phases (comma-separated)"
            echo "  --disable LIST Skip these phases (comma-separated)"
            echo ""
            echo "Phase names for --enable/--disable:"
            echo "  chat, realtime, image, search, deepseek, gemini, music,"
            echo "  trading, computer_use, playwright, multimodal, google_search, stress, vllm"
            echo ""
            echo "Environment variables:"
            echo "  RUNS_PER_SCENARIO        Number of runs (default: 30)"
            echo "  INTER_SCENARIO_DELAY     Seconds between scenarios (default: 2)"
            echo "  INTER_PROVIDER_DELAY     Seconds between providers (default: 5)"
            echo "  CAPTURE_PCAP             Enable pcap capture (default: true)"
            echo "  CAPTURE_DIR              Pcap output directory (default: results/captures)"
            echo "  CAPTURE_FILTER           BPF filter (default: 'port 443 or port 80 or port 8080 or port 8000')"
            echo "  ANONYMIZE_DB             Anonymize provider/model names (default: true)"
            echo "  CLEAN_START              Archive old data before starting (default: true)"
            echo "  NETWORK_INTERFACE        Global interface override (default: auto)"
            echo "  RUN_TIMEOUT_SEC          Per-run timeout in seconds (default: 300, 0 = no timeout)"
            echo ""
            echo "Optional API keys (for additional scenarios):"
            echo "  GOOGLE_SEARCH_API_KEY    Enable Google search scenarios"
            echo "  GOOGLE_SEARCH_CX         Required with GOOGLE_SEARCH_API_KEY"
            echo "  SPOTIFY_CLIENT_ID        Enable Spotify music agent scenarios"
            echo "  SPOTIFY_CLIENT_SECRET    Required with SPOTIFY_CLIENT_ID"
            echo ""
            echo "Pipeline (automated after tests):"
            echo "  1. Generate charts (latency, TTFT, throughput, heatmaps, pcap analysis)"
            echo "  2. Export to Excel (15 sheets)"
            echo "  3. Generate RESULTS.md (full evaluation report)"
            echo "  4. Generate TRACES.md (sample request/response traces)"
            echo "  5. Build ML dataset from pcap captures"
            echo "  6. Train MLP traffic classifier + k-sweep"
            echo "  7. Train CVAE traffic generator"
            echo "  8. Generate synthetic traffic traces"
            echo "  9. Evaluate synthetic traffic quality (KS tests)"
            echo " 10. Anonymize database"
            echo ""
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

main
if [[ ${#FAILED_SCENARIOS[@]} -gt 0 ]]; then
    exit 1
fi
