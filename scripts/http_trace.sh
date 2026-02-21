#!/bin/bash
# ============================================================================
# SRE HTTP Trace — Analyze instrumented HTTP calls
# ============================================================================
#
# Parses /tmp/sre-http-calls.jsonl (produced by instrument.mjs via
# run-instrumented.sh) and displays a detailed breakdown of every
# HTTP call Claude Code made during a session.
#
# Usage:
#   http_trace.sh [logfile]
#   http_trace.sh --summary
#   http_trace.sh --slow 500       # show calls slower than 500ms
#   http_trace.sh --provider aws-bedrock
#   http_trace.sh --request-ids    # extract all request IDs

set -eo pipefail

LOG_FILE="${1:-/tmp/sre-http-calls.jsonl}"
MODE="full"  # full, summary, slow, request-ids, streaming
SLOW_THRESHOLD=500
PROVIDER_FILTER=""

# Parse flags
while [ $# -gt 0 ]; do
  case "$1" in
    --summary|-s)     MODE="summary"; shift ;;
    --slow)           MODE="slow"; SLOW_THRESHOLD="${2:-500}"; shift 2 ;;
    --provider|-p)    PROVIDER_FILTER="$2"; shift 2 ;;
    --request-ids)    MODE="request-ids"; shift ;;
    --streaming)      MODE="streaming"; shift ;;
    --help|-h)
      echo "Usage: http_trace.sh [logfile] [options]"
      echo ""
      echo "Options:"
      echo "  --summary         Show aggregate statistics"
      echo "  --slow <ms>       Show calls slower than threshold (default: 500ms)"
      echo "  --provider <name> Filter by provider (anthropic-direct, aws-bedrock, mcp-local)"
      echo "  --request-ids     Extract all Anthropic/AWS request IDs"
      echo "  --streaming       Show only streaming responses with chunk timing"
      exit 0
      ;;
    *)
      # First positional arg = log file
      if [ -f "$1" ]; then
        LOG_FILE="$1"
      fi
      shift
      ;;
  esac
done

if [ ! -f "$LOG_FILE" ]; then
  echo "ERROR: Log file not found: $LOG_FILE" >&2
  echo "Run an instrumented session first: run-instrumented.sh -p 'prompt'" >&2
  exit 1
fi

# Skip metadata lines (type: session_metadata)
DATA_FILTER='select(.type != "session_metadata")'
if [ -n "$PROVIDER_FILTER" ]; then
  DATA_FILTER="$DATA_FILTER | select(.provider == \"$PROVIDER_FILTER\")"
fi

case "$MODE" in
  full)
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                    HTTP CALL TRACE                              ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Source: $LOG_FILE"
    echo ""

    jq -r "$DATA_FILTER"' |
      "\(.seq // "-"). \(.method) \(.url)"
      + "\n   Provider:  \(.provider)"
      + "\n   Status:    \(.status // "error")"
      + "\n   TTFB:      \(.ttfb_ms // "-")ms"
      + (if .streaming then
           "\n   Streaming: yes"
           + "\n   TTFT:      \(.stream_metrics.ttft_ms // "-")ms"
           + "\n   Chunks:    \(.stream_metrics.chunk_count // "-")"
           + "\n   Bytes:     \(.stream_metrics.total_bytes // "-")"
         else "" end)
      + "\n   Total:     \(.total_ms // "-")ms"
      + (if .response_headers.anthropic_request_id then
           "\n   Request ID: \(.response_headers.anthropic_request_id)"
         else "" end)
      + (if .response_headers.aws_request_id then
           "\n   AWS Req ID: \(.response_headers.aws_request_id)"
         else "" end)
      + (if .error then "\n   ERROR: \(.error)" else "" end)
      + "\n"
    ' "$LOG_FILE" 2>/dev/null
    ;;

  summary)
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                  HTTP CALL SUMMARY                              ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""

    jq -sr '
      [.[] | '"$DATA_FILTER"'] |
      if length == 0 then "No HTTP calls recorded.\n"
      else
        "Total calls:    \(length)\n"
        + "Errors:         \([.[] | select(.error != null)] | length)\n"
        + "Streaming:      \([.[] | select(.streaming == true)] | length)\n"
        + "\n"
        + "BY PROVIDER:\n"
        + (group_by(.provider) | map(
            "  \(.[0].provider): \(length) calls"
            + ", avg \(([.[].total_ms // 0] | add / length | . * 10 | round / 10))ms"
            + ", total \(([.[].total_ms // 0] | add | . * 10 | round / 10))ms"
          ) | join("\n"))
        + "\n\nBY METHOD:\n"
        + (group_by(.method) | map(
            "  \(.[0].method): \(length) calls"
          ) | join("\n"))
        + "\n\nTIMING (non-error calls):\n"
        + ([.[] | select(.error == null and .total_ms != null)] as $ok |
           if ($ok | length) == 0 then "  No successful calls"
           else
             "  Fastest:      \([$ok[].total_ms] | min | . * 10 | round / 10)ms"
             + "\n  Slowest:      \([$ok[].total_ms] | max | . * 10 | round / 10)ms"
             + "\n  Mean:         \([$ok[].total_ms] | add / length | . * 10 | round / 10)ms"
             + "\n  Total time:   \([$ok[].total_ms] | add | . * 10 | round / 10)ms"
           end)
        + "\n"
      end
    ' "$LOG_FILE" 2>/dev/null
    ;;

  slow)
    echo "Calls slower than ${SLOW_THRESHOLD}ms:"
    echo ""

    jq -r "$DATA_FILTER"' |
      select(.total_ms != null and .total_ms > '"$SLOW_THRESHOLD"') |
      "\(.total_ms)ms  \(.method) \(.url) [\(.provider)]"
    ' "$LOG_FILE" 2>/dev/null | sort -rn
    ;;

  request-ids)
    echo "Request IDs:"
    echo ""

    echo "Anthropic:"
    jq -r "$DATA_FILTER"' |
      select(.response_headers.anthropic_request_id != null) |
      "  \(.response_headers.anthropic_request_id)  \(.method) \(.url | split("?")[0])"
    ' "$LOG_FILE" 2>/dev/null

    echo ""
    echo "AWS:"
    jq -r "$DATA_FILTER"' |
      select(.response_headers.aws_request_id != null) |
      "  \(.response_headers.aws_request_id)  \(.method) \(.url | split("?")[0])"
    ' "$LOG_FILE" 2>/dev/null
    ;;

  streaming)
    echo "Streaming Responses:"
    echo ""

    jq -r "$DATA_FILTER"' |
      select(.streaming == true) |
      "\(.seq). \(.method) \(.url | split("?")[0])"
      + "\n   TTFB:    \(.stream_metrics.ttfb_ms // "-")ms"
      + "\n   TTFT:    \(.stream_metrics.ttft_ms // "-")ms"
      + "\n   Chunks:  \(.stream_metrics.chunk_count // "-")"
      + "\n   Bytes:   \(.stream_metrics.total_bytes // "-")"
      + "\n   Total:   \(.total_ms // "-")ms"
      + (if (.stream_metrics.chunk_timings_ms | length) > 2 then
           "\n   Chunk timing (first 10): \(.stream_metrics.chunk_timings_ms[:10] | map(tostring + "ms") | join(", "))"
         else "" end)
      + "\n"
    ' "$LOG_FILE" 2>/dev/null
    ;;
esac
