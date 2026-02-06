---
allowed-tools: Bash, Read
description: View categorized time-spent analysis — Model vs Tools vs MCP breakdown
argument-hint: [--last N] [--tool-name Bash] [--category MCP]
---

## Context
- Plugin root: ${CLAUDE_PLUGIN_ROOT}
- Arguments: $ARGUMENTS
- Hook log file: /tmp/sre-latency-monitor.jsonl

## Your Task

Analyze where time is being spent in this Claude Code session: Model API, CLI tools, MCP servers, or Bash commands.

### Steps

1. Check if `/tmp/sre-latency-monitor.jsonl` exists. If not, inform the user that no hook data has been collected yet.

2. Read the JSONL file and parse each line as JSON. Filter for entries where `"event": "tool_call"`.

3. **Categorize each tool call:**
   - **Bash**: `tool_name == "Bash"` — shell commands
   - **MCP**: `tool_name` starts with `mcp__` — MCP server calls (context7, linear, firebase, chrome, etc.)
   - **Task**: `tool_name == "Task"` — subagent/parallel tasks
   - **CLI**: `tool_name` in `Read, Write, Edit, Glob, Grep, NotebookEdit` — built-in file tools
   - **Other**: everything else

4. **Present a time-spent summary table:**
   ```
   Category     Calls   Total Time   Avg       P90       P99
   ─────────────────────────────────────────────────────────
   Task           3      1m12s       24.0s     35.0s     35.0s
   Bash           8      45.2s        5.6s     12.3s     15.1s
   MCP            5      28.5s        5.7s      8.4s      9.2s
   CLI           12       0.8s       67ms      120ms     210ms
   ─────────────────────────────────────────────────────────
   Total Tools   28      2m26s

   Session Total: 5m12s
   Tool Time:     2m26s (47%)
   Model+Idle:    2m46s (53%) ← time waiting for API responses + user think time
   ```

5. **MCP server breakdown** (if MCP calls exist):
   ```
   MCP Server          Calls   Total     Avg
   context7              2     15.2s    7.6s
   linear                3     13.3s    4.4s
   ```

6. **Per-tool breakdown** within each category:
   - Show individual tool names and their timing stats
   - Flag any calls with `duration_ms: null` (timing gap)
   - Flag any suspiciously slow calls (> 2x the category average)

7. If the user passes `--last N`, only show the most recent N entries.
   If `--tool-name <name>`, filter to that tool.
   If `--category <cat>`, filter to that category (Bash, MCP, Task, CLI).

8. Present in a clean table format with SRE-focused insights:
   - "Most time is in Task subagents — consider if these can be parallelized"
   - "MCP calls averaging 5.7s — check server health or network latency"
   - "CLI tools are fast (<100ms avg) — no concern here"
