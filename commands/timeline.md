---
allowed-tools: Bash, Read
description: Session timeline — model inference vs tool execution breakdown from real hook data
argument-hint: [path/to/jsonl]
---

## Context
- Plugin root: ${CLAUDE_PLUGIN_ROOT}
- Arguments: $ARGUMENTS
- Default log file: /tmp/sre-latency-monitor.jsonl

## Your Task

Run the timeline analyzer to show where time is spent: model inference vs tool execution, computed from real PreToolUse/PostToolUse hook timestamps.

### Steps

1. Run the timeline analyzer:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/timeline.sh" $ARGUMENTS
   ```

2. Present the output directly — it's already formatted.

3. After the table, add brief SRE-focused observations:
   - If model inference is >80% of session time, note that tools are efficient and the bottleneck is API response time
   - If a single inference gap is >30s, flag it — may indicate a complex reasoning step or context overflow
   - If MCP tools dominate tool time, suggest checking MCP server health
   - If Task (subagent) calls are significant, note parallel execution opportunities
   - If User wait time is substantial, note it's excluded from performance concerns
