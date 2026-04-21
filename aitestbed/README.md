# 6G AI Traffic Characterization Testbed

A testbed for measuring AI/LLM service traffic patterns under emulated network conditions, aligned with **3GPP SA4 6G Media Study** objectives.

## Overview

The testbed enables:

- **Measurement** of traffic characteristics across generative AI services (chat, image, video, realtime voice)
- **Analysis** of agentic AI patterns (multi-step tool calling via MCP, browser automation, market data)
- **Evaluation** of QoE metrics under emulated network conditions (latency, loss, bandwidth)
- **Reporting** in formats suitable for 3GPP standardization contributions

## Scenarios

### Chat

| Scenario | Provider | Model | Streaming | Description |
|:---------|:---------|:------|:----------|:------------|
| `chat_basic` | OpenAI | gpt-5-mini | No | Single-turn chat |
| `chat_streaming` | OpenAI | gpt-5-mini | Yes | Multi-turn streaming chat |
| `chat_gemini` | Gemini | gemini-3-flash-preview | Yes | Gemini chat |
| `chat_deepseek` | DeepSeek | deepseek-chat | No | DeepSeek chat |
| `chat_deepseek_streaming` | DeepSeek | deepseek-chat | Yes | DeepSeek streaming chat |
| `chat_deepseek_coder` | DeepSeek | deepseek-coder | Yes | Code-focused chat |
| `chat_deepseek_reasoner` | DeepSeek | deepseek-reasoner | Yes | Deep reasoning chat (R1) |
| `chat_vllm` | vLLM | Qwen3-VL-30B-A3B | Yes | Self-hosted model (loopback) |

### Agentic AI (MCP Tool Calling)

| Scenario | Provider | Model | MCP Server Group | Description |
|:---------|:---------|:------|:-----------------|:------------|
| `shopping_agent` | OpenAI | gpt-5-mini | shopping | Shopping assistant with product search |
| `shopping_agent_deepseek` | DeepSeek | deepseek-chat | shopping | Shopping assistant (DeepSeek) |
| `web_search_agent` | OpenAI | gpt-5-mini | web_research | Research agent with web search |
| `web_search_agent_deepseek` | DeepSeek | deepseek-chat | web_research | Research agent (DeepSeek) |
| `general_agent` | OpenAI | gpt-5.2 | general | General-purpose agent (all tools) |
| `trading_market_data` | OpenAI | gpt-5-mini | trading | Market data analysis (Alpaca) |
| `trading_options_scan` | OpenAI | gpt-5-mini | trading | Options market scan (Alpaca) |
| `music_search` | OpenAI | gpt-5-mini | music | Spotify music search |
| `music_playlist` | OpenAI | gpt-5-mini | music | Playlist composition |
| `music_research` | OpenAI | gpt-5-mini | music_research | Spotify + web search |
| `music_search_deepseek` | DeepSeek | deepseek-chat | music | Music search (DeepSeek) |

### Browser Automation

| Scenario | Provider | Model | Description |
|:---------|:---------|:------|:------------|
| `computer_control_agent` | OpenAI | computer-use-preview | OpenAI computer use tool |
| `playwright_web_test` | OpenAI | gpt-5-mini | Playwright MCP (with screenshots) |
| `playwright_web_test_text` | OpenAI | gpt-5-mini | Playwright MCP (text extraction only) |

### Image & Multimodal

| Scenario | Provider | Model | Description |
|:---------|:---------|:------|:------------|
| `image_generation` | OpenAI | gpt-image-1.5 | DALL-E image generation |
| `multimodal_analysis` | Gemini | gemini-3-flash-preview | Image + text analysis |
| `video_understanding_vllm` | vLLM | Qwen3-VL-30B-A3B | Video understanding (loopback) |

### Realtime Conversational AI (OpenAI Realtime API)

| Scenario | Transport | Modalities | Voice | Description |
|:---------|:----------|:-----------|:------|:------------|
| `realtime_text` | WebSocket | text + audio | alloy | Text-mode realtime |
| `realtime_text_webrtc` | WebRTC | text | alloy | Text-mode via WebRTC |
| `realtime_interactive` | WebSocket | text + audio | shimmer | Voice assistant simulation |
| `realtime_technical` | WebSocket | text + audio | echo | Technical support conversation |
| `realtime_multilingual` | WebSocket | text + audio | coral | Multilingual conversation |
| `realtime_audio` | WebSocket | text + audio | sage | Voice in/out with TTS |
| `realtime_audio_webrtc` | WebRTC | text + audio | sage | Voice in/out via WebRTC |

### Direct Web Search (No MCP)

| Scenario | Engine | Threads | LLM Synthesis | Description |
|:---------|:-------|:--------|:--------------|:------------|
| `direct_web_search` | DuckDuckGo | 5 | Yes (OpenAI) | Multi-threaded search |
| `direct_web_search_deepseek` | DuckDuckGo | 5 | Yes (DeepSeek) | Multi-threaded search |
| `direct_web_search_google` | Google | 5 | Yes | Google Custom Search API |
| `direct_web_search_burst` | DuckDuckGo | 20 | No | Burst stress test |
| `parallel_search_benchmark` | DuckDuckGo | 1-20 | No | Parallelism benchmark |

### Azure (Disabled by Default)

| Scenario | Provider | Model | Description |
|:---------|:---------|:------|:------------|
| `chat_azure_openai` | Azure OpenAI | gpt-5.2 | Azure-hosted GPT |
| `chat_azure_openai_streaming` | Azure OpenAI | gpt-5.2 | Azure-hosted GPT (streaming) |
| `shopping_agent_azure_openai` | Azure OpenAI | gpt-5.2 | Shopping agent via Azure |
| `image_generation_azure` | Azure OpenAI | gpt-image-1-mini | Image generation via Azure |
| `chat_azure_inference` | Azure Inference | Phi-4-mini | Phi-4 chat |
| `chat_azure_inference_streaming` | Azure Inference | Phi-4-mini | Phi-4 streaming |
| `chat_azure_inference_llama` | Azure Inference | Llama-4-Maverick | Llama 4 streaming |

## Network Profiles

The test matrix uses 9 selected profiles from `configs/profiles.yaml`:

| Profile | Delay | Jitter | Loss | Rate | Loss Model | Description |
|:--------|:------|:-------|:-----|:-----|:-----------|:------------|
| `no_emulation` | 0 ms | 0 ms | 0% | -- | -- | Reference (no tc/netem) |
| `ideal_6g` | 1 ms | 0 ms | 0% | -- | fixed | Deterministic baseline |
| `5g_urban` | 20 ms | 5 ms | 0.1% | 100 Mbps | correlated | Mainstream terrestrial cellular |
| `wifi_good` | 30 ms | 10 ms | 0.1% | 50 Mbps | correlated | Home/office WiFi |
| `cell_edge` | 120 ms | 30 ms | 1% | 5 Mbps | Gilbert-Elliot | Poor coverage, heavy-tail jitter |
| `satellite` | 600 ms | 50 ms | 0.5% | 10 Mbps | Gilbert-Elliot | LEO satellite |
| `congested` | 200 ms | 50 ms | 3% | 1 Mbps | Gilbert-Elliot | Bufferbloat / heavy congestion |
| `5qi_7` | 100 ms | 10 ms | 0.1% | -- | correlated | 5QI 7: voice / live streaming |
| `5qi_80` | 10 ms | 1 ms | 0.0001% | -- | correlated | 5QI 80: low-latency eMBB/AR |

Profiles include advanced netem controls: `delay_distribution`, `loss_correlation_pct`, `reorder_pct`, `duplicate_pct`, and `limit_packets`. See `configs/profiles.yaml` for full definitions.

Bidirectional shaping is applied by default using IFB devices:

```bash
# Symmetric (default)
python orchestrator.py --scenario chat_basic --profile cell_edge

# Egress-only
python orchestrator.py --scenario chat_basic --profile cell_edge --egress-only

# Asymmetric
python orchestrator.py --scenario chat_basic --profile 5g_urban --ingress-profile satellite
```

## Test Matrix

The full test matrix runs each scenario against all 9 selected profiles. Defined in `configs/scenarios.yaml` under `test_matrix:`.

| Phase | Scenarios | Priority | Prerequisites |
|:------|:----------|:---------|:--------------|
| chat | `chat_basic`, `chat_streaming` | high | OPENAI_API_KEY |
| realtime | `realtime_text`, `realtime_interactive`, `realtime_technical`, `realtime_multilingual`, `realtime_audio`, `realtime_audio_webrtc`, `realtime_text_webrtc` | high/medium | OPENAI_API_KEY |
| image | `image_generation` | medium | OPENAI_API_KEY |
| search | `direct_web_search` | high | OPENAI_API_KEY |
| deepseek | `chat_deepseek`, `chat_deepseek_streaming`, `chat_deepseek_coder`, `chat_deepseek_reasoner`, `direct_web_search_deepseek` | high/medium | DEEPSEEK_API_KEY |
| gemini | `chat_gemini` | medium | GOOGLE_API_KEY |
| trading | `trading_market_data`, `trading_options_scan` | medium | ALPACA_API_KEY, ALPACA_SECRET_KEY |
| computer_use | `computer_control_agent` | medium | Playwright + Chromium |
| playwright | `playwright_web_test` | medium | Playwright + Chromium |
| multimodal | `multimodal_analysis` | medium | GOOGLE_API_KEY + image assets |
| vllm | `chat_vllm`, `video_understanding_vllm` | high | vLLM server on localhost:8000 |
| stress | `direct_web_search_burst`, `parallel_search_benchmark` | medium/low | Disabled by default |

```bash
# Run the full matrix
python orchestrator.py --scenario all --runs 10

# Run a single scenario across all profiles
python orchestrator.py --scenario chat_basic --profile all --runs 10

# Quick test
python orchestrator.py --scenario chat_basic --profile 5g_urban --runs 5
```

## Metrics

See [METRICS.md](METRICS.md) for full documentation. Summary:

- **QoE**: TTFT, TTLT, tail percentiles (P50/P95/P99), session completion rate
- **Traffic**: UL/DL byte volumes, UL/DL ratio, token streaming rate, burstiness descriptors, stall rate
- **AI Service**: Agent loop factor, tool call latency, multi-step completion time, error taxonomy

## MCP Server Groups

Agent scenarios use MCP servers defined in `configs/mcp_servers.yaml`:

| Group | Servers | Used By |
|:------|:--------|:--------|
| `shopping` | brave-search, fetch | Shopping agent scenarios |
| `web_research` | brave-search, fetch, memory | Web search agent scenarios |
| `music` | spotify | Music search/playlist scenarios |
| `music_research` | spotify, brave-search, fetch | Music research scenarios |
| `trading` | alpaca | Trading/market data scenarios |
| `playwright` | playwright | Browser automation scenarios |
| `general` | All servers | General agent scenario |

All MCP servers support HTTP transport for traffic measurement via loopback (subject to tc/netem shaping).

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     Scenario Orchestrator                        │
│                      (orchestrator.py)                           │
└─────────────────────────┬───────────────────────────────────────┘
                          │
        ┌─────────────────┼─────────────────┐
        │                 │                 │
        ▼                 ▼                 ▼
┌───────────────┐ ┌───────────────┐ ┌───────────────┐
│  Chat         │ │  Agent        │ │  Realtime     │
│  Scenarios    │ │  Scenarios    │ │  Scenarios    │
└───────┬───────┘ └───────┬───────┘ └───────┬───────┘
        │                 │                 │
        │                 │ MCP Protocol    │ WebSocket/WebRTC
        │                 ▼                 │
        │    ┌────────────────────────┐     │
        │    │    MCP Tool Servers    │     │
        │    │  brave-search, fetch,  │     │
        │    │  filesystem, memory,   │     │
        │    │  spotify, playwright,  │     │
        │    │  alpaca                │     │
        │    └───────────┬────────────┘     │
        │                │                  │
        └────────────────┼──────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│                      LLM Client Layer                           │
│  ┌────────┬────────┬──────────┬──────┬───────────┬───────────┐  │
│  │ OpenAI │ Gemini │ DeepSeek │ vLLM │ Azure OAI │ Azure Inf │  │
│  └────────┴────────┴──────────┴──────┴───────────┴───────────┘  │
└─────────────────────────┬───────────────────────────────────────┘
                          │ HTTPS / WebSocket / WebRTC
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                   Network Emulator (tc/netem)                    │
│       Bandwidth │ Latency │ Jitter │ Loss │ Reorder │ Corrupt   │
└─────────────────────────┬───────────────────────────────────────┘
                          │
                          ▼
                    ┌───────────┐
                    │  Internet │ → LLM APIs + Tool APIs
                    └───────────┘

┌─────────────────────────────────────────────────────────────────┐
│                     Capture & Analysis                           │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐           │
│  │  L3/L4   │ │   L7     │ │  SQLite  │ │  Metrics │           │
│  │ tcpdump  │ │ mitmproxy│ │  Logger  │ │  + Plots │           │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘           │
└─────────────────────────────────────────────────────────────────┘
```

## Installation

### Prerequisites

- Python 3.10+
- Node.js 18+ (for MCP servers)
- Linux with `iproute2` (for network emulation)
- `tcpdump` (for PCAP capture)
- Sudo access or Docker with `NET_ADMIN`

### Setup

```bash
cd <repo-root>
python -m venv venv
source venv/bin/activate

# Install netemu (sibling package)
pip install -e netemu

# Install testbed dependencies
pip install -r aitestbed/requirements.txt

# Install npm-based MCP servers
npm install -g @modelcontextprotocol/server-brave-search
npm install -g @modelcontextprotocol/server-filesystem
npm install -g @modelcontextprotocol/server-memory
```

### API Keys

```bash
export OPENAI_API_KEY="sk-..."          # OpenAI scenarios
export GOOGLE_API_KEY="..."             # Gemini scenarios
export DEEPSEEK_API_KEY="..."           # DeepSeek scenarios
export BRAVE_API_KEY="..."              # Agent scenarios (web search)
export SPOTIFY_CLIENT_ID="..."          # Music agent scenarios
export SPOTIFY_CLIENT_SECRET="..."      # Music agent scenarios
export ALPACA_API_KEY="..."             # Trading scenarios
export ALPACA_SECRET_KEY="..."          # Trading scenarios
```

Or copy `.env.example` to `.env` and fill in values.

### Sudoers (for Network Emulation)

```bash
TCPDUMP_PATH=$(which tcpdump)
echo "$USER ALL=(ALL) NOPASSWD: /usr/sbin/tc, $TCPDUMP_PATH, /usr/sbin/modprobe, /usr/sbin/ip" \
  | sudo tee /etc/sudoers.d/testbed
sudo chmod 440 /etc/sudoers.d/testbed
```

### vLLM (Self-Hosted Models)

Two ways to run the vLLM server. **Docker is recommended** — the
`vllm/vllm-openai` image bundles the right CUDA runtime and Python, so it
sidesteps `libcudart.so.12` and Python-version compatibility issues typical
of a host-pip install.

#### Docker (recommended)

Requires Docker, the NVIDIA driver, and `nvidia-container-toolkit`. Add
yourself to the `docker` group so you can manage containers without `sudo`:

```bash
sudo usermod -aG docker $USER
newgrp docker                     # or log out / log back in

# Sanity-check GPU passthrough before running scenarios:
docker run --rm --gpus all nvidia/cuda:12.6.0-base-ubuntu22.04 nvidia-smi
```

Launch the vLLM server:

```bash
docker run -d --name vllm-testbed --gpus all --ipc=host \
    -v ~/.cache/huggingface:/root/.cache/huggingface \
    -p 127.0.0.1:8000:8000 \
    vllm/vllm-openai:latest \
    --model Qwen/Qwen3-VL-30B-A3B-Instruct \
    --max-model-len 131072 --gpu-memory-utilization 0.95 \
    --trust-remote-code --tensor-parallel-size 1

# Stop / remove when done:
docker stop vllm-testbed && docker rm vllm-testbed
```

Then run the testbed with `MANAGE_VLLM=false` so the scripts probe the
already-running container instead of trying to spawn another:

```bash
MANAGE_VLLM=false ./run_full_tests.sh
MANAGE_VLLM=false ./test_vllm.sh
```

#### Host pip install (fallback — auto-managed by the scripts)

```bash
pip install vllm
vllm serve Qwen/Qwen3-VL-30B-A3B-Instruct \
    --host 0.0.0.0 --port 8000 \
    --tensor-parallel-size 1 --max-model-len 131072 \
    --gpu-memory-utilization 0.95 --trust-remote-code
```

`run_full_tests.sh` and `test_vllm.sh` default to `MANAGE_VLLM=true`, which
auto-starts and stops a host `vllm serve` process for you.

vLLM scenarios use `network_interface: lo` to shape loopback traffic.

## Usage

```bash
# List scenarios and profiles
python orchestrator.py --list-scenarios
python orchestrator.py --list-profiles

# Single scenario
python orchestrator.py --scenario chat_basic --profile 5g_urban --runs 10

# Full test matrix
python orchestrator.py --scenario all --runs 10

# With PCAP capture
python orchestrator.py --scenario chat_basic --profile 5g_urban --runs 10 --capture-pcap

# Custom paths
python orchestrator.py \
    --scenario chat_basic \
    --profile 5g_urban \
    --config configs/scenarios.yaml \
    --profiles configs/profiles.yaml \
    --db logs/traffic_logs.db \
    --report results/reports/experiment_report.json
```

### Programmatic

```python
from orchestrator import TestbedOrchestrator

orchestrator = TestbedOrchestrator()
results = orchestrator.run_experiment("chat_streaming", "5g_urban", runs=10)

for r in results:
    print(f"Latency: {r.total_latency_sec:.2f}s  TTFT: {r.ttft_sec:.3f}s")
```

## Docker

```bash
# Build (from repo root)
docker build -t 6g-ai-testbed:latest -f aitestbed/Dockerfile .

# Run
docker run --rm --cap-add=NET_ADMIN \
    -e OPENAI_API_KEY="sk-..." \
    -v $(pwd)/logs:/app/logs \
    -v $(pwd)/results/reports:/app/results/reports \
    6g-ai-testbed:latest \
    python orchestrator.py --scenario chat_basic --profile 5g_urban --runs 10

# Interactive shell
docker run -it --rm --cap-add=NET_ADMIN \
    -e OPENAI_API_KEY="sk-..." \
    6g-ai-testbed:latest --shell

# Docker Compose
docker compose up -d testbed
docker compose run testbed python orchestrator.py --scenario all --runs 10

# Makefile shortcuts
make build          # Build image
make test           # Quick test
make shell          # Interactive shell
make all            # Run all scenarios
```

### Persistent Data Volumes

```
logs:/app/logs                              # SQLite logs
results/reports:/app/results/reports        # JSON/Markdown reports
results/captures:/app/results/captures      # PCAP files
results/l7_captures:/app/results/l7_captures  # L7 HTTP logs
```

## Output

- **SQLite** (`logs/traffic_logs.db`) — per-request records with timestamps, bytes, tokens, TTFT/TTLT
- **JSON report** (`results/reports/experiment_report.json`) — aggregated metrics in 3GPP-compatible format
- **Markdown tables** (`results/reports/experiment_tables.md`) — QoE and traffic summaries
- **Plots** (`results/reports/figures/`) — latency CDFs, UL/DL ratios, success rates

## Extending

### New Scenario

1. Subclass `BaseScenario` in `scenarios/`
2. Register in `scenarios/__init__.py`
3. Add config in `configs/scenarios.yaml`

### New LLM Provider

1. Subclass `LLMClient` in `clients/`
2. Register in `clients/__init__.py`
3. Add to orchestrator's client factory

## References

- [3GPP TR 26.870](https://www.3gpp.org/): 6G Media Study
- [3GPP TR 22.870](https://www.3gpp.org/): Service requirements for 6G
- [OpenAI API](https://platform.openai.com/docs/api-reference)
- [Google Gemini API](https://ai.google.dev/gemini-api/docs)
- [Linux tc(8)](https://man7.org/linux/man-pages/man8/tc.8.html)
