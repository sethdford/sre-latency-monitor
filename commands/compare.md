---
allowed-tools: Bash
description: Compare latency budget results across runs, machines, or providers
argument-hint: [results/ | file1.json file2.json] [--latest N]
---

## Context
- Plugin root: ${CLAUDE_PLUGIN_ROOT}
- Arguments: $ARGUMENTS

## Your Task

Compare latency budget results side by side. This helps teams understand:
- How latency differs between machines / regions / network conditions
- Whether Bedrock overhead is consistent across environments
- How tool/MCP latency varies between setups

### Steps

1. Run the comparison script:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/compare.sh $ARGUMENTS
   ```

   If no arguments provided, default to the results directory:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/compare.sh ${CLAUDE_PLUGIN_ROOT}/results/
   ```

   Options:
   - Pass individual JSON files: `file1.json file2.json`
   - Pass a directory to compare all results in it
   - `--latest N` — only compare the N most recent results

2. After showing the comparison table, provide analysis:
   - Highlight the fastest / slowest environments
   - Note if Bedrock overhead varies significantly across runs
   - Flag any anomalies (e.g., one run with much higher P99)
   - Suggest what might explain differences (region, network, time of day)

3. If only one result file exists, suggest running more benchmarks:
   - On different machines: `scp` the plugin, run `/latency-budget`
   - At different times: run at peak vs off-peak hours
   - With different models: `--direct-model claude-sonnet-4-5`
