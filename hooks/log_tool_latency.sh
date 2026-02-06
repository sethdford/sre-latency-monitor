#!/bin/bash
# PostToolUse hook — compute tool call duration and log to JSONL
# Pure bash + jq + perl (no Python). ~10ms execution.

INPUT=$(cat)
TID=$(echo "$INPUT" | jq -r '.tool_use_id // "unknown"')
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"')
START_FILE="/tmp/sre-latency-tool-start-$TID"

if [ -f "$START_FILE" ]; then
  START=$(cat "$START_FILE")
  NOW=$(perl -MTime::HiRes=time -e 'printf "%.6f", time()')
  DUR_MS=$(echo "($NOW - $START) * 1000" | bc 2>/dev/null | cut -d'.' -f1)
  rm -f "$START_FILE"

  printf '{"event": "tool_call", "tool_name": "%s", "tool_use_id": "%s", "duration_ms": %s, "timestamp": "%s"}\n' \
    "$TOOL_NAME" "$TID" "${DUR_MS:-0}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> /tmp/sre-latency-monitor.jsonl 2>/dev/null
fi

echo '{}'
