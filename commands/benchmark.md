---
allowed-tools: Bash
description: Run a full latency benchmark comparing Anthropic Direct API vs AWS Bedrock
argument-hint: [-n iterations] [--providers direct bedrock] [--output file.json]
---

## Context
- Plugin root: ${CLAUDE_PLUGIN_ROOT}
- Arguments: $ARGUMENTS

## Your Task

Run the SRE latency benchmark to compare Anthropic Direct API and AWS Bedrock performance.

### Steps

1. Parse the user's arguments. Supported flags:
   - `-n <count>` — number of iterations per provider (default: 5)
   - `--providers <list>` — which providers: `anthropic-direct`, `aws-bedrock`, or both (default: both)
   - `--prompt-size <short|medium|long>` — test prompt complexity (default: medium)
   - `--max-tokens <n>` — max output tokens (default: 512)
   - `--direct-model <id>` — Anthropic Direct model (default: claude-haiku-4-5)
   - `--bedrock-model <id>` — Bedrock model ID
   - `--bedrock-region <region>` — AWS region (default: us-east-1)
   - `--output <file>` — save full JSON report

2. Run the benchmark script:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/benchmark.sh [args]
   ```

3. Present the results in a clear comparison table showing:
   - TTFT (Time to First Token) — P50, P90, P95, P99
   - Total response time — P50, P90, P95, P99
   - Output throughput (tokens/second)
   - Error rate
   - Delta analysis between providers

4. Provide SRE-focused insights:
   - Which provider has lower tail latency (P99)?
   - Is the TTFT gap significant for interactive CLI usage?
   - Are there any error rate concerns?
   - Recommendations based on the results

### Error Handling
- If `ANTHROPIC_API_KEY` is not set, skip the Anthropic Direct provider and inform the user
- If AWS credentials are not configured, skip Bedrock and inform the user
- Requires: bash, curl, jq, perl (all pre-installed on macOS)
