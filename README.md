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

## Sample Results

### Latency Budget (Haiku 4.5)

Bedrock adds ~350-400ms fixed network overhead. Impact depends on model speed:

| Provider | TTFB | TTFT | Server Latency | Total |
|----------|------|------|----------------|-------|
| Direct   | 417ms | 568ms | — | 568ms |
| Bedrock  | 384ms | 1018ms | 1018ms | 1402ms |
| Delta    | -33ms | +450ms | — | +147% |

### Session Benchmark (Medium Task)

Real Claude Code session running a Calculator class + pytest task:

| Provider | Total Session | Model Time | Tool Time | Tool Calls |
|----------|--------------|------------|-----------|------------|
| Direct   | 1.5m         | 1.4m       | 3.5s      | 3          |
| Bedrock  | 1.7m         | 1.6m       | 4.3s      | 7          |
| Delta    | +13.3%       | +13.0%     | +21.8%    | —          |

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
