#!/bin/bash
#
# vLLM Smoke Validation Script
# Runs each vllm test_matrix scenario from configs/scenarios.yaml against a
# small representative profile set. Auto-manages the vLLM server lifecycle by
# default (start before scenarios, stop on exit/error/Ctrl-C).
#
# Default profile is satellite_leo — the asymmetric NTN case that exercises
# the uplink: parser on lo. Override with VALIDATION_PROFILES=a,b,... or
# --profile a,b,... to run additional ones (each scenario runs once per
# requested profile).
#
# vllm scenarios declare `network_interface: lo` in their scenario config, so
# the orchestrator applies tc/netem to the loopback interface and the running
# vLLM server's TCP traffic is what gets shaped.
#

set -u
set -o pipefail

if [[ -f ".env" ]]; then
    set -a
    source .env
    set +a
fi

# --- Profile selection (same shape as test_profiles.sh) -------------------
VALIDATION_PROFILES=${VALIDATION_PROFILES:-satellite_leo}
if [[ -n "${VALIDATION_PROFILE:-}" ]]; then
    VALIDATION_PROFILES="$VALIDATION_PROFILE"
fi

RUNS_PER_SCENARIO=${RUNS_PER_SCENARIO:-1}
INTER_RUN_DELAY=${INTER_RUN_DELAY:-1}
RUN_TIMEOUT_SEC=${RUN_TIMEOUT_SEC:-600}
SCENARIO_FILTER=${SCENARIO_FILTER:-}

CAPTURE_PCAP=${CAPTURE_PCAP:-false}
CAPTURE_DIR=${CAPTURE_DIR:-results/captures_vllm_smoke}
CAPTURE_FILTER=${CAPTURE_FILTER:-"port ${VLLM_PORT:-8000}"}

# --- vLLM lifecycle (mirrors run_full_tests.sh) ---------------------------
# Default ON for this script — its entire purpose is to exercise vllm.
# VLLM_BACKEND selects how the server is launched:
#   docker (default) — vllm/vllm-openai container via docker
#   host             — `vllm serve` directly (requires working CUDA on host)
MANAGE_VLLM=${MANAGE_VLLM:-true}
VLLM_BACKEND=${VLLM_BACKEND:-docker}
VLLM_MODEL=${VLLM_MODEL:-Qwen/Qwen3-VL-30B-A3B-Instruct}
VLLM_HOST=${VLLM_HOST:-127.0.0.1}
VLLM_PORT=${VLLM_PORT:-8000}
VLLM_GPU_MEM_UTIL=${VLLM_GPU_MEM_UTIL:-0.95}
VLLM_MAX_MODEL_LEN=${VLLM_MAX_MODEL_LEN:-131072}
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

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0
FAILURES=()
FAILURE_DETAILS=()
FAILURE_LOGS=()

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_pass()  { echo -e "  ${GREEN}PASS${NC}  $1"; ((PASS++)); }
log_fail() {
    local label=$1
    local detail=${2:-"unknown error"}
    local logfile=${3:-""}
    echo -e "  ${RED}FAIL${NC}  ${label} — ${detail}"
    ((FAIL++))
    FAILURES+=("$label")
    FAILURE_DETAILS+=("$detail")
    FAILURE_LOGS+=("$logfile")
}
log_skip()  { echo -e "  ${YELLOW}SKIP${NC}  $1"; ((SKIP++)); }
log_phase() {
    echo -e "\n${BLUE}────────────────────────────────────────${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}────────────────────────────────────────${NC}"
}

print_usage() {
    cat <<EOF
Usage: $0 [--scenario NAME] [--profile NAME[,NAME...]]
          [--asymmetric-only] [--no-manage] [--help]

Runs every vllm-phase scenario from configs/scenarios.yaml:test_matrix
once per requested profile. Auto-starts and stops the vLLM server.

Options:
  --scenario NAME      Run only the named vllm scenario
                       (default: all enabled vllm-phase scenarios)
  --profile LIST       Comma-separated profile list to validate
                       (overrides VALIDATION_PROFILES). Each scenario runs
                       once per profile.
  --asymmetric-only    Shortcut for --profile satellite_leo,satellite_geo
                       (verifies the uplink: parser on lo end-to-end)
  --no-manage          Don't start/stop vllm; assume one is already running
                       at \${VLLM_HOST}:\${VLLM_PORT}
  --help               Show this help

Environment overrides:
  VALIDATION_PROFILES        Comma-separated profile list
                             (default: satellite_leo)
  VALIDATION_PROFILE         Single-profile shortcut (overrides VALIDATION_PROFILES)
  RUNS_PER_SCENARIO          Runs per (scenario, profile) (default: 1)
  RUN_TIMEOUT_SEC            Per-run timeout in seconds (default: 600)
  CAPTURE_PCAP               Enable pcap capture on lo (default: false)
  CAPTURE_DIR                Capture output directory
  CAPTURE_FILTER             tcpdump filter (default: "port \${VLLM_PORT}")

vLLM lifecycle:
  MANAGE_VLLM                true|false  (default: true; --no-manage sets false)
  VLLM_BACKEND               docker|host (default: docker)
  VLLM_MODEL                 (default: Qwen/Qwen3-VL-30B-A3B-Instruct)
  VLLM_HOST / VLLM_PORT      (defaults: 127.0.0.1 / 8000)
  VLLM_GPU_MEM_UTIL          (default: 0.95)
  VLLM_MAX_MODEL_LEN         (default: 131072 — 128K context)
  VLLM_EXTRA_ARGS            (default: --trust-remote-code --tensor-parallel-size 1)
  VLLM_LOG / VLLM_PID_FILE   (defaults under logs/; VLLM_LOG holds docker logs when docker backend)
  VLLM_STARTUP_TIMEOUT_SEC   (default: 600)
  VLLM_SHUTDOWN_TIMEOUT_SEC  (default: 30)

vLLM docker backend:
  VLLM_IMAGE                 (default: vllm/vllm-openai:latest)
  VLLM_CONTAINER_NAME        (default: vllm-testbed)
  VLLM_HF_CACHE              HuggingFace cache mounted into container
                             (default: \$HOME/.cache/huggingface)
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --scenario)
                if [[ $# -lt 2 || -z "$2" ]]; then
                    log_error "--scenario requires a name"; exit 1
                fi
                SCENARIO_FILTER="$2"; shift 2 ;;
            --profile)
                if [[ $# -lt 2 || -z "$2" ]]; then
                    log_error "--profile requires a name (comma-separated for multiple)"; exit 1
                fi
                VALIDATION_PROFILES="$2"; shift 2 ;;
            --asymmetric-only)
                VALIDATION_PROFILES="satellite_leo,satellite_geo"; shift ;;
            --no-manage)
                MANAGE_VLLM=false; shift ;;
            --help)
                print_usage; exit 0 ;;
            *)
                log_error "Unknown option: $1"; print_usage; exit 1 ;;
        esac
    done
}

# --------------------------------------------------------------------------
# vLLM lifecycle (kept in sync with run_full_tests.sh)
# --------------------------------------------------------------------------

vllm_reachable() {
    curl -sf "http://${VLLM_HOST}:${VLLM_PORT}/v1/models" > /dev/null 2>&1
}

start_vllm_server() {
    if [[ "$MANAGE_VLLM" != "true" ]]; then
        if vllm_reachable; then
            log_info "vLLM reachable at ${VLLM_HOST}:${VLLM_PORT} (operator-managed)"
            return 0
        fi
        log_error "MANAGE_VLLM=false but no server is reachable at ${VLLM_HOST}:${VLLM_PORT}"
        log_error "Start vllm yourself or re-run without --no-manage"
        return 1
    fi

    if vllm_reachable; then
        log_info "vLLM already reachable at ${VLLM_HOST}:${VLLM_PORT} — reusing existing server"
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

    sudo tc qdisc del dev lo root    >/dev/null 2>&1 || true
    sudo tc qdisc del dev lo ingress >/dev/null 2>&1 || true

    mkdir -p "$(dirname "$VLLM_LOG")"
    : > "$VLLM_LOG"

    log_info "Starting vLLM (host): model=${VLLM_MODEL} host=${VLLM_HOST} port=${VLLM_PORT}"
    log_info "  log: $VLLM_LOG  (timeout ${VLLM_STARTUP_TIMEOUT_SEC}s for model load)"

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
            rm -f "$VLLM_PID_FILE"; VLLM_STARTED_BY_US=false
            return 1
        fi
        if vllm_reachable; then
            log_info "vLLM ready at ${VLLM_HOST}:${VLLM_PORT} (pid $pid, ${waited}s)"
            return 0
        fi
        sleep 1; waited=$((waited + 1))
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
        sudo tc qdisc del dev lo root    >/dev/null 2>&1 || true
        sudo tc qdisc del dev lo ingress >/dev/null 2>&1 || true

        mkdir -p "$(dirname "$VLLM_LOG")"
        : > "$VLLM_LOG"

        log_info "Starting vLLM (docker): image=${VLLM_IMAGE} name=${VLLM_CONTAINER_NAME}"
        log_info "  model=${VLLM_MODEL}  bind=${VLLM_HOST}:${VLLM_PORT}  HF cache=${VLLM_HF_CACHE}"
        log_info "  log: ${VLLM_LOG}  (timeout ${VLLM_STARTUP_TIMEOUT_SEC}s for model load)"

        local cid err
        if ! err=$(docker run -d --name "$VLLM_CONTAINER_NAME" \
                --gpus all --ipc=host \
                -v "${VLLM_HF_CACHE}:/root/.cache/huggingface" \
                -p "${VLLM_HOST}:${VLLM_PORT}:8000" \
                "$VLLM_IMAGE" \
                --model "$VLLM_MODEL" \
                --max-model-len "$VLLM_MAX_MODEL_LEN" \
                --gpu-memory-utilization "$VLLM_GPU_MEM_UTIL" \
                $VLLM_EXTRA_ARGS 2>&1); then
            log_error "docker run failed:"
            printf '    %s\n' "$err" >&2
            return 1
        fi
        cid="$err"
        log_info "Container started (id=${cid:0:12})"
        VLLM_STARTED_BY_US=true
    fi

    local waited=0
    while (( waited < VLLM_STARTUP_TIMEOUT_SEC )); do
        if ! docker inspect -f '{{.State.Running}}' "$VLLM_CONTAINER_NAME" 2>/dev/null | grep -q '^true$'; then
            log_error "vLLM container stopped during startup. Tail of docker logs:"
            docker logs --tail 40 "$VLLM_CONTAINER_NAME" 2>&1 | sed 's/^/    /' >&2 || true
            docker logs --tail 200 "$VLLM_CONTAINER_NAME" > "$VLLM_LOG" 2>&1 || true
            return 1
        fi
        if vllm_reachable; then
            log_info "vLLM ready at ${VLLM_HOST}:${VLLM_PORT} (container ${VLLM_CONTAINER_NAME}, ${waited}s)"
            docker logs --tail 100 "$VLLM_CONTAINER_NAME" > "$VLLM_LOG" 2>&1 || true
            return 0
        fi
        sleep 1; waited=$((waited + 1))
        if (( waited % 30 == 0 )); then
            log_info "  still waiting for vLLM container (${waited}s / ${VLLM_STARTUP_TIMEOUT_SEC}s)..."
        fi
    done

    log_error "vLLM container did not become ready within ${VLLM_STARTUP_TIMEOUT_SEC}s. Tail of docker logs:"
    docker logs --tail 40 "$VLLM_CONTAINER_NAME" 2>&1 | sed 's/^/    /' >&2 || true
    docker logs --tail 200 "$VLLM_CONTAINER_NAME" > "$VLLM_LOG" 2>&1 || true
    stop_vllm_server || true
    return 1
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
    docker logs --tail 200 "$VLLM_CONTAINER_NAME" > "$VLLM_LOG" 2>&1 || true
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
    kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    local waited=0
    while (( waited < VLLM_SHUTDOWN_TIMEOUT_SEC )); do
        if ! kill -0 "$pid" 2>/dev/null; then
            log_info "vLLM stopped cleanly after ${waited}s"; return 0
        fi
        sleep 1; waited=$((waited + 1))
    done
    log_warn "vLLM did not exit within ${VLLM_SHUTDOWN_TIMEOUT_SEC}s — sending SIGKILL"
    kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
}

# --------------------------------------------------------------------------
# Network state cleanup (lo only — vllm scenarios target loopback)
# --------------------------------------------------------------------------

cleanup_lo_state() {
    sudo tc qdisc del dev lo root    >/dev/null 2>&1 || true
    sudo tc qdisc del dev lo ingress >/dev/null 2>&1 || true
    local ifb=${IFB_DEVICE:-ifb0}
    sudo tc qdisc del dev "$ifb" root >/dev/null 2>&1 || true
    sudo ip link set dev "$ifb" down  >/dev/null 2>&1 || true
}

cleanup_on_exit() {
    stop_vllm_server || true
    cleanup_lo_state
}

check_sudo() {
    log_info "Checking sudo access for tc on lo..."
    if ! sudo -n tc qdisc show dev lo &>/dev/null; then
        log_error "Cannot run tc commands without a password."
        log_error "Configure passwordless sudo for tc, or run 'sudo -v' first."
        exit 1
    fi
    log_info "sudo OK"
}

# --------------------------------------------------------------------------
# Discovery + execution
# --------------------------------------------------------------------------

load_vllm_scenarios() {
    mapfile -t VLLM_ENTRIES < <(
        python - <<'PY'
import yaml
from pathlib import Path

config = yaml.safe_load(Path("configs/scenarios.yaml").read_text())
scenarios = config.get("scenarios") or {}
for entry in (config.get("test_matrix") or []):
    if entry.get("phase") != "vllm":
        continue
    name = entry["scenario"]
    sd = scenarios.get(name, {})
    fields = [
        name,
        "true" if entry.get("runner_enabled_by_default", True) else "false",
        "true" if sd.get("disabled", False) else "false",
        ",".join(entry.get("profiles") or []),
    ]
    print("\t".join(fields))
PY
    )
    if [[ ${#VLLM_ENTRIES[@]} -eq 0 ]]; then
        log_error "No vllm-phase scenarios in configs/scenarios.yaml:test_matrix."
        exit 1
    fi
}

load_requested_profiles() {
    REQUESTED_PROFILES=()
    IFS=',' read -r -a REQUESTED_PROFILES <<< "$VALIDATION_PROFILES"

    if [[ ${#REQUESTED_PROFILES[@]} -eq 0 ]]; then
        log_error "VALIDATION_PROFILES is empty"; exit 1
    fi

    local known
    known=$(python - <<'PY'
import yaml
from pathlib import Path
p = yaml.safe_load(Path("configs/profiles.yaml").read_text()) or {}
print(" ".join((p.get("profiles") or {}).keys()))
PY
    )
    local missing=()
    for prof in "${REQUESTED_PROFILES[@]}"; do
        prof="${prof// /}"
        if ! [[ " $known " == *" $prof "* ]]; then
            missing+=("$prof")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "profile(s) not defined in configs/profiles.yaml: ${missing[*]}"
        exit 1
    fi
}

# Print profiles that are both requested AND included in this entry's
# matrix profiles list. Order follows REQUESTED_PROFILES.
profiles_for_entry() {
    local entry_csv=$1
    local -a entry_profiles
    IFS=',' read -r -a entry_profiles <<< "$entry_csv"
    local out=()
    local req prof
    for req in "${REQUESTED_PROFILES[@]}"; do
        req="${req// /}"
        for prof in "${entry_profiles[@]}"; do
            if [[ "$prof" == "$req" ]]; then
                out+=("$req"); break
            fi
        done
    done
    (IFS=,; echo "${out[*]:-}")
}

run_one() {
    local scenario=$1
    local profile=$2
    local logfile="logs/vllm_smoke_${scenario}_${profile}.log"

    local -a cmd=(
        python orchestrator.py
        --scenario "$scenario"
        --profile "$profile"
        --runs "$RUNS_PER_SCENARIO"
        # vllm scenarios declare network_interface: lo themselves; pass
        # auto so the orchestrator picks that up rather than overriding.
        --interface auto
    )
    if [[ "$CAPTURE_PCAP" == "true" ]]; then
        cmd+=( --capture-pcap --capture-dir "$CAPTURE_DIR" )
        if [[ -n "$CAPTURE_FILTER" ]]; then
            cmd+=( --capture-filter "$CAPTURE_FILTER" )
        fi
    fi
    if (( RUN_TIMEOUT_SEC > 0 )); then
        cmd+=( --run-timeout "$RUN_TIMEOUT_SEC" )
    fi
    cmd+=( --stop-on-error )

    log_info "Running ${scenario} on profile ${profile}"
    cleanup_lo_state
    LAST_LOGFILE="$logfile"
    "${cmd[@]}" 2>&1 | tee "$logfile"
    local rc=${PIPESTATUS[0]}
    cleanup_lo_state
    return "$rc"
}

scenario_reported_failure() {
    local logfile=$1
    python - <<'PY' "$logfile"
from pathlib import Path
import re, sys

logfile = Path(sys.argv[1])
try:
    lines = logfile.read_text(errors="ignore").splitlines()
except Exception:
    raise SystemExit(1)

completed = [l for l in lines if "Completed: success=" in l]
if completed:
    last = completed[-1]
    m = re.search(r"Completed: success=(True|False)", last)
    if m and m.group(1) == "False":
        raise SystemExit(0)

if any(" - ERROR - " in l for l in lines):
    raise SystemExit(0)

raise SystemExit(1)
PY
}

extract_failure_summary() {
    local logfile=$1
    python - <<'PY' "$logfile"
from pathlib import Path
import re, sys

logfile = Path(sys.argv[1])
try:
    lines = logfile.read_text(errors="ignore").splitlines()
except Exception:
    print("unable to read failure log"); raise SystemExit(0)

patterns = [
    r"\bERROR\b", r"Completed: success=False", r"Traceback", r"Exception",
    r"failed", r"timed out", r"server_error", r"\b429\b", r"\b5\d\d\b",
]
matches = []
for line in lines:
    text = line.strip()
    if text and any(re.search(p, text, re.IGNORECASE) for p in patterns):
        if text not in matches:
            matches.append(text)
if matches:
    print(" | ".join(matches[-3:])[:800])
elif lines:
    tail = [l.strip() for l in lines[-5:] if l.strip()]
    print(" | ".join(tail)[:800] if tail else "non-zero exit without recognizable error")
else:
    print("non-zero exit without log output")
PY
}

# ==========================================================================
# Main
# ==========================================================================

parse_args "$@"

echo "========================================"
echo "vLLM Smoke Validation"
echo "========================================"
echo "Profiles:          $VALIDATION_PROFILES"
echo "Runs per scenario: $RUNS_PER_SCENARIO  (per profile)"
echo "Packet capture:    $CAPTURE_PCAP"
echo "Run timeout:       ${RUN_TIMEOUT_SEC}s"
echo "Manage vLLM:       $MANAGE_VLLM"
if [[ "$MANAGE_VLLM" == "true" ]]; then
    echo "vLLM backend:      $VLLM_BACKEND"
fi
echo "vLLM endpoint:     http://${VLLM_HOST}:${VLLM_PORT}"
if [[ "$MANAGE_VLLM" == "true" ]]; then
    echo "vLLM model:        $VLLM_MODEL"
    if [[ "$VLLM_BACKEND" == "docker" ]]; then
        echo "vLLM image:        $VLLM_IMAGE"
        echo "Container name:    $VLLM_CONTAINER_NAME"
    fi
fi
if [[ -n "$SCENARIO_FILTER" ]]; then
    echo "Scenario filter:   $SCENARIO_FILTER"
fi
echo ""

mkdir -p logs
if [[ "$CAPTURE_PCAP" == "true" ]]; then
    mkdir -p "$CAPTURE_DIR"
fi

# Trap registered BEFORE start_vllm_server so a Ctrl-C during the
# (possibly several-minute) model load still triggers stop_vllm_server.
trap cleanup_on_exit EXIT INT TERM

check_sudo
load_vllm_scenarios
load_requested_profiles

if ! start_vllm_server; then
    log_error "vLLM startup failed — aborting"
    exit 1
fi

log_phase "vLLM Local Inference Scenarios"

for entry in "${VLLM_ENTRIES[@]}"; do
    IFS=$'\t' read -r scenario runner_enabled scenario_disabled profiles_csv <<< "$entry"

    if [[ -n "$SCENARIO_FILTER" && "$scenario" != "$SCENARIO_FILTER" ]]; then
        continue
    fi

    if [[ "$scenario_disabled" == "true" ]]; then
        log_skip "$scenario — disabled in configs/scenarios.yaml"
        continue
    fi
    if [[ "$runner_enabled" != "true" ]]; then
        log_skip "$scenario — runner_enabled_by_default=false"
        continue
    fi

    applicable_csv=$(profiles_for_entry "$profiles_csv")
    if [[ -z "$applicable_csv" ]]; then
        log_skip "$scenario — matrix entry includes none of the requested profiles ($VALIDATION_PROFILES)"
        continue
    fi

    IFS=',' read -r -a applicable_profiles <<< "$applicable_csv"
    for prof in "${applicable_profiles[@]}"; do
        if run_one "$scenario" "$prof"; then
            if scenario_reported_failure "$LAST_LOGFILE"; then
                log_fail "${scenario}/${prof}" \
                    "$(extract_failure_summary "$LAST_LOGFILE")" "$LAST_LOGFILE"
            else
                log_pass "${scenario}/${prof}"
            fi
        else
            log_fail "${scenario}/${prof}" \
                "$(extract_failure_summary "$LAST_LOGFILE")" "$LAST_LOGFILE"
        fi
        echo ""
        sleep "$INTER_RUN_DELAY"
    done
done

echo "========================================"
echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${SKIP} skipped${NC}"

if [[ ${#FAILURES[@]} -gt 0 ]]; then
    echo ""
    echo -e "${RED}Failed runs:${NC}"
    for i in "${!FAILURES[@]}"; do
        echo "  - ${FAILURES[$i]}: ${FAILURE_DETAILS[$i]}"
        if [[ -n "${FAILURE_LOGS[$i]}" ]]; then
            echo "    log: ${FAILURE_LOGS[$i]}"
        fi
    done
    exit 1
fi

echo -e "${GREEN}vLLM smoke validation completed without failures.${NC}"
