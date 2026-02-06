---
allowed-tools: Bash
description: Quick single-request latency check against a specific provider
argument-hint: [direct|bedrock|both]
---

## Context
- Plugin root: ${CLAUDE_PLUGIN_ROOT}
- Arguments: $ARGUMENTS

## Your Task

Run a quick latency probe against one or both Claude API providers. This is a fast spot-check rather than a full benchmark.

### Steps

1. Parse arguments. The first argument should be the provider:
   - `anthropic-direct` or `direct` — check Anthropic Direct API
   - `aws-bedrock` or `bedrock` — check AWS Bedrock
   - `both` or no argument — check both sequentially

2. For each provider, run:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/latency_check.sh <provider> [--model <id>] [--bedrock-region <region>]
   ```

3. Present the results concisely:
   ```
   Provider        TTFT     Total    Throughput
   direct          482ms    2341ms   98.3 t/s
   bedrock         N/A      2589ms   91.7 t/s
   ```

4. Flag any concerning values:
   - TTFT > 2000ms — high first-token latency
   - Error status — connection or auth issue
   - Throughput < 50 t/s — unusually slow generation

Note: Direct API uses curl streaming for real TTFT measurement. Bedrock uses aws CLI converse (non-streaming) which measures total latency.
