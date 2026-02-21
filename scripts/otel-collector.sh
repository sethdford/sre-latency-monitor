#!/bin/bash
# ============================================================================
# SRE OTel Event Collector
# ============================================================================
#
# Captures Claude Code's native OpenTelemetry events alongside HTTP
# instrumentation data. Claude Code emits:
#   - claude_code.api_request: model, duration, tokens, cost
#   - claude_code.tool_result: tool name, duration, success
#
# This script sets up the environment for OTel collection and optionally
# merges OTel events with HTTP call logs for a complete picture.
#
# Usage:
#   otel-collector.sh run -p "say hello"       # Run with OTel collection
#   otel-collector.sh merge                     # Merge OTel + HTTP logs
#   otel-collector.sh show                      # Display collected events
#
# Requires: Node.js >= 18, @anthropic-ai/claude-code npm package

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OTEL_LOG="/tmp/sre-otel-events.jsonl"
HTTP_LOG="${SRE_HTTP_LOG:-/tmp/sre-http-calls.jsonl}"
MERGED_LOG="/tmp/sre-merged-trace.jsonl"

CMD="${1:-show}"
shift 2>/dev/null || true

case "$CMD" in
  run)
    # Run instrumented Claude Code with OTel enabled
    # OTel console exporter writes to stderr; we capture it
    OTEL_STDERR="/tmp/sre-otel-stderr.log"
    > "$OTEL_LOG"
    > "$OTEL_STDERR"

    echo "[SRE] Running with OTel collection enabled..." >&2
    echo "[SRE] OTel log: $OTEL_LOG" >&2
    echo "[SRE] HTTP log: $HTTP_LOG" >&2

    # Run the instrumented runner with OTel env vars
    env \
      CLAUDE_CODE_ENABLE_TELEMETRY=1 \
      OTEL_METRICS_EXPORTER=console \
      OTEL_LOG_LEVEL=warn \
      bash "$SCRIPT_DIR/run-instrumented.sh" "$@" 2> >(tee "$OTEL_STDERR" >&2)

    EXIT_CODE=$?

    # Parse OTel console output from stderr into JSONL
    # OTel console exporter outputs JSON objects to stderr
    if [ -f "$OTEL_STDERR" ]; then
      grep -E '^\{' "$OTEL_STDERR" 2>/dev/null | while IFS= read -r line; do
        # Validate it's JSON
        if echo "$line" | jq -e '.' &>/dev/null; then
          echo "$line" >> "$OTEL_LOG"
        fi
      done
    fi

    echo "" >&2
    echo "[SRE] Collection complete (exit: $EXIT_CODE)" >&2
    echo "[SRE] OTel events: $(wc -l < "$OTEL_LOG" 2>/dev/null || echo 0)" >&2
    echo "[SRE] HTTP calls:  $(jq -s 'length' "$HTTP_LOG" 2>/dev/null || echo 0)" >&2

    exit "$EXIT_CODE"
    ;;

  merge)
    # Merge OTel events with HTTP call logs
    echo "Merging OTel + HTTP trace data..." >&2

    if [ ! -f "$HTTP_LOG" ] && [ ! -f "$OTEL_LOG" ]; then
      echo "ERROR: No log files found. Run a session first." >&2
      exit 1
    fi

    > "$MERGED_LOG"

    # Add HTTP calls
    if [ -f "$HTTP_LOG" ]; then
      jq -c '. + {source: "http_instrument"}' "$HTTP_LOG" >> "$MERGED_LOG" 2>/dev/null
    fi

    # Add OTel events
    if [ -f "$OTEL_LOG" ]; then
      jq -c '. + {source: "otel"}' "$OTEL_LOG" >> "$MERGED_LOG" 2>/dev/null
    fi

    # Sort by timestamp
    tmp_sorted=$(mktemp)
    jq -s 'sort_by(.timestamp // .ts // "")' "$MERGED_LOG" > "$tmp_sorted" 2>/dev/null
    mv "$tmp_sorted" "$MERGED_LOG"

    TOTAL=$(jq -s 'length' "$MERGED_LOG" 2>/dev/null || echo 0)
    HTTP_COUNT=$(jq -s '[.[] | select(.source == "http_instrument")] | length' "$MERGED_LOG" 2>/dev/null || echo 0)
    OTEL_COUNT=$(jq -s '[.[] | select(.source == "otel")] | length' "$MERGED_LOG" 2>/dev/null || echo 0)

    echo "Merged: $TOTAL events ($HTTP_COUNT HTTP + $OTEL_COUNT OTel)" >&2
    echo "Output: $MERGED_LOG" >&2
    ;;

  show)
    # Display collected OTel events
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                  OTEL EVENT SUMMARY                             ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""

    if [ ! -f "$OTEL_LOG" ] || [ ! -s "$OTEL_LOG" ]; then
      echo "No OTel events collected."
      echo "Run: otel-collector.sh run -p 'prompt'"
      exit 0
    fi

    echo "Events: $(wc -l < "$OTEL_LOG")"
    echo ""

    # Show api_request events
    echo "API Requests:"
    jq -r 'select(.name == "claude_code.api_request" or .type == "api_request") |
      "  \(.attributes.model // .model // "?") — \(.attributes.duration_ms // .duration_ms // "?")ms, \(.attributes.output_tokens // .output_tokens // "?") tokens"
    ' "$OTEL_LOG" 2>/dev/null || echo "  (none found)"

    echo ""

    # Show tool_result events
    echo "Tool Results:"
    jq -r 'select(.name == "claude_code.tool_result" or .type == "tool_result") |
      "  \(.attributes.tool_name // .tool_name // "?") — \(.attributes.duration_ms // .duration_ms // "?")ms \(if (.attributes.success // .success) == false then "[FAILED]" else "" end)"
    ' "$OTEL_LOG" 2>/dev/null || echo "  (none found)"
    ;;

  *)
    echo "Usage: otel-collector.sh <run|merge|show> [args...]" >&2
    echo ""
    echo "Commands:"
    echo "  run -p 'prompt'   Run instrumented session with OTel collection"
    echo "  merge             Merge OTel + HTTP call logs"
    echo "  show              Display collected OTel events"
    exit 1
    ;;
esac
