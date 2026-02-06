---
allowed-tools: Bash, Read
description: Generate a formatted latency report from saved benchmark data
argument-hint: <file.json|directory> [--trend]
---

## Context
- Plugin root: ${CLAUDE_PLUGIN_ROOT}
- Arguments: $ARGUMENTS

## Your Task

Generate a formatted comparison report from previously saved benchmark JSON files.

### Steps

1. Parse arguments:
   - First argument: path to a JSON report file or directory of reports
   - `--trend` — show trend analysis across multiple runs
   - `--json` — output raw JSON

2. Run the report generator:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/report.sh <input> [--trend] [--json]
   ```

3. Present the report. For multi-file trend analysis, highlight:
   - Is latency improving or degrading over time?
   - Are there sudden spikes in any metric?
   - Which provider is trending better?

4. If no report files exist, suggest running `/sre-latency:benchmark --output report.json` first.
