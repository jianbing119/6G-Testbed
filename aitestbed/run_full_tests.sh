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
RUNS_PER_SCENARIO=${RUNS_PER_SCENARIO:-30}
INTER_SCENARIO_DELAY=${INTER_SCENARIO_DELAY:-2}  # Seconds between scenarios
INTER_PROVIDER_DELAY=${INTER_PROVIDER_DELAY:-5}  # Seconds between providers
TRACE_PAYLOADS=${TRACE_PAYLOADS:-1}
TRACE_LOG_DIR=${TRACE_LOG_DIR:-logs/traces}
CAPTURE_PCAP=${CAPTURE_PCAP:-true}  # Enable L3/L4 packet capture by default
CAPTURE_DIR=${CAPTURE_DIR:-results/captures}
CAPTURE_FILTER=${CAPTURE_FILTER:-"port 443 or port 80 or port 8080 or port 8000"}  # HTTPS, HTTP, proxy, and vLLM
ANONYMIZE_DB=${ANONYMIZE_DB:-true}  # Anonymize provider/model names by default
CLEAN_START=${CLEAN_START:-true}  # Start from a clean database by default
NETWORK_INTERFACE=${NETWORK_INTERFACE:-auto}  # Network interface for emulation + capture (auto = detect)
RUN_TIMEOUT_SEC=${RUN_TIMEOUT_SEC:-600}  # Per-run timeout in seconds (0 = no timeout)
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
    if curl -sf http://localhost:8000/v1/models > /dev/null 2>&1; then
        HAS_VLLM=true
        log_info "  + vLLM server reachable at localhost:8000"
    else
        log_warn "  - vLLM server not reachable (start with: docker run ... vllm/vllm-openai)"
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
    cleanup_network_state "${LAST_INTERFACE:-}"
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

# Run a single scenario with all its profiles
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
            --interface $scenario_interface"

        if [[ "$CAPTURE_PCAP" == "true" ]]; then
            cmd="$cmd --capture-pcap --capture-dir $CAPTURE_DIR"
            if [[ -n "$CAPTURE_FILTER" ]]; then
                cmd="$cmd --capture-filter '$CAPTURE_FILTER'"
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

        log_info "Cooling down for ${INTER_SCENARIO_DELAY}s..."
        sleep "$INTER_SCENARIO_DELAY"
    done
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
        phase_ran=true
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
        echo ""
    fi

    # Check prerequisites
    check_sudo || true

    # Check optional prerequisites
    if [[ "$QUIET_MODE" != "true" ]]; then
        check_optional_prereqs
    else
        check_optional_prereqs > /dev/null 2>&1
    fi
    load_test_matrix

    mkdir -p logs
    trap cleanup_on_exit EXIT INT TERM

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
    # Network Profiles referenced by configs/scenarios.yaml:test_matrix:
    # - no_emulation: reference case with no tc/netem impairment
    # - ideal_6g:   1ms delay, 0% loss, unlimited BW (baseline)
    # - 5g_urban:   20ms delay, 0.1% loss, 100Mbit
    # - wifi_good:  30ms delay, 0.1% loss, 50Mbit
    # - cell_edge:  120ms delay, 1% loss, 5Mbit
    # - satellite:  600ms delay, 0.5% loss, 10Mbit
    # - congested:  200ms delay, 3% loss, 1Mbit
    # - 5qi_7:      100ms delay, 0.1% loss (Voice/Live Streaming)
    # - 5qi_80:     10ms delay, 0.0001% loss (Low-latency eMBB/AR)
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
            echo "  RUN_TIMEOUT_SEC          Per-run timeout in seconds (default: 600, 0 = no timeout)"
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
