# SRE Latency Monitor — Claude Code Plugin

Measure and compare Claude API performance across **Anthropic Direct API** and **AWS Bedrock** directly from Claude Code. Pure bash/jq/curl/perl — zero Python dependency.

## What It Measures

| Metric | Description |
|--------|-------------|
| **TTFB** (Time to First Byte) | Network round-trip time to the API endpoint |
| **TTFT** (Time to First Token) | How long until the first content token streams back |
| **Server Latency** | Server-side processing time (Bedrock `metrics.latencyMs`) |
| **Generation Time** | Token streaming duration after first token |
| **Output Throughput** | Tokens generated per second |
| **Percentiles** | P50, P90, P95, P99 for all timing metrics |
| **Tool Budget** | Time breakdown: Model vs Bash vs MCP vs CLI tools |

## Commands

### `/sre-latency:benchmark`

Full benchmark comparing both providers with statistical analysis.

```
/sre-latency:benchmark -n 10 --prompt-size medium --output results.json
/sre-latency:benchmark --providers anthropic-direct -n 20
```

### `/sre-latency:latency-check`

Quick single-request probe for spot-checking.

```
/sre-latency:latency-check both
/sre-latency:latency-check direct
/sre-latency:latency-check bedrock
```

### `/sre-latency:report`

Generate formatted reports from saved benchmark data.

```
/sre-latency:report results.json
```

### `/sre-latency:grade`

Grade benchmark results against SLO thresholds (A-F).

```
/sre-latency:grade results.json
```

### `/sre-latency:tool-timings`

View categorized time-spent analysis — Model vs Tools vs MCP breakdown.

```
/sre-latency:tool-timings
```

### `/sre-latency:compare`

Side-by-side comparison of multiple benchmark runs.

```
/sre-latency:compare results/budget-run1.json results/budget-run2.json
/sre-latency:compare results/ --latest 3
```

## Session Benchmark

Compare real Claude Code coding sessions across providers:

```bash
scripts/session_benchmark.sh --task simple --output results/session.json
scripts/session_benchmark.sh --task medium
scripts/session_benchmark.sh --task complex --model opus
```

Task levels:
- **simple** — Write a function + verify (~2 tool calls)
- **medium** — Write a module with tests (~5-8 tool calls)
- **complex** — Read existing code, refactor, add tests (~10-15 tool calls)

## Auto-Invoked Skill

The **latency-advisor** skill activates automatically when you discuss latency issues, Bedrock performance, or TTFT optimization. It provides SRE-focused guidance.

## Prerequisites

```bash
# Required tools (all standard on macOS/Linux)
# bash, jq, curl, perl, bc

# Anthropic Direct API
export ANTHROPIC_API_KEY=sk-ant-...

# AWS Bedrock (configure at least one)
export AWS_REGION=us-east-1
# Plus standard AWS credentials (aws configure, env vars, or SSO)
```

## Installation

```bash
# Load locally during development
claude --plugin-dir ./sre-latency-monitor

# Or install from a marketplace
/plugin install sre-latency@your-marketplace
```

## Statusline

The plugin includes a statusline script that displays real-time tool latency in the Claude Code status bar:

```
Model 12.4s | Bash 2x 3.1s | CLI 4x 0.5s | MCP 1x 0.8s
```

## SLO Grading

Assigns letter grades (A-F) based on configurable SLO thresholds:

| Grade | TTFT P50 | TTFT P99 | Throughput Mean | Error Rate |
|-------|----------|----------|-----------------|------------|
| A     | ≤ 500ms  | ≤ 1500ms | ≥ 80 t/s        | 0%         |
| B     | ≤ 800ms  | ≤ 2500ms | ≥ 60 t/s        | ≤ 1%       |
| C     | ≤ 1200ms | ≤ 4000ms | ≥ 40 t/s        | ≤ 5%       |
| D     | ≤ 2000ms | ≤ 6000ms | ≥ 20 t/s        | ≤ 10%      |
| F     | > 2000ms | > 6000ms | < 20 t/s        | > 10%      |

## Findings: Why Bedrock Feels Slow

### The Root Cause: Fixed Per-Request Overhead

Bedrock adds **~554ms of fixed overhead per API call** — from AWS network routing and the Bedrock invocation layer. This overhead exists even with **no Guardrails configured**.

Adding a Guardrail (content filter) adds another **~800ms** on top:

| Configuration | Total (avg) | Server Latency | Overhead vs Direct |
|--------------|-------------|----------------|-------------------|
| **Direct API** | 581ms | — | baseline |
| **Bedrock (no guardrail)** | 1,135ms | 782ms | **+554ms (+95%)** |
| **Bedrock (+ guardrail)** | 1,936ms | 1,555ms | **+1,355ms (+233%)** |
| Guardrail delta | — | — | **+802ms (+772ms server-side)** |

*Measured on Haiku 4.5 with content filter (sexual, violence, hate, insults, misconduct, prompt attack), N=5.*

The base Bedrock overhead impact depends on model speed:

| Model | Direct API | Bedrock (no guardrail) | Overhead | Impact |
|-------|-----------|------------------------|----------|--------|
| **Haiku 4.5** | 581ms | 1,135ms | **+95%** | Severe |
| **Sonnet 4.5** | ~30s | ~34s | **+13%** | Noticeable |
| **Opus 4.6** | 49.1s | 48.1s | **-2%** | Negligible |

For Opus, 554ms is noise on a 50-second call. For Haiku, it nearly doubles every call.

### How Claude Code Uses Models (Inferred)

> **Note:** The model routing behavior below is inferred from observed patterns, not directly measured. Our hooks capture tool calls but not which model is used per turn. Claude Code's internal routing may change between versions.

Claude Code appears to use a **multi-model routing strategy**:

- **Haiku** — Quick decisions: tool selection, context summarization, simple follow-ups. *Frequent and latency-sensitive.*
- **Sonnet** — Standard coding tasks: writing code, editing files, running tests. The workhorse (confirmed as default via `--model` inspection).
- **Opus** — Complex reasoning: architecture decisions, multi-step refactors, debugging hard problems.

A typical coding session likely involves many small Haiku calls for routing/summarization plus a few larger Sonnet/Opus calls for the actual work.

### The Compounding Effect (Illustrative)

> **Note:** The example below is illustrative, not measured from an actual session trace. It demonstrates the *mechanism* by which Bedrock overhead compounds, using our measured per-call latencies.

If a session makes multiple Haiku calls internally, the overhead compounds:

```
                        Direct API              Bedrock (no guardrail)
8x Haiku calls:         8 x 581ms  = 4.6s      8 x 1,135ms = 9.1s
3x Sonnet calls:        3 x 30s    = 90.0s     3 x 34s     = 102.0s
                        ──────────              ──────────
Total:                  ~94.6s                  ~111.1s  (+17%)
```

The Haiku overhead alone would account for ~4.5 seconds of extra latency. With Guardrails enabled, it would be ~10.8 seconds. It's not any single call being slow — it's death by a thousand cuts on the fast model calls.

### Benchmark Results

#### Raw API Latency Budget (Haiku 4.5, 5 iterations)

| Provider | Total (avg) | Server Latency | Overhead |
|----------|------------|----------------|----------|
| Direct API | 581ms | — | baseline |
| Bedrock (no guardrail) | 1,135ms | 782ms | **+95%** |
| Bedrock (+ guardrail) | 1,936ms | 1,555ms | **+233%** |

#### Session Benchmark: Sonnet 4.5 (auto-selected, medium task)

Real Claude Code session — Calculator class + pytest tests:

| Provider | Total Session | Model Time | Tool Time | Tool Calls |
|----------|--------------|------------|-----------|------------|
| Direct | 1.5m | 1.4m | 3.5s | 3 |
| Bedrock | 1.7m | 1.6m | 4.3s | 7 |
| Delta | **+13.3%** | +13.0% | +21.8% | — |

#### Session Benchmark: Opus 4.6 (explicit, medium task)

| Provider | Total Session | Model Time | Tool Time | Tool Calls |
|----------|--------------|------------|-----------|------------|
| Direct | 1.7m | 1.7m | 4.2s | 10 |
| Bedrock | 1.4m | 1.3m | 2.7s | 8 |
| Delta | **-21%** | -20.3% | -37.1% | — |

Opus 4.6 on Bedrock was faster in this run. One possible explanation: Bedrock's non-streaming response may avoid per-token streaming overhead, benefiting slower models. However, N=1 session benchmarks have high variance — this result should be validated with multiple runs.

#### Session Benchmark: Opus 4.6 (simple task)

| Provider | Total Session | Model Time | Tool Calls |
|----------|--------------|------------|------------|
| Direct | 49.1s | 47.7s | 2 |
| Bedrock | 48.1s | 46.2s | 2 |
| Delta | **-2.1%** | -3.2% | — |

### Key Takeaways

1. **Bedrock's ~554ms base overhead is the bottleneck** — not model inference speed. This exists with zero Guardrails configured. (Measured, N=5.)
2. **Guardrails add ~800ms more** (772ms server-side). A content filter nearly doubles Bedrock latency on fast models. (Measured, N=5.)
3. **Haiku is disproportionately affected** (+95% without guardrails, +233% with) because the overhead approaches or exceeds the model's own response time. (Measured.)
4. **Opus is unaffected or faster** on Bedrock because the fixed overhead is negligible relative to inference time. (Measured, but session benchmarks are N=1.)
5. **The perceived slowness of Bedrock in Claude Code** likely comes from compounding overhead across many internal API calls, not from the primary coding model being slow. (Inferred from per-call measurements, not directly traced.)
6. **No default Guardrails exist** — AWS accounts don't ship with guardrails pre-configured. The base Bedrock overhead is purely invocation-layer.

### Methodology Limitations

- **Raw API benchmarks** (latency_budget.sh): N=5 iterations after 2 warmup discards. Statistically limited but consistent across runs.
- **Session benchmarks** (session_benchmark.sh): N=1 per configuration. High variance — individual results should be treated as directional, not definitive.
- **Model routing**: We confirmed Sonnet 4.5 as Claude Code's default on Bedrock, but cannot directly observe internal Haiku routing calls.
- **All tests from a single location**: Seths-MacBook-Pro, US East. Results will vary by network and region.

### Bedrock Model IDs

Bedrock Opus 4.6 requires inference profile IDs rather than direct model IDs:

| Model | Direct API ID | Bedrock Inference Profile ID |
|-------|--------------|------------------------------|
| Opus 4.6 | `claude-opus-4-6` | `us.anthropic.claude-opus-4-6-v1` |
| Sonnet 4.5 | `claude-sonnet-4-5-20250929` | `us.anthropic.claude-sonnet-4-5-20250929-v1:0` |
| Haiku 4.5 | `claude-haiku-4-5-20251001` | `us.anthropic.claude-haiku-4-5-20251001-v1:0` |

The session benchmark script handles this automatically with `--model opus`.

## Architecture

```
sre-latency-monitor/
├── .claude-plugin/plugin.json        # Plugin manifest (v2.2.0)
├── commands/
│   ├── benchmark.md                  # /sre-latency:benchmark
│   ├── compare.md                    # /sre-latency:compare
│   ├── grade.md                      # /sre-latency:grade
│   ├── latency-budget.md             # /sre-latency:latency-budget
│   ├── latency-check.md              # /sre-latency:latency-check
│   ├── report.md                     # /sre-latency:report
│   └── tool-timings.md               # /sre-latency:tool-timings
├── hooks/
│   ├── hooks.json                    # Tool call latency logging
│   └── log_tool_latency.sh           # Hook script
├── results/                          # Benchmark results (JSON)
├── scripts/
│   ├── benchmark.sh                  # Core benchmark engine
│   ├── compare.sh                    # Multi-run comparison
│   ├── grade.sh                      # SLO grading
│   ├── latency_budget.sh             # Latency budget breakdown
│   ├── latency_check.sh              # Quick probe
│   ├── report.sh                     # Report formatter
│   ├── session_benchmark.sh          # Real Claude Code session comparison
│   └── statusline.sh                 # Statusline display
└── skills/
    └── latency-advisor/              # Auto-invoked latency advice
```

## License

MIT
