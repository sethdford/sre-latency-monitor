#!/bin/bash
# ============================================================================
# SRE E2E Benchmark — Real Claude Code HTTP Instrumentation
# ============================================================================
#
# Runs REAL Claude Code sessions with fetch instrumentation to capture
# actual HTTP behavior: protocol, timing, streaming metrics, request IDs.
#
# Unlike benchmark.sh (synthetic curl calls) or session_benchmark.sh
# (measures total session time), this captures every HTTP call Claude Code
# makes from inside the process.
#
# Comparison matrix:
#                     | Direct API | Bedrock | Bedrock+Guardrail |
#   ------------------|-----------|---------|-------------------|
#   TTFB (avg)        |           |         |                   |
#   TTFT (avg)        |           |         |                   |
#   Total latency     |           |         |                   |
#   Streaming chunks  |           |         |                   |
#   MCP call count    |           |         |                   |
#   AWS Request IDs   | N/A       | yes     | yes               |
#   Guardrail delta   | N/A       | N/A     | vs Bedrock        |
#
# Usage:
#   e2e_benchmark.sh [--iterations N] [--prompt "..."] [--output FILE]
#   e2e_benchmark.sh --providers direct,bedrock
#   e2e_benchmark.sh --providers bedrock,guardrail --guardrail-id XXX

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$SCRIPT_DIR/run-instrumented.sh"
HTTP_LOG="${SRE_HTTP_LOG:-/tmp/sre-http-calls.jsonl}"

# --- Defaults ---
ITERATIONS=3
PROMPT="Say hello in exactly 5 words."
OUTPUT_FILE=""
PROVIDERS="direct,bedrock"
GUARDRAIL_ID=""
GUARDRAIL_VER=""
MODEL=""
BEDROCK_REGION="${AWS_REGION:-us-east-1}"

# --- Argument parsing ---
while [ $# -gt 0 ]; do
  case "$1" in
    --iterations|-n)   ITERATIONS="$2"; shift 2 ;;
    --prompt)          PROMPT="$2"; shift 2 ;;
    --output|-o)       OUTPUT_FILE="$2"; shift 2 ;;
    --providers|-p)    PROVIDERS="$2"; shift 2 ;;
    --guardrail-id)    GUARDRAIL_ID="$2"; shift 2 ;;
    --guardrail-ver)   GUARDRAIL_VER="$2"; shift 2 ;;
    --model|-m)        MODEL="$2"; shift 2 ;;
    --region|-r)       BEDROCK_REGION="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: e2e_benchmark.sh [options]"
      echo ""
      echo "Options:"
      echo "  --iterations N       Runs per provider (default: 3)"
      echo "  --prompt 'text'      Prompt to send (default: short greeting)"
      echo "  --providers p1,p2    Comma-separated: direct,bedrock,guardrail"
      echo "  --guardrail-id ID    Bedrock guardrail ID"
      echo "  --guardrail-ver V    Guardrail version (default: DRAFT)"
      echo "  --model name         Model short name (haiku, sonnet, opus)"
      echo "  --region REGION      AWS region (default: us-east-1)"
      echo "  --output FILE        Save JSON report"
      exit 0
      ;;
    *) shift ;;
  esac
done

# --- Verify runner exists ---
if [ ! -x "$RUNNER" ]; then
  echo "ERROR: run-instrumented.sh not found at $RUNNER" >&2
  exit 1
fi

# --- Timing utility ---
ms_now() { perl -MTime::HiRes=time -e 'printf "%.3f", time()*1000'; }

# --- Environment metadata ---
ENV_HOSTNAME=$(hostname -s 2>/dev/null || echo "unknown")
ENV_OS=$(uname -s 2>/dev/null || echo "unknown")
ENV_ARCH=$(uname -m 2>/dev/null || echo "unknown")
NODE_VER=$(node --version 2>/dev/null || echo "unknown")
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "╔══════════════════════════════════════════════════════════════════╗" >&2
echo "║              SRE E2E HTTP BENCHMARK                             ║" >&2
echo "╚══════════════════════════════════════════════════════════════════╝" >&2
echo "" >&2
echo "  Iterations:  $ITERATIONS" >&2
echo "  Providers:   $PROVIDERS" >&2
echo "  Prompt:      ${PROMPT:0:60}..." >&2
echo "  Model:       ${MODEL:-auto}" >&2
echo "  Node:        $NODE_VER" >&2
echo "  Region:      $BEDROCK_REGION" >&2
echo "" >&2

# --- Temp directory ---
TMPDIR=$(mktemp -d /tmp/sre-e2e-XXXXXX)
trap "rm -rf $TMPDIR" EXIT

# --- Run a single instrumented session and capture HTTP log ---
run_one() {
  local provider="$1" iter="$2"
  local log_file="$TMPDIR/${provider}_${iter}.jsonl"
  local session_log="$TMPDIR/${provider}_${iter}_session.log"

  # Clear HTTP log
  > "$HTTP_LOG"

  local model_flag=""
  [ -n "$MODEL" ] && model_flag="--model $MODEL"

  local t_start t_end
  t_start=$(ms_now)

  local exit_code=0
  case "$provider" in
    direct)
      env -u CLAUDE_CODE_USE_BEDROCK \
        bash "$RUNNER" -p "$PROMPT" \
          $model_flag \
          --dangerously-skip-permissions \
          --max-turns 3 \
          --no-session-persistence \
          > "$session_log" 2>&1 || exit_code=$?
      ;;
    bedrock)
      env \
        CLAUDE_CODE_USE_BEDROCK=1 \
        AWS_REGION="$BEDROCK_REGION" \
        bash "$RUNNER" -p "$PROMPT" \
          $model_flag \
          --dangerously-skip-permissions \
          --max-turns 3 \
          --no-session-persistence \
          > "$session_log" 2>&1 || exit_code=$?
      ;;
    guardrail)
      if [ -z "$GUARDRAIL_ID" ]; then
        echo '{"error":"guardrail-id not set"}' > "$log_file"
        return
      fi
      env \
        CLAUDE_CODE_USE_BEDROCK=1 \
        AWS_REGION="$BEDROCK_REGION" \
        BEDROCK_GUARDRAIL_ID="$GUARDRAIL_ID" \
        BEDROCK_GUARDRAIL_VERSION="${GUARDRAIL_VER:-DRAFT}" \
        bash "$RUNNER" -p "$PROMPT" \
          $model_flag \
          --dangerously-skip-permissions \
          --max-turns 3 \
          --no-session-persistence \
          > "$session_log" 2>&1 || exit_code=$?
      ;;
  esac

  t_end=$(ms_now)
  local session_ms
  session_ms=$(echo "$t_end - $t_start" | bc)

  # Copy HTTP log for this run
  cp "$HTTP_LOG" "$log_file" 2>/dev/null || true

  # Add session metadata
  jq -nc \
    --arg provider "$provider" \
    --argjson iter "$iter" \
    --argjson session_ms "$session_ms" \
    --argjson exit_code "$exit_code" \
    '{type:"run_metadata", provider:$provider, iteration:$iter,
      session_total_ms:$session_ms, exit_code:$exit_code}' \
    >> "$log_file"

  printf "  %s run %d/%d: %.0fms (exit: %d)\n" "$provider" "$iter" "$ITERATIONS" "$session_ms" "$exit_code" >&2
}

# --- Analyze HTTP log for a provider run ---
analyze_run() {
  local log_file="$1"

  if [ ! -f "$log_file" ] || [ ! -s "$log_file" ]; then
    echo '{}'
    return
  fi

  jq -s '
    [.[] | select(.type != "session_metadata" and .type != "run_metadata")] as $calls |
    ([.[] | select(.type == "run_metadata")] | first // {}) as $meta |

    # API calls (messages endpoint)
    [$calls[] | select(.provider == "anthropic-direct" or .provider == "aws-bedrock")
                | select(.url | test("/messages|/converse|/invoke"))] as $api |

    # MCP calls
    [$calls[] | select(.provider | test("mcp"))] as $mcp |

    # Streaming API calls
    [$api[] | select(.streaming == true)] as $streaming |

    {
      session_total_ms: ($meta.session_total_ms // null),
      exit_code: ($meta.exit_code // null),
      total_http_calls: ($calls | length),
      api_calls: ($api | length),
      mcp_calls: ($mcp | length),
      streaming_calls: ($streaming | length),

      api_timing: (if ($api | length) > 0 then {
        ttfb_mean_ms: ([$api[].ttfb_ms // 0] | add / length | . * 100 | round / 100),
        total_mean_ms: ([$api[].total_ms // 0] | add / length | . * 100 | round / 100),
        total_sum_ms: ([$api[].total_ms // 0] | add | . * 100 | round / 100)
      } else null end),

      streaming_timing: (if ($streaming | length) > 0 then {
        ttfb_mean_ms: ([$streaming[].stream_metrics.ttfb_ms // 0] | add / length | . * 100 | round / 100),
        ttft_mean_ms: ([$streaming[] | .stream_metrics.ttft_ms // 0] | add / length | . * 100 | round / 100),
        chunks_mean: ([$streaming[].stream_metrics.chunk_count // 0] | add / length | round),
        bytes_total: ([$streaming[].stream_metrics.total_bytes // 0] | add)
      } else null end),

      mcp_timing: (if ($mcp | length) > 0 then {
        total_calls: ($mcp | length),
        total_ms: ([$mcp[].total_ms // 0] | add | . * 100 | round / 100),
        mean_ms: ([$mcp[].total_ms // 0] | add / length | . * 100 | round / 100)
      } else null end),

      request_ids: {
        anthropic: [$calls[] | .response_headers.anthropic_request_id // empty],
        aws: [$calls[] | .response_headers.aws_request_id // empty]
      },

      errors: [$calls[] | select(.error != null) | {url: .url, error: .error}]
    }
  ' "$log_file" 2>/dev/null || echo '{}'
}

# --- Run benchmark for each provider ---
IFS=',' read -ra PROV_LIST <<< "$PROVIDERS"

for prov in "${PROV_LIST[@]}"; do
  echo "--- $prov ---" >&2
  for i in $(seq 1 "$ITERATIONS"); do
    run_one "$prov" "$i"
    [ "$i" -lt "$ITERATIONS" ] && sleep 2
  done
  echo "" >&2
done

# --- Aggregate results per provider ---
echo "--- Analyzing HTTP traces ---" >&2

ALL_RESULTS="{}"

for prov in "${PROV_LIST[@]}"; do
  RUNS="[]"
  for i in $(seq 1 "$ITERATIONS"); do
    log_file="$TMPDIR/${prov}_${i}.jsonl"
    run_analysis=$(analyze_run "$log_file")
    RUNS=$(echo "$RUNS" | jq --argjson r "$run_analysis" '. + [$r]')
  done

  # Aggregate across iterations
  PROV_AGG=$(echo "$RUNS" | jq '
    . as $runs |
    [$runs[] | select(.api_timing != null)] as $ok |
    if ($ok | length) == 0 then {runs: ($runs | length), error: "no successful runs"}
    else {
      runs: ($runs | length),
      successful: ($ok | length),
      session_total_ms: {
        mean: ([$ok[].session_total_ms // 0] | add / length | . * 100 | round / 100),
        values: [$ok[].session_total_ms]
      },
      api_ttfb_ms: {
        mean: ([$ok[].api_timing.ttfb_mean_ms] | add / length | . * 100 | round / 100)
      },
      api_total_ms: {
        mean: ([$ok[].api_timing.total_mean_ms] | add / length | . * 100 | round / 100)
      },
      streaming: (
        [$ok[] | select(.streaming_timing != null)] as $st |
        if ($st | length) > 0 then {
          ttfb_mean_ms: ([$st[].streaming_timing.ttfb_mean_ms] | add / length | . * 100 | round / 100),
          ttft_mean_ms: ([$st[].streaming_timing.ttft_mean_ms] | add / length | . * 100 | round / 100),
          chunks_mean: ([$st[].streaming_timing.chunks_mean] | add / length | round)
        } else null end
      ),
      mcp: (
        [$ok[] | select(.mcp_timing != null)] as $mc |
        if ($mc | length) > 0 then {
          calls_mean: ([$mc[].mcp_timing.total_calls] | add / length | round),
          total_ms_mean: ([$mc[].mcp_timing.total_ms] | add / length | . * 100 | round / 100)
        } else null end
      ),
      request_ids: {
        anthropic: [$ok[].request_ids.anthropic[]] | unique,
        aws: [$ok[].request_ids.aws[]] | unique
      },
      errors: [$ok[].errors[]]
    }
    end
  ')

  ALL_RESULTS=$(echo "$ALL_RESULTS" | jq --arg p "$prov" --argjson a "$PROV_AGG" '.[$p] = $a')
done

# --- Build comparison ---
COMPARISON="{}"
DIRECT=$(echo "$ALL_RESULTS" | jq '.direct // {}')
BEDROCK=$(echo "$ALL_RESULTS" | jq '.bedrock // {}')
GUARDRAIL=$(echo "$ALL_RESULTS" | jq '.guardrail // {}')

DIRECT_API_MS=$(echo "$DIRECT" | jq '.api_total_ms.mean // 0')
BEDROCK_API_MS=$(echo "$BEDROCK" | jq '.api_total_ms.mean // 0')
GUARDRAIL_API_MS=$(echo "$GUARDRAIL" | jq '.api_total_ms.mean // 0')

if [ "$(echo "$DIRECT_API_MS > 0" | bc)" = "1" ] && [ "$(echo "$BEDROCK_API_MS > 0" | bc)" = "1" ]; then
  BEDROCK_DELTA=$(echo "$BEDROCK_API_MS - $DIRECT_API_MS" | bc)
  BEDROCK_PCT=$(echo "scale=1; ($BEDROCK_DELTA / $DIRECT_API_MS) * 100" | bc 2>/dev/null || echo "0")
  COMPARISON=$(echo "$COMPARISON" | jq \
    --argjson delta "$BEDROCK_DELTA" \
    --argjson pct "$BEDROCK_PCT" \
    '. + {bedrock_vs_direct: {delta_ms: ($delta * 100 | round / 100), delta_pct: $pct}}')
fi

if [ "$(echo "$BEDROCK_API_MS > 0" | bc)" = "1" ] && [ "$(echo "$GUARDRAIL_API_MS > 0" | bc)" = "1" ]; then
  GUARD_DELTA=$(echo "$GUARDRAIL_API_MS - $BEDROCK_API_MS" | bc)
  GUARD_PCT=$(echo "scale=1; ($GUARD_DELTA / $BEDROCK_API_MS) * 100" | bc 2>/dev/null || echo "0")
  COMPARISON=$(echo "$COMPARISON" | jq \
    --argjson delta "$GUARD_DELTA" \
    --argjson pct "$GUARD_PCT" \
    '. + {guardrail_overhead: {delta_ms: ($delta * 100 | round / 100), delta_pct: $pct}}')
fi

# --- Build final report ---
REPORT=$(jq -nc \
  --arg ts "$TIMESTAMP" \
  --arg hostname "$ENV_HOSTNAME" \
  --arg os "$ENV_OS" \
  --arg arch "$ENV_ARCH" \
  --arg node "$NODE_VER" \
  --argjson iterations "$ITERATIONS" \
  --arg prompt "$PROMPT" \
  --arg model "${MODEL:-auto}" \
  --arg region "$BEDROCK_REGION" \
  --argjson results "$ALL_RESULTS" \
  --argjson comparison "$COMPARISON" \
  '{
    type: "e2e_benchmark",
    timestamp: $ts,
    environment: {hostname: $hostname, os: $os, arch: $arch, node: $node},
    config: {iterations: $iterations, prompt: $prompt, model: $model, region: $region},
    results: $results,
    comparison: $comparison
  }')

# --- Display summary ---
echo "" >&2
echo "╔══════════════════════════════════════════════════════════════════╗" >&2
echo "║                  E2E BENCHMARK RESULTS                          ║" >&2
echo "╚══════════════════════════════════════════════════════════════════╝" >&2
echo "" >&2

echo "$REPORT" | jq -r '
  def fmt: if type != "number" then "—" elif . >= 1000 then "\(. / 1000 | . * 10 | round / 10)s" else "\(. * 10 | round / 10)ms" end;

  "                    | Direct API    | Bedrock       | Guardrail",
  "                    |---------------|---------------|----------",
  "API TTFB (avg)      | \(.results.direct.api_ttfb_ms.mean // null | fmt | . + "            " | .[:14])| \(.results.bedrock.api_ttfb_ms.mean // null | fmt | . + "            " | .[:14])| \(.results.guardrail.api_ttfb_ms.mean // null | fmt)",
  "API Total (avg)     | \(.results.direct.api_total_ms.mean // null | fmt | . + "            " | .[:14])| \(.results.bedrock.api_total_ms.mean // null | fmt | . + "            " | .[:14])| \(.results.guardrail.api_total_ms.mean // null | fmt)",
  "Session Total (avg) | \(.results.direct.session_total_ms.mean // null | fmt | . + "            " | .[:14])| \(.results.bedrock.session_total_ms.mean // null | fmt | . + "            " | .[:14])| \(.results.guardrail.session_total_ms.mean // null | fmt)",
  "Stream TTFT (avg)   | \(.results.direct.streaming.ttft_mean_ms // null | fmt | . + "            " | .[:14])| \(.results.bedrock.streaming.ttft_mean_ms // null | fmt | . + "            " | .[:14])| \(.results.guardrail.streaming.ttft_mean_ms // null | fmt)",
  "Stream Chunks (avg) | \(.results.direct.streaming.chunks_mean // "—" | tostring | . + "            " | .[:14])| \(.results.bedrock.streaming.chunks_mean // "—" | tostring | . + "            " | .[:14])| \(.results.guardrail.streaming.chunks_mean // "—" | tostring)",
  "MCP Calls (avg)     | \(.results.direct.mcp.calls_mean // "—" | tostring | . + "            " | .[:14])| \(.results.bedrock.mcp.calls_mean // "—" | tostring | . + "            " | .[:14])| \(.results.guardrail.mcp.calls_mean // "—" | tostring)",
  "AWS Request IDs     | N/A           | \(.results.bedrock.request_ids.aws // [] | length | tostring | . + "            " | .[:14])| \(.results.guardrail.request_ids.aws // [] | length | tostring)",
  "",
  (if .comparison.bedrock_vs_direct then
    "Bedrock overhead:   +\(.comparison.bedrock_vs_direct.delta_ms)ms (+\(.comparison.bedrock_vs_direct.delta_pct)%)"
  else "" end),
  (if .comparison.guardrail_overhead then
    "Guardrail overhead: +\(.comparison.guardrail_overhead.delta_ms)ms (+\(.comparison.guardrail_overhead.delta_pct)%)"
  else "" end)
' >&2

# Save if output specified
if [ -n "$OUTPUT_FILE" ]; then
  echo "$REPORT" | jq '.' > "$OUTPUT_FILE"
  echo "" >&2
  echo "Full report saved to $OUTPUT_FILE" >&2
fi

# Output JSON
echo "$REPORT" | jq '.'
