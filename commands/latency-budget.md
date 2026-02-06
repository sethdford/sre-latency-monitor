---
allowed-tools: Bash
description: Analyze where every millisecond goes — Model vs Bedrock vs Guardrails vs CLI vs Tools
argument-hint: [--iterations 10] [--output budget.json]
---

## Context
- Plugin root: ${CLAUDE_PLUGIN_ROOT}
- Arguments: $ARGUMENTS

## Your Task

Run a comprehensive latency budget analysis that shows exactly where time is spent across the entire Claude Code stack.

### What This Measures

```
┌─────────────────────────────────────────────────────────────┐
│  TOTAL REQUEST LATENCY                                      │
│                                                             │
│  ┌──────────┬──────────────────┬─────────────────────────┐  │
│  │ Network  │ Provider         │ Model Processing        │  │
│  │ RTT      │ overhead         │                         │  │
│  │          │ (Bedrock routing │ ┌─────────┬───────────┐ │  │
│  │          │  + guardrails    │ │ TTFT    │ Token     │ │  │
│  │          │  + auth)         │ │ (think) │ streaming │ │  │
│  │          │                  │ └─────────┴───────────┘ │  │
│  └──────────┴──────────────────┴─────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

- **Direct API**: TTFB (network → API), TTFT (first token), Generation (token streaming)
- **Bedrock**: Total latency, server-side latency (from Bedrock metrics), network overhead
- **Bedrock Overhead** = Bedrock total - Direct total (routing, guardrails, extra hops)
- **Session Tool Budget**: Time in Bash, MCP servers, CLI tools, Task subagents

### Steps

1. Run the latency budget script:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/latency_budget.sh $ARGUMENTS
   ```

   Supported flags:
   - `--iterations N` — requests per provider (default: 10, excludes warmup)
   - `--warmup N` — warmup requests to discard (default: 2)
   - `--direct-model <id>` — Anthropic Direct model
   - `--bedrock-model <id>` — Bedrock model ID
   - `--bedrock-region <region>` — AWS region (default: us-east-1)
   - `--output <file>` — save full JSON report

2. Present the results as a **latency budget breakdown**:

   ```
   === LATENCY BUDGET ===

   DIRECT API (claude-haiku-4-5)
     Network → API (TTFB):     ~50ms
     Model thinking (TTFT):    ~450ms
     Token generation:         ~1800ms
     ────────────────────────
     Total:                    ~2300ms

   BEDROCK (us.anthropic.claude-haiku...)
     Total (measured):         ~3200ms
     Server-side latency:      ~2800ms
     Network overhead:         ~400ms

   BEDROCK OVERHEAD
     Delta vs Direct:          +900ms (+39%)
     This includes: Bedrock routing, guardrails evaluation, auth, extra network hops

   SESSION TOOL BUDGET (from hooks)
     Bash commands:            45.2s total (8 calls, avg 5.6s)
     MCP servers:              28.5s total (5 calls, avg 5.7s)
     Task subagents:           57.0s total (3 calls, avg 19.0s)
     CLI tools (R/W/Edit):     0.8s total (12 calls, avg 67ms)
     ────────────────────────
     Total tool time:          2m11s
   ```

3. Provide SRE-focused analysis:
   - Is the Bedrock overhead acceptable for your use case?
   - Are guardrails adding significant latency?
   - Which tool category dominates session time?
   - Recommendations for reducing latency
