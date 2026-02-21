#!/bin/bash
# ============================================================================
# SRE Todo Application E2E Test
# ============================================================================
#
# Runs a deterministic Todo Application creation task across 3 scenarios:
#   1. Anthropic Direct API
#   2. AWS Bedrock (no guardrail)
#   3. AWS Bedrock + Guardrail
#
# The prompt is carefully designed to produce consistent, repeatable behavior
# with minimal token usage while exercising real code generation (Write tool).
#
# Each scenario runs the instrumented Claude Code runner, capturing every
# HTTP call with full timing, streaming metrics, and request IDs.
#
# Usage:
#   todo_e2e_test.sh                                    # All 3 scenarios
#   todo_e2e_test.sh --providers direct                 # Direct API only
#   todo_e2e_test.sh --providers bedrock,guardrail      # Bedrock only
#   todo_e2e_test.sh --guardrail-id <ID>                # Custom guardrail
#   todo_e2e_test.sh --output /path/to/report.json      # Save JSON report
#   todo_e2e_test.sh --iterations 3                     # Multiple iterations
#
# Requires:
#   - Node.js >= 18
#   - @anthropic-ai/claude-code npm package
#   - AWS credentials (for bedrock/guardrail scenarios)

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$SCRIPT_DIR/run-instrumented.sh"
HTTP_LOG="${SRE_HTTP_LOG:-/tmp/sre-http-calls.jsonl}"

# --- Defaults ---
ITERATIONS=1
OUTPUT_FILE=""
PROVIDERS="direct,bedrock,guardrail"
GUARDRAIL_ID="${BEDROCK_GUARDRAIL_ID:-pcxoysw8v24d}"
GUARDRAIL_VER="${BEDROCK_GUARDRAIL_VERSION:-DRAFT}"
BEDROCK_REGION="${AWS_REGION:-us-east-1}"
CLEANUP=1

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()    { printf "${CYAN}[SRE]${NC} %s\n" "$*" >&2; }
success() { printf "${GREEN}[SRE]${NC} %s\n" "$*" >&2; }
warn()    { printf "${YELLOW}[SRE]${NC} %s\n" "$*" >&2; }
error()   { printf "${RED}[SRE]${NC} %s\n" "$*" >&2; }

# --- Argument parsing ---
while [ $# -gt 0 ]; do
  case "$1" in
    --iterations|-n)   ITERATIONS="$2"; shift 2 ;;
    --output|-o)       OUTPUT_FILE="$2"; shift 2 ;;
    --providers|-p)    PROVIDERS="$2"; shift 2 ;;
    --guardrail-id)    GUARDRAIL_ID="$2"; shift 2 ;;
    --guardrail-ver)   GUARDRAIL_VER="$2"; shift 2 ;;
    --region|-r)       BEDROCK_REGION="$2"; shift 2 ;;
    --no-cleanup)      CLEANUP=0; shift ;;
    --help|-h)
      echo "Usage: todo_e2e_test.sh [options]"
      echo ""
      echo "Runs a deterministic Todo app creation task across providers."
      echo ""
      echo "Options:"
      echo "  --iterations N       Runs per provider (default: 1)"
      echo "  --providers p1,p2    Comma-separated: direct,bedrock,guardrail (default: all)"
      echo "  --guardrail-id ID    Bedrock guardrail ID (default: $GUARDRAIL_ID)"
      echo "  --guardrail-ver V    Guardrail version (default: DRAFT)"
      echo "  --region REGION      AWS region (default: us-east-1)"
      echo "  --output FILE        Save JSON report to file"
      echo "  --no-cleanup         Keep temp directory and todo app files"
      exit 0
      ;;
    *) shift ;;
  esac
done

# --- Verify prerequisites ---
if [ ! -x "$RUNNER" ] && [ ! -f "$RUNNER" ]; then
  error "run-instrumented.sh not found at $RUNNER"
  exit 1
fi

# --- Timing utility ---
ms_now() { perl -MTime::HiRes=time -e 'printf "%.3f", time()*1000'; }

# --- The Todo App Prompt ---
# Designed for determinism:
# - Explicit file path prevents variation in where files are created
# - Complete spec leaves no room for creative interpretation
# - Single file keeps it simple (1 Write tool call)
# - No dependencies, no build step, no tests
# - Small enough to be cheap but real enough to be meaningful
#
# Expected behavior: 1 API call (messages), 1 tool call (Write), 1 final API call
TODO_PROMPT='Create a file at /tmp/sre-todo-app.html that is a complete, self-contained Todo application. Requirements:
- Single HTML file with embedded CSS and JavaScript
- A text input field and "Add" button at the top
- Todo items displayed as a list below
- Each item has a checkbox to mark complete (strikethrough when checked) and a delete button
- Completed count shown at the bottom (e.g., "2 of 5 completed")
- Clean, minimal styling with a max-width container
- No external dependencies, no frameworks, just vanilla HTML/CSS/JS
- The app must work when opened directly in a browser

Write ONLY this single file. Do not explain or describe it.'

# --- Environment metadata ---
ENV_HOSTNAME=$(hostname -s 2>/dev/null || echo "unknown")
ENV_OS=$(uname -s 2>/dev/null || echo "unknown")
ENV_ARCH=$(uname -m 2>/dev/null || echo "unknown")
NODE_VER=$(node --version 2>/dev/null || echo "unknown")
AWS_VER=$(aws --version 2>/dev/null | head -1 || echo "not installed")
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# --- Banner ---
echo "" >&2
printf "${BOLD}╔══════════════════════════════════════════════════════════════════╗${NC}\n" >&2
printf "${BOLD}║          SRE TODO APP E2E TEST — HTTP INSTRUMENTATION          ║${NC}\n" >&2
printf "${BOLD}╚══════════════════════════════════════════════════════════════════╝${NC}\n" >&2
echo "" >&2
info "Iterations:    $ITERATIONS"
info "Providers:     $PROVIDERS"
info "Guardrail ID:  $GUARDRAIL_ID"
info "Region:        $BEDROCK_REGION"
info "Node:          $NODE_VER"
info "Timestamp:     $TIMESTAMP"
echo "" >&2

# --- Temp directory for logs ---
TMPDIR=$(mktemp -d /tmp/sre-todo-e2e-XXXXXX)
if [ "$CLEANUP" = "1" ]; then
  trap "rm -rf $TMPDIR" EXIT
else
  info "Temp dir (preserved): $TMPDIR"
fi

# --- Run a single test scenario ---
run_scenario() {
  local provider="$1" iter="$2"
  local log_file="$TMPDIR/${provider}_${iter}.jsonl"
  local session_stdout="$TMPDIR/${provider}_${iter}_stdout.log"
  local session_stderr="$TMPDIR/${provider}_${iter}_stderr.log"
  local todo_file="/tmp/sre-todo-app-${provider}-${iter}.html"

  # Remove previous todo app file
  rm -f "$todo_file"

  # Modify prompt to use provider-specific output path
  local prompt
  prompt=$(echo "$TODO_PROMPT" | sed "s|/tmp/sre-todo-app.html|$todo_file|")

  # Clear HTTP log
  > "$HTTP_LOG"

  local t_start t_end
  t_start=$(ms_now)

  local exit_code=0
  case "$provider" in
    direct)
      env -u CLAUDE_CODE_USE_BEDROCK \
        bash "$RUNNER" -p "$prompt" \
          --dangerously-skip-permissions \
          --max-turns 3 \
          --no-session-persistence \
          > "$session_stdout" 2>"$session_stderr" || exit_code=$?
      ;;
    bedrock)
      env \
        CLAUDE_CODE_USE_BEDROCK=1 \
        AWS_REGION="$BEDROCK_REGION" \
        bash "$RUNNER" -p "$prompt" \
          --dangerously-skip-permissions \
          --max-turns 3 \
          --no-session-persistence \
          > "$session_stdout" 2>"$session_stderr" || exit_code=$?
      ;;
    guardrail)
      if [ -z "$GUARDRAIL_ID" ]; then
        error "guardrail-id not set for guardrail scenario"
        echo '{"error":"guardrail-id not set"}' > "$log_file"
        return
      fi
      env \
        CLAUDE_CODE_USE_BEDROCK=1 \
        AWS_REGION="$BEDROCK_REGION" \
        BEDROCK_GUARDRAIL_ID="$GUARDRAIL_ID" \
        BEDROCK_GUARDRAIL_VERSION="$GUARDRAIL_VER" \
        bash "$RUNNER" -p "$prompt" \
          --dangerously-skip-permissions \
          --max-turns 3 \
          --no-session-persistence \
          > "$session_stdout" 2>"$session_stderr" || exit_code=$?
      ;;
  esac

  t_end=$(ms_now)
  local session_ms
  session_ms=$(echo "$t_end - $t_start" | bc)

  # Copy HTTP log for this run
  cp "$HTTP_LOG" "$log_file" 2>/dev/null || true

  # Check if todo file was created
  local todo_created=false
  local todo_size=0
  if [ -f "$todo_file" ]; then
    todo_created=true
    todo_size=$(wc -c < "$todo_file" | tr -d ' ')
  fi

  # Add run metadata
  jq -nc \
    --arg provider "$provider" \
    --argjson iter "$iter" \
    --argjson session_ms "$session_ms" \
    --argjson exit_code "$exit_code" \
    --argjson todo_created "$todo_created" \
    --argjson todo_size "$todo_size" \
    --arg todo_file "$todo_file" \
    '{type:"run_metadata", provider:$provider, iteration:$iter,
      session_total_ms:$session_ms, exit_code:$exit_code,
      todo_app_created:$todo_created, todo_app_size_bytes:$todo_size,
      todo_app_path:$todo_file}' \
    >> "$log_file"

  # Status indicator
  local status_icon="✓"
  local status_color="$GREEN"
  if [ "$exit_code" -ne 0 ]; then
    status_icon="✗"
    status_color="$RED"
  elif [ "$todo_created" = "false" ]; then
    status_icon="⚠"
    status_color="$YELLOW"
  fi

  printf "  ${status_color}${status_icon}${NC} %-12s run %d/%d: %sms (exit: %d) todo: %s (%s bytes)\n" \
    "$provider" "$iter" "$ITERATIONS" \
    "$(printf '%.0f' "$session_ms")" \
    "$exit_code" \
    "$todo_created" \
    "$todo_size" >&2
}

# --- Analyze HTTP log for a single run ---
analyze_run() {
  local log_file="$1"

  if [ ! -f "$log_file" ] || [ ! -s "$log_file" ]; then
    echo '{}'
    return
  fi

  jq -s '
    [.[] | select(.type != "session_metadata" and .type != "run_metadata")] as $calls |
    ([.[] | select(.type == "run_metadata")] | first // {}) as $meta |

    # API calls (messages/converse/invoke endpoints)
    [$calls[] | select(
      (.url != null) and
      ((.url | contains("/messages")) or (.url | contains("/converse")) or (.url | contains("/invoke")))
    ) | select(
      (.url | contains("count_tokens")) | not
    )] as $api |

    # Token counting calls
    [$calls[] | select(.url != null and (.url | contains("count_tokens")))] as $token_count |

    # MCP calls
    [$calls[] | select(.provider != null and (.provider | contains("mcp")))] as $mcp |

    # Streaming API calls
    [$api[] | select(.streaming == true)] as $streaming |

    # Eval / telemetry calls
    [$calls[] | select(.url != null and (.url | contains("/eval")))] as $eval |

    {
      session_total_ms: ($meta.session_total_ms // null),
      exit_code: ($meta.exit_code // null),
      todo_app_created: ($meta.todo_app_created // false),
      todo_app_size_bytes: ($meta.todo_app_size_bytes // 0),

      total_http_calls: ($calls | length),
      api_calls: ($api | length),
      token_count_calls: ($token_count | length),
      mcp_calls: ($mcp | length),
      eval_calls: ($eval | length),
      streaming_calls: ($streaming | length),

      api_timing: (if ($api | length) > 0 then {
        ttfb_ms: ([$api[].ttfb_ms // 0] | add / length | . * 100 | round / 100),
        total_ms: ([$api[].total_ms // 0] | add / length | . * 100 | round / 100),
        total_sum_ms: ([$api[].total_ms // 0] | add | . * 100 | round / 100)
      } else null end),

      streaming_timing: (if ($streaming | length) > 0 then {
        ttfb_ms: ([$streaming[].stream_metrics.ttfb_ms // 0] | add / length | . * 100 | round / 100),
        ttft_ms: ([$streaming[] | .stream_metrics.ttft_ms // .stream_metrics.ttfb_ms // 0] | add / length | . * 100 | round / 100),
        chunks_mean: ([$streaming[].stream_metrics.chunk_count // 0] | add / length | round),
        bytes_total: ([$streaming[].stream_metrics.total_bytes // 0] | add)
      } else null end),

      mcp_timing: (if ($mcp | length) > 0 then {
        total_calls: ($mcp | length),
        total_ms: ([$mcp[].total_ms // 0] | add | . * 100 | round / 100),
        mean_ms: ([$mcp[].total_ms // 0] | add / length | . * 100 | round / 100),
        providers: ([$mcp[].provider] | unique)
      } else null end),

      request_ids: {
        anthropic: [$calls[] | .response_headers.anthropic_request_id // empty],
        aws: [$calls[] | .response_headers.aws_request_id // empty]
      },

      errors: [$calls[] | select(.error != null) | {url: .url, error: .error, status: .status}]
    }
  ' "$log_file" 2>/dev/null || echo '{}'
}

# --- Run all scenarios ---
IFS=',' read -ra PROV_LIST <<< "$PROVIDERS"

for prov in "${PROV_LIST[@]}"; do
  printf "\n${BOLD}--- %s ---${NC}\n" "$prov" >&2
  for i in $(seq 1 "$ITERATIONS"); do
    run_scenario "$prov" "$i"
    # Brief pause between runs to avoid rate limiting
    if [ "$i" -lt "$ITERATIONS" ]; then
      sleep 3
    fi
  done
done

# --- Aggregate results per provider ---
echo "" >&2
info "Analyzing HTTP traces..."

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
    if ($ok | length) == 0 then {
      runs: ($runs | length),
      successful: 0,
      error: "no successful API calls detected",
      exit_codes: [$runs[].exit_code],
      todo_apps_created: [$runs[].todo_app_created]
    }
    else {
      runs: ($runs | length),
      successful: ($ok | length),
      todo_apps_created: ([$ok[].todo_app_created] | map(select(. == true)) | length),
      todo_app_size_avg: ([$ok[].todo_app_size_bytes // 0] | add / length | round),

      session_total_ms: {
        mean: ([$ok[].session_total_ms // 0] | add / length | . * 100 | round / 100),
        min: ([$ok[].session_total_ms // 0] | min | . * 100 | round / 100),
        max: ([$ok[].session_total_ms // 0] | max | . * 100 | round / 100),
        values: [$ok[].session_total_ms]
      },

      api_ttfb_ms: {
        mean: ([$ok[].api_timing.ttfb_ms] | add / length | . * 100 | round / 100)
      },
      api_total_ms: {
        mean: ([$ok[].api_timing.total_ms] | add / length | . * 100 | round / 100)
      },
      api_sum_ms: {
        mean: ([$ok[].api_timing.total_sum_ms] | add / length | . * 100 | round / 100)
      },

      streaming: (
        [$ok[] | select(.streaming_timing != null)] as $st |
        if ($st | length) > 0 then {
          ttfb_mean_ms: ([$st[].streaming_timing.ttfb_ms] | add / length | . * 100 | round / 100),
          ttft_mean_ms: ([$st[].streaming_timing.ttft_ms] | add / length | . * 100 | round / 100),
          chunks_mean: ([$st[].streaming_timing.chunks_mean] | add / length | round),
          bytes_total: ([$st[].streaming_timing.bytes_total] | add)
        } else null end
      ),

      mcp: (
        [$ok[] | select(.mcp_timing != null)] as $mc |
        if ($mc | length) > 0 then {
          calls_mean: ([$mc[].mcp_timing.total_calls] | add / length | round),
          total_ms_mean: ([$mc[].mcp_timing.total_ms] | add / length | . * 100 | round / 100)
        } else null end
      ),

      http_calls_mean: ([$ok[].total_http_calls] | add / length | round),
      api_calls_mean: ([$ok[].api_calls] | add / length | . * 10 | round / 10),

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

# --- Compute deltas ---
COMPARISON="{}"
DIRECT_API=$(echo "$ALL_RESULTS" | jq '.direct.api_total_ms.mean // 0')
BEDROCK_API=$(echo "$ALL_RESULTS" | jq '.bedrock.api_total_ms.mean // 0')
GUARDRAIL_API=$(echo "$ALL_RESULTS" | jq '.guardrail.api_total_ms.mean // 0')

DIRECT_TTFB=$(echo "$ALL_RESULTS" | jq '.direct.streaming.ttfb_mean_ms // 0')
BEDROCK_TTFB=$(echo "$ALL_RESULTS" | jq '.bedrock.streaming.ttfb_mean_ms // 0')
GUARDRAIL_TTFB=$(echo "$ALL_RESULTS" | jq '.guardrail.streaming.ttfb_mean_ms // 0')

DIRECT_TTFT=$(echo "$ALL_RESULTS" | jq '.direct.streaming.ttft_mean_ms // 0')
BEDROCK_TTFT=$(echo "$ALL_RESULTS" | jq '.bedrock.streaming.ttft_mean_ms // 0')
GUARDRAIL_TTFT=$(echo "$ALL_RESULTS" | jq '.guardrail.streaming.ttft_mean_ms // 0')

# Bedrock vs Direct
if [ "$(echo "$DIRECT_API > 0 && $BEDROCK_API > 0" | bc)" = "1" ]; then
  B_DELTA=$(echo "$BEDROCK_API - $DIRECT_API" | bc)
  B_PCT=$(echo "scale=1; ($B_DELTA / $DIRECT_API) * 100" | bc 2>/dev/null || echo "0")
  B_TTFB_DELTA=$(echo "$BEDROCK_TTFB - $DIRECT_TTFB" | bc 2>/dev/null || echo "0")
  B_TTFT_DELTA=$(echo "$BEDROCK_TTFT - $DIRECT_TTFT" | bc 2>/dev/null || echo "0")

  COMPARISON=$(echo "$COMPARISON" | jq \
    --argjson delta "$B_DELTA" \
    --argjson pct "$B_PCT" \
    --argjson ttfb_delta "$B_TTFB_DELTA" \
    --argjson ttft_delta "$B_TTFT_DELTA" \
    '. + {bedrock_vs_direct: {
      api_total_delta_ms: ($delta * 100 | round / 100),
      api_total_delta_pct: $pct,
      stream_ttfb_delta_ms: ($ttfb_delta * 100 | round / 100),
      stream_ttft_delta_ms: ($ttft_delta * 100 | round / 100)
    }}')
fi

# Guardrail vs Bedrock
if [ "$(echo "$BEDROCK_API > 0 && $GUARDRAIL_API > 0" | bc)" = "1" ]; then
  G_DELTA=$(echo "$GUARDRAIL_API - $BEDROCK_API" | bc)
  G_PCT=$(echo "scale=1; ($G_DELTA / $BEDROCK_API) * 100" | bc 2>/dev/null || echo "0")
  G_TTFB_DELTA=$(echo "$GUARDRAIL_TTFB - $BEDROCK_TTFB" | bc 2>/dev/null || echo "0")
  G_TTFT_DELTA=$(echo "$GUARDRAIL_TTFT - $BEDROCK_TTFT" | bc 2>/dev/null || echo "0")

  COMPARISON=$(echo "$COMPARISON" | jq \
    --argjson delta "$G_DELTA" \
    --argjson pct "$G_PCT" \
    --argjson ttfb_delta "$G_TTFB_DELTA" \
    --argjson ttft_delta "$G_TTFT_DELTA" \
    '. + {guardrail_overhead: {
      api_total_delta_ms: ($delta * 100 | round / 100),
      api_total_delta_pct: $pct,
      stream_ttfb_delta_ms: ($ttfb_delta * 100 | round / 100),
      stream_ttft_delta_ms: ($ttft_delta * 100 | round / 100)
    }}')
fi

# --- Build final report ---
REPORT=$(jq -nc \
  --arg ts "$TIMESTAMP" \
  --arg hostname "$ENV_HOSTNAME" \
  --arg os "$ENV_OS" \
  --arg arch "$ENV_ARCH" \
  --arg node "$NODE_VER" \
  --arg aws_cli "$AWS_VER" \
  --argjson iterations "$ITERATIONS" \
  --arg providers "$PROVIDERS" \
  --arg guardrail_id "$GUARDRAIL_ID" \
  --arg region "$BEDROCK_REGION" \
  --argjson results "$ALL_RESULTS" \
  --argjson comparison "$COMPARISON" \
  '{
    type: "todo_e2e_test",
    test_name: "Todo Application E2E",
    timestamp: $ts,
    environment: {
      hostname: $hostname,
      os: $os,
      arch: $arch,
      node: $node,
      aws_cli: $aws_cli
    },
    config: {
      iterations: $iterations,
      providers: ($providers | split(",")),
      guardrail_id: $guardrail_id,
      region: $region,
      task: "Create single-file Todo HTML application"
    },
    results: $results,
    comparison: $comparison
  }')

# --- Display results ---
echo "" >&2
printf "${BOLD}╔══════════════════════════════════════════════════════════════════╗${NC}\n" >&2
printf "${BOLD}║              TODO APP E2E TEST RESULTS                          ║${NC}\n" >&2
printf "${BOLD}╚══════════════════════════════════════════════════════════════════╝${NC}\n" >&2
echo "" >&2

# Comparison table
echo "$REPORT" | jq -r '
  def fmt: if type != "number" then "—" elif . >= 10000 then "\(. / 1000 | . * 10 | round / 10)s" elif . >= 1000 then "\(. / 1000 | . * 10 | round / 10)s" else "\(. * 10 | round / 10)ms" end;
  def pad(n): . + (" " * 20) | .[:n];

  "  Metric               │ Direct API     │ Bedrock        │ Guardrail",
  "  ─────────────────────┼────────────────┼────────────────┼──────────────",
  "  Session Total (avg)  │ \(.results.direct.session_total_ms.mean // null | fmt | pad(15))│ \(.results.bedrock.session_total_ms.mean // null | fmt | pad(15))│ \(.results.guardrail.session_total_ms.mean // null | fmt)",
  "  API Total (avg)      │ \(.results.direct.api_total_ms.mean // null | fmt | pad(15))│ \(.results.bedrock.api_total_ms.mean // null | fmt | pad(15))│ \(.results.guardrail.api_total_ms.mean // null | fmt)",
  "  Stream TTFB (avg)    │ \(.results.direct.streaming.ttfb_mean_ms // null | fmt | pad(15))│ \(.results.bedrock.streaming.ttfb_mean_ms // null | fmt | pad(15))│ \(.results.guardrail.streaming.ttfb_mean_ms // null | fmt)",
  "  Stream TTFT (avg)    │ \(.results.direct.streaming.ttft_mean_ms // null | fmt | pad(15))│ \(.results.bedrock.streaming.ttft_mean_ms // null | fmt | pad(15))│ \(.results.guardrail.streaming.ttft_mean_ms // null | fmt)",
  "  Stream Chunks (avg)  │ \(.results.direct.streaming.chunks_mean // "—" | tostring | pad(15))│ \(.results.bedrock.streaming.chunks_mean // "—" | tostring | pad(15))│ \(.results.guardrail.streaming.chunks_mean // "—" | tostring)",
  "  HTTP Calls (avg)     │ \(.results.direct.http_calls_mean // "—" | tostring | pad(15))│ \(.results.bedrock.http_calls_mean // "—" | tostring | pad(15))│ \(.results.guardrail.http_calls_mean // "—" | tostring)",
  "  API Calls (avg)      │ \(.results.direct.api_calls_mean // "—" | tostring | pad(15))│ \(.results.bedrock.api_calls_mean // "—" | tostring | pad(15))│ \(.results.guardrail.api_calls_mean // "—" | tostring)",
  "  MCP Calls (avg)      │ \(.results.direct.mcp.calls_mean // "—" | tostring | pad(15))│ \(.results.bedrock.mcp.calls_mean // "—" | tostring | pad(15))│ \(.results.guardrail.mcp.calls_mean // "—" | tostring)",
  "  Todo App Created     │ \(.results.direct.todo_apps_created // 0 | tostring | pad(15))│ \(.results.bedrock.todo_apps_created // 0 | tostring | pad(15))│ \(.results.guardrail.todo_apps_created // 0 | tostring)",
  "  Todo App Size (avg)  │ \(.results.direct.todo_app_size_avg // 0 | tostring | . + "B" | pad(15))│ \(.results.bedrock.todo_app_size_avg // 0 | tostring | . + "B" | pad(15))│ \(.results.guardrail.todo_app_size_avg // 0 | tostring | . + "B")",
  "  AWS Request IDs      │ N/A            │ \(.results.bedrock.request_ids.aws // [] | length | tostring | pad(15))│ \(.results.guardrail.request_ids.aws // [] | length | tostring)"
' >&2

echo "" >&2

# Delta summary
echo "$REPORT" | jq -r '
  if .comparison.bedrock_vs_direct then
    "  Bedrock vs Direct:    API total \(if .comparison.bedrock_vs_direct.api_total_delta_ms > 0 then "+" else "" end)\(.comparison.bedrock_vs_direct.api_total_delta_ms)ms (\(if .comparison.bedrock_vs_direct.api_total_delta_pct > 0 then "+" else "" end)\(.comparison.bedrock_vs_direct.api_total_delta_pct)%)  |  TTFT \(if .comparison.bedrock_vs_direct.stream_ttft_delta_ms > 0 then "+" else "" end)\(.comparison.bedrock_vs_direct.stream_ttft_delta_ms)ms"
  else "" end,
  if .comparison.guardrail_overhead then
    "  Guardrail overhead:   API total \(if .comparison.guardrail_overhead.api_total_delta_ms > 0 then "+" else "" end)\(.comparison.guardrail_overhead.api_total_delta_ms)ms (\(if .comparison.guardrail_overhead.api_total_delta_pct > 0 then "+" else "" end)\(.comparison.guardrail_overhead.api_total_delta_pct)%)  |  TTFT \(if .comparison.guardrail_overhead.stream_ttft_delta_ms > 0 then "+" else "" end)\(.comparison.guardrail_overhead.stream_ttft_delta_ms)ms"
  else "" end
' >&2

# --- Request ID listing ---
echo "" >&2
info "Request IDs:"
echo "$REPORT" | jq -r '
  if (.results.direct.request_ids.anthropic // [] | length) > 0 then
    "  Direct (Anthropic): \(.results.direct.request_ids.anthropic | join(", "))"
  else empty end,
  if (.results.bedrock.request_ids.aws // [] | length) > 0 then
    "  Bedrock (AWS):      \(.results.bedrock.request_ids.aws | join(", "))"
  else empty end,
  if (.results.guardrail.request_ids.aws // [] | length) > 0 then
    "  Guardrail (AWS):    \(.results.guardrail.request_ids.aws | join(", "))"
  else empty end
' >&2

# --- Error summary ---
TOTAL_ERRORS=$(echo "$REPORT" | jq '[.results[].errors // [] | length] | add // 0')
if [ "$TOTAL_ERRORS" -gt 0 ]; then
  echo "" >&2
  warn "Errors detected:"
  echo "$REPORT" | jq -r '
    .results | to_entries[] |
    .key as $prov |
    .value.errors // [] | .[] |
    "  [\($prov)] \(.url // "?"): \(.error // "unknown")"
  ' >&2
fi

# --- Save report ---
if [ -n "$OUTPUT_FILE" ]; then
  echo "$REPORT" | jq '.' > "$OUTPUT_FILE"
  echo "" >&2
  success "Full report saved to $OUTPUT_FILE"
fi

echo "" >&2
success "Test complete."

# Output JSON to stdout
echo "$REPORT" | jq '.'
