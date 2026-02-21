---
allowed-tools: Bash
description: Analyze real HTTP calls from an instrumented Claude Code session
argument-hint: [--summary] [--slow 500] [--request-ids] [--streaming]
---

## Context

- Plugin root: ${CLAUDE_PLUGIN_ROOT}
- Arguments: $ARGUMENTS

## Your Task

Analyze the HTTP call trace from the most recent instrumented Claude Code session.

### What This Shows

Every real HTTP call Claude Code made — Anthropic API, AWS Bedrock, MCP servers, eval endpoints — captured from inside the process with zero proxy overhead.

Per-call data includes:

- URL, method, HTTP status
- Provider classification (anthropic-direct, aws-bedrock, mcp-local, etc.)
- TTFB (time to first byte) and total latency
- Streaming metrics: TTFT, chunk count, inter-chunk timing
- Request IDs (Anthropic `request-id`, AWS `x-amzn-requestid`)

### Steps

1. Check if an instrumented session log exists:

   ```
   ls -la /tmp/sre-http-calls.jsonl
   ```

2. If no log exists, inform the user they need to run an instrumented session first:

   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/run-instrumented.sh -p "say hello"
   ```

3. Run the HTTP trace analysis:

   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/http_trace.sh $ARGUMENTS
   ```

   Supported flags:
   - `--summary` — Aggregate statistics (call count, timing, by provider)
   - `--slow <ms>` — Show calls slower than threshold (default: 500ms)
   - `--provider <name>` — Filter by provider
   - `--request-ids` — Extract all Anthropic/AWS request IDs
   - `--streaming` — Show only streaming responses with chunk timing

4. Present the results with SRE-focused insights:
   - Which endpoints are slowest?
   - Are there unexpected external calls?
   - What's the streaming TTFT vs TTFB gap?
   - Are MCP server calls adding significant latency?
   - List any errors or failed calls
