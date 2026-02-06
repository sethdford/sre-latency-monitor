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
[D] Sonnet 4.5 | Ctx 45% | $0.15 | 5m30s | Bash:2m CLI:30s [2m30s tools] | TTFT 450ms
```

Provider indicators: `[D]` = Direct API, `[BR]` = Bedrock, `[VX]` = Vertex.

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

### The Root Cause: Per-Request Overhead

Bedrock adds measurable per-request overhead from AWS network routing and the Bedrock invocation layer. This overhead exists even with **no Guardrails configured**.

We measured this overhead across two independent test runs on Haiku 4.5 (the fastest model, where overhead is most visible):

| Run | Direct API (avg) | Bedrock (avg) | Overhead |
|-----|-----------------|---------------|----------|
| Guardrail benchmark (N=5) | 581ms | 1,135ms | **+554ms (+95%)** |
| Latency budget (N=5) | 568ms | 1,402ms | **+834ms (+147%)** |

*Both runs: Haiku 4.5, "count 1-20" prompt, max_tokens=128. Run-to-run variance is significant with N=5.*

The measured overhead ranges from **~550–850ms per call**. This variance is expected with small sample sizes and network conditions. The key finding is directional: Bedrock consistently adds hundreds of milliseconds of per-request overhead.

### Guardrail Impact

Adding a Guardrail (content filter) adds another **~800ms** on top of the base Bedrock overhead:

| Configuration | Total (avg) | Server Latency | Overhead vs Direct |
|--------------|-------------|----------------|-------------------|
| **Direct API** | 581ms | — | baseline |
| **Bedrock (no guardrail)** | 1,135ms | 782ms | **+554ms (+95%)** |
| **Bedrock (+ guardrail)** | 1,936ms | 1,555ms | **+1,355ms (+233%)** |
| Guardrail delta | — | — | **+802ms (+772ms server-side)** |

*Measured on Haiku 4.5 with content filter (sexual, violence, hate, insults, misconduct, prompt attack), N=5, single run. No default Guardrails exist — AWS accounts don't ship with guardrails pre-configured.*

### Impact by Model Speed

The overhead impact depends on the model's own response time:

#### Raw API Per-Call Latency (latency_budget.sh, N=5, "count 1-20" prompt)

| Model | Direct API (avg) | Bedrock (avg) | Overhead |
|-------|-----------------|---------------|----------|
| **Haiku 4.5** | 568ms | 1,402ms | **+147%** |
| **Opus 4.6** | 1,891ms | 1,830ms | **-3.2%** |

*Sonnet 4.5 per-call data was not collected. Haiku data from `budget-direct-vs-bedrock-20260205-235937.json`, Opus from `budget-opus46-20260206-000119.json`.*

For Haiku, the overhead more than doubles each call. For Opus, the overhead is within noise — Bedrock was actually marginally faster in this run, likely because the non-streaming `converse` API avoids per-token streaming overhead that benefits slower models.

### Session Benchmarks

Real Claude Code sessions running identical coding tasks on both providers. Each session uses `claude -p` with `--dangerously-skip-permissions` for non-interactive execution.

> **Note:** All session benchmarks are N=1 per configuration. High variance is expected — treat individual results as directional, not definitive.

#### Sonnet 4.5 (auto-selected, simple task)

Fibonacci function + verify:

| Provider | Total Session | Model Time | Tool Calls |
|----------|--------------|------------|------------|
| Direct | 48.4s | 46.9s | 2 |
| Bedrock | 48.6s | 46.8s | 2 |
| Delta | **+0.3%** | -0.3% | — |

*From `session-simple-20260206-005840.json`.*

#### Sonnet 4.5 (auto-selected, medium task)

Calculator class + pytest tests:

| Provider | Total Session | Model Time | Tool Time | Tool Calls |
|----------|--------------|------------|-----------|------------|
| Direct | 1.5m | 1.4m | 3.5s | 3 |
| Bedrock | 1.7m | 1.6m | 4.3s | 7 |
| Delta | **+13.3%** | +13.0% | +21.8% | — |

*From `session-medium-20260206-010024.json`.*

#### Sonnet 4.5 (auto-selected, complex task)

Read legacy code, refactor into DataProcessor class + tests:

| Provider | Total Session | Model Time | Tool Time | Tool Calls |
|----------|--------------|------------|-----------|------------|
| Direct | 2.5m | 2.5m | 4.9s | 9 |
| Bedrock | 2.5m | 2.5m | 3.4s | 13 |
| Delta | **-0.4%** | +0.6% | -30.1% | — |

*From `session-complex-20260206-064530.json`.*

#### Opus 4.6 (explicit, simple task)

Fibonacci function + verify:

| Provider | Total Session | Model Time | Tool Calls |
|----------|--------------|------------|------------|
| Direct | 49.1s | 47.7s | 2 |
| Bedrock | 48.1s | 46.2s | 2 |
| Delta | **-2.1%** | -3.2% | — |

*From `session-simple-opus46-20260206-062655.json`.*

#### Opus 4.6 (explicit, medium task)

Calculator class + pytest tests:

| Provider | Total Session | Model Time | Tool Time | Tool Calls |
|----------|--------------|------------|-----------|------------|
| Direct | 1.7m | 1.7m | 4.2s | 10 |
| Bedrock | 1.4m | 1.3m | 2.7s | 8 |
| Delta | **-21.0%** | -20.3% | -36.7% | — |

*From `session-medium-opus46-20260206-062841.json`. Opus on Bedrock was faster in this run. Bedrock's non-streaming response may avoid per-token streaming overhead on slower models. However, N=1 — validate with multiple runs.*

### How Claude Code Uses Models (Inferred)

> **Note:** The model routing behavior below is inferred from observed patterns, not directly measured. Our hooks capture tool calls but not which model is used per turn. Claude Code's internal routing may change between versions.

Claude Code appears to use a **multi-model routing strategy**:

- **Haiku** — Quick decisions: tool selection, context summarization, simple follow-ups. *Frequent and latency-sensitive.*
- **Sonnet** — Standard coding tasks: writing code, editing files, running tests. The workhorse (confirmed as default via `--model` inspection).
- **Opus** — Complex reasoning: architecture decisions, multi-step refactors, debugging hard problems.

A typical coding session likely involves many small Haiku calls for routing/summarization plus a few larger Sonnet/Opus calls for the actual work.

### The Compounding Effect (Illustrative)

> **Note:** The example below is illustrative, not measured from an actual session trace. It demonstrates the *mechanism* by which Bedrock overhead compounds, using our measured per-call Haiku latencies.

If a session makes multiple Haiku calls internally, the overhead compounds:

```
                        Direct API              Bedrock
8x Haiku calls:         8 x 568ms  = 4.5s      8 x 1,402ms = 11.2s
                                                    Overhead: +6.7s
```

With Guardrails enabled, each Haiku call would add ~800ms more, bringing Bedrock to 8 x 2,204ms = 17.6s (+13.1s overhead). It's not any single call being slow — it's death by a thousand cuts on the fast model calls.

### Key Takeaways

1. **Bedrock adds ~550–850ms of per-request overhead** — not model inference speed. This exists with zero Guardrails configured. (Measured across 2 independent Haiku runs, N=5 each.)
2. **Guardrails add ~800ms more** (772ms server-side). A content filter nearly triples Bedrock latency on fast models. (Measured, N=5, single run.)
3. **Haiku is disproportionately affected** (+95% to +147% depending on run) because the overhead approaches or exceeds the model's own response time. (Measured.)
4. **Opus is unaffected** — Bedrock was within noise or faster in all our tests. The non-streaming `converse` API may even benefit slower models. (Measured, but N=1 sessions.)
5. **Session-level impact varies**: Sonnet sessions ranged from -0.4% to +13.3%, suggesting the overhead impact depends heavily on the number and type of internal API calls per session. (Measured, N=1 each.)
6. **The perceived slowness of Bedrock in Claude Code** likely comes from compounding overhead across many internal Haiku API calls, not from the primary coding model being slow. (Inferred from per-call measurements, not directly traced.)
7. **No default Guardrails exist** — AWS accounts don't ship with guardrails pre-configured. The base Bedrock overhead is purely invocation-layer.

### Methodology Limitations

- **Raw API benchmarks** (latency_budget.sh): N=5 iterations after 2 warmup discards. Statistically limited — two independent Haiku runs showed different overhead magnitudes (554ms vs 834ms).
- **Session benchmarks** (session_benchmark.sh): N=1 per configuration. High variance — individual results should be treated as directional, not definitive. Sonnet complex showed -0.4% while Sonnet medium showed +13.3%.
- **No Sonnet per-call data**: We have per-call raw API latency for Haiku and Opus only. Sonnet overhead is inferred from session-level benchmarks.
- **Model routing**: We confirmed Sonnet 4.5 as Claude Code's default on Bedrock, but cannot directly observe internal Haiku routing calls.
- **All tests from a single location**: Seths-MacBook-Pro, US East (Pennsylvania). Results will vary by network and region.
- **Bedrock uses non-streaming API**: `aws bedrock-runtime converse` returns complete responses, while Direct API uses SSE streaming. This may advantage Bedrock on slower models.

### Bedrock Model IDs

Bedrock requires inference profile IDs rather than direct model IDs for newer models:

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
├── skills/
│   └── latency-advisor/
│       └── SKILL.md                  # Auto-invoked latency advice
└── LICENSE                           # MIT
```

## License

MIT
