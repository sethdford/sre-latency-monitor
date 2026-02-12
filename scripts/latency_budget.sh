#!/bin/bash
# ============================================================================
# SRE Latency Budget Analysis
# ============================================================================
#
# Measures WHERE every millisecond goes in the Claude Code stack:
#
#   ┌─────────────────────────────────────────────────────┐
#   │  Total Request Latency                              │
#   │  ┌───────────┬──────────────────┬────────────────┐  │
#   │  │ Network   │ Provider         │ Model          │  │
#   │  │ overhead  │ overhead         │ generation     │  │
#   │  │           │ (Bedrock routing │ (TTFT + token  │  │
#   │  │           │  + guardrails)   │  generation)   │  │
#   │  └───────────┴──────────────────┴────────────────┘  │
#   └─────────────────────────────────────────────────────┘
#
# By comparing Direct API vs Bedrock for the SAME model + prompt,
# the delta reveals the cost of Bedrock routing and guardrails.
#
# Usage: latency_budget.sh [--iterations N] [--bedrock-region REGION]
#        [--direct-model ID] [--bedrock-model ID] [--output FILE]
#
# Requires: ANTHROPIC_API_KEY (for Direct), AWS credentials (for Bedrock)
# Dependencies: bash, curl, jq, perl, aws CLI

set -eo pipefail

# --- Defaults ---
ITERATIONS=10
BEDROCK_REGION="us-east-1"
DIRECT_MODEL="claude-haiku-4-5"
BEDROCK_MODEL="us.anthropic.claude-haiku-4-5-20251001-v1:0"
OUTPUT_FILE=""
WARMUP=2  # discard first N requests (cold start)
PROVIDER=""  # empty = auto-detect, "direct" or "bedrock" to force one

# --- Argument parsing ---
while [ $# -gt 0 ]; do
  case "$1" in
    --iterations|-n)     ITERATIONS="$2"; shift 2 ;;
    --bedrock-region)    BEDROCK_REGION="$2"; shift 2 ;;
    --direct-model)      DIRECT_MODEL="$2"; shift 2 ;;
    --bedrock-model)     BEDROCK_MODEL="$2"; shift 2 ;;
    --output|-o)         OUTPUT_FILE="$2"; shift 2 ;;
    --warmup)            WARMUP="$2"; shift 2 ;;
    --provider|-p)       PROVIDER="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# Total iterations including warmup
TOTAL_RUNS=$((ITERATIONS + WARMUP))

# --- Fixed test prompts for reproducibility ---
# These produce consistent output lengths for reliable measurements.
# Using a deterministic prompt that constrains model output.
PROMPT="Count from 1 to 20, one number per line. Only output the numbers, nothing else."
MAX_TOKENS=128

# --- Timing utility (ms precision via perl) ---
ms_now() { perl -MTime::HiRes=time -e 'printf "%.3f", time()*1000'; }

# --- Temp directory ---
TMPDIR=$(mktemp -d /tmp/sre-budget-XXXXXX)
trap "rm -rf $TMPDIR" EXIT

# ============================================================================
# Anthropic Direct API — streaming with detailed timing
# ============================================================================
run_direct_timed() {
  local iter="$1"

  if [ -z "$ANTHROPIC_API_KEY" ]; then
    echo '{"error":"ANTHROPIC_API_KEY not set"}' > "$TMPDIR/direct_${iter}.json"
    return
  fi

  local payload
  payload=$(jq -nc --arg m "$DIRECT_MODEL" --arg p "$PROMPT" --argjson t "$MAX_TOKENS" \
    '{model:$m, max_tokens:$t, stream:true, messages:[{role:"user",content:$p}]}')

  local t_start t_first_byte="" t_first_token="" t_end
  local output_tokens=0 input_tokens=0 token_chunks=0 got_error=""

  t_start=$(ms_now)

  while IFS= read -r line; do
    [[ "$line" != data:* ]] && continue
    local data="${line#data: }"
    [[ "$data" == "[DONE]" ]] && break

    # Mark first byte (any SSE data line from server)
    if [ -z "$t_first_byte" ]; then
      t_first_byte=$(ms_now)
    fi

    local etype
    etype=$(echo "$data" | jq -r '.type // ""' 2>/dev/null)

    if [[ "$etype" == "error" ]]; then
      got_error=$(echo "$data" | jq -r '.error.message // "unknown"' 2>/dev/null)
      break
    fi

    # TTFT: first actual content token
    if [[ "$etype" == "content_block_delta" ]]; then
      if [ -z "$t_first_token" ]; then
        t_first_token=$(ms_now)
      fi
      token_chunks=$((token_chunks + 1))
    fi

    if [[ "$etype" == "message_start" ]]; then
      input_tokens=$(echo "$data" | jq -r '.message.usage.input_tokens // 0' 2>/dev/null)
    fi

    if [[ "$etype" == "message_delta" ]]; then
      output_tokens=$(echo "$data" | jq -r '.usage.output_tokens // 0' 2>/dev/null)
    fi
  done < <(curl -sN -X POST "https://api.anthropic.com/v1/messages" \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d "$payload" 2>/dev/null)

  t_end=$(ms_now)

  if [ -n "$got_error" ]; then
    jq -nc --arg e "$got_error" '{error:$e}' > "$TMPDIR/direct_${iter}.json"
    return
  fi

  # Compute all timing components
  local total_ms ttfb_ms ttft_ms generation_ms tps
  total_ms=$(echo "$t_end - $t_start" | bc)
  ttfb_ms=$(echo "${t_first_byte:-$t_end} - $t_start" | bc)
  ttft_ms=$(echo "${t_first_token:-$t_end} - $t_start" | bc)
  generation_ms=$(echo "$t_end - ${t_first_token:-$t_start}" | bc)
  tps=$(echo "scale=2; ${output_tokens:-0} / (${total_ms:-1} / 1000)" | bc 2>/dev/null || echo "0")

  jq -nc \
    --argjson total "$total_ms" \
    --argjson ttfb "$ttfb_ms" \
    --argjson ttft "$ttft_ms" \
    --argjson gen "$generation_ms" \
    --argjson in_tok "${input_tokens:-0}" \
    --argjson out_tok "${output_tokens:-0}" \
    --argjson chunks "$token_chunks" \
    --argjson tps "$tps" \
    '{total_ms:$total, ttfb_ms:$ttfb, ttft_ms:$ttft, generation_ms:$gen,
      input_tokens:$in_tok, output_tokens:$out_tok, token_chunks:$chunks,
      tokens_per_second:$tps}' > "$TMPDIR/direct_${iter}.json"
}

# ============================================================================
# AWS Bedrock — streaming via converse-stream (detailed timing)
# ============================================================================
run_bedrock_timed() {
  local iter="$1"

  if ! command -v aws &>/dev/null; then
    echo '{"error":"aws CLI not installed"}' > "$TMPDIR/bedrock_${iter}.json"
    return
  fi

  local t_start t_first_byte="" t_first_token="" t_end
  local output_tokens=0 input_tokens=0 token_chunks=0 server_latency=0

  t_start=$(ms_now)

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    # Mark first byte (any output from the stream)
    if [ -z "$t_first_byte" ]; then
      t_first_byte=$(ms_now)
    fi

    # Detect contentBlockDelta for TTFT (fast string match, no jq)
    if [[ "$line" == *'"contentBlockDelta"'* ]]; then
      if [ -z "$t_first_token" ]; then
        t_first_token=$(ms_now)
      fi
      token_chunks=$((token_chunks + 1))
    fi

    # Extract usage and server metrics from metadata event
    if [[ "$line" == *'"metadata"'* ]]; then
      output_tokens=$(echo "$line" | jq -r '.metadata.usage.outputTokens // 0' 2>/dev/null)
      input_tokens=$(echo "$line" | jq -r '.metadata.usage.inputTokens // 0' 2>/dev/null)
      server_latency=$(echo "$line" | jq -r '.metadata.metrics.latencyMs // 0' 2>/dev/null)
    fi
  done < <(aws bedrock-runtime converse-stream \
    --model-id "$BEDROCK_MODEL" \
    --messages "[{\"role\":\"user\",\"content\":[{\"text\":\"$PROMPT\"}]}]" \
    --inference-config "{\"maxTokens\":$MAX_TOKENS}" \
    --region "$BEDROCK_REGION" 2>"$TMPDIR/bedrock_err_${iter}")

  t_end=$(ms_now)

  # Check for errors (no events received, or stderr output)
  if [ -z "$t_first_byte" ]; then
    local err_msg="No streaming events received"
    [ -s "$TMPDIR/bedrock_err_${iter}" ] && err_msg=$(cat "$TMPDIR/bedrock_err_${iter}" | head -5)
    jq -nc --arg e "$err_msg" '{error:$e}' > "$TMPDIR/bedrock_${iter}.json"
    return
  fi

  # Compute all timing components
  local total_ms ttfb_ms ttft_ms generation_ms network_ms tps
  total_ms=$(echo "$t_end - $t_start" | bc)
  ttfb_ms=$(echo "${t_first_byte:-$t_end} - $t_start" | bc)
  ttft_ms=$(echo "${t_first_token:-$t_end} - $t_start" | bc)
  generation_ms=$(echo "$t_end - ${t_first_token:-$t_start}" | bc)
  tps=$(echo "scale=2; ${output_tokens:-0} / (${total_ms:-1} / 1000)" | bc 2>/dev/null || echo "0")

  # Network overhead = total - server latency (if available)
  network_ms=0
  if [ "$server_latency" != "0" ] && [ "$server_latency" != "null" ]; then
    network_ms=$(echo "$total_ms - $server_latency" | bc)
  fi

  jq -nc \
    --argjson total "$total_ms" \
    --argjson ttfb "$ttfb_ms" \
    --argjson ttft "$ttft_ms" \
    --argjson gen "$generation_ms" \
    --argjson server "$server_latency" \
    --argjson network "$network_ms" \
    --argjson in_tok "${input_tokens:-0}" \
    --argjson out_tok "${output_tokens:-0}" \
    --argjson chunks "$token_chunks" \
    --argjson tps "$tps" \
    '{total_ms:$total, ttfb_ms:$ttfb, ttft_ms:$ttft, generation_ms:$gen,
      server_latency_ms:$server, network_overhead_ms:$network,
      input_tokens:$in_tok, output_tokens:$out_tok, token_chunks:$chunks,
      tokens_per_second:$tps}' > "$TMPDIR/bedrock_${iter}.json"
}

# ============================================================================
# Run the benchmark
# ============================================================================
echo "============================================" >&2
echo "  SRE Latency Budget Analysis" >&2
echo "============================================" >&2
echo "  Prompt: fixed (count 1-20)" >&2
echo "  Max tokens: $MAX_TOKENS" >&2
echo "  Iterations: $ITERATIONS (+$WARMUP warmup)" >&2
echo "  Direct model: $DIRECT_MODEL" >&2
echo "  Bedrock model: $BEDROCK_MODEL" >&2
echo "  Bedrock region: $BEDROCK_REGION" >&2
echo "============================================" >&2
echo "" >&2

# Check which providers are available
HAS_DIRECT=false
HAS_BEDROCK=false

if [ "$PROVIDER" = "direct" ] || [ -z "$PROVIDER" ]; then
  [ -n "$ANTHROPIC_API_KEY" ] && HAS_DIRECT=true
fi

if [ "$PROVIDER" = "bedrock" ] || [ -z "$PROVIDER" ]; then
  if command -v aws &>/dev/null; then
    # Verify credentials are valid before wasting time on N iterations
    if aws sts get-caller-identity &>/dev/null; then
      HAS_BEDROCK=true
    else
      echo "SKIP: aws CLI found but credentials are invalid/expired. Skipping Bedrock." >&2
      echo "  Fix with: aws sso login / aws configure / export AWS_ACCESS_KEY_ID=..." >&2
      echo "" >&2
    fi
  fi
fi

if [ "$HAS_DIRECT" = "false" ] && [ "$HAS_BEDROCK" = "false" ]; then
  echo "ERROR: No valid providers available." >&2
  echo "  Direct API: set ANTHROPIC_API_KEY" >&2
  echo "  Bedrock: configure AWS credentials (aws sts get-caller-identity must succeed)" >&2
  exit 1
fi

# Run Direct API benchmark
if [ "$HAS_DIRECT" = "true" ]; then
  echo "--- Anthropic Direct API ($DIRECT_MODEL) ---" >&2
  for i in $(seq 1 "$TOTAL_RUNS"); do
    if [ "$i" -le "$WARMUP" ]; then
      printf "  Warmup %d/%d..." "$i" "$WARMUP" >&2
    else
      printf "  Run %d/%d..." "$((i - WARMUP))" "$ITERATIONS" >&2
    fi
    run_direct_timed "$i"
    result=$(cat "$TMPDIR/direct_${i}.json")
    err=$(echo "$result" | jq -r '.error // empty')
    if [ -n "$err" ]; then
      echo " ERROR: $err" >&2
    else
      ttft=$(echo "$result" | jq -r '.ttft_ms')
      total=$(echo "$result" | jq -r '.total_ms')
      echo " TTFT=${ttft}ms Total=${total}ms" >&2
    fi
    [ "$i" -lt "$TOTAL_RUNS" ] && sleep 1
  done
  echo "" >&2
fi

# Run Bedrock benchmark
if [ "$HAS_BEDROCK" = "true" ]; then
  echo "--- AWS Bedrock ($BEDROCK_MODEL) ---" >&2
  for i in $(seq 1 "$TOTAL_RUNS"); do
    if [ "$i" -le "$WARMUP" ]; then
      printf "  Warmup %d/%d..." "$i" "$WARMUP" >&2
    else
      printf "  Run %d/%d..." "$((i - WARMUP))" "$ITERATIONS" >&2
    fi
    run_bedrock_timed "$i"
    result=$(cat "$TMPDIR/bedrock_${i}.json")
    err=$(echo "$result" | jq -r '.error // empty')
    if [ -n "$err" ]; then
      echo " ERROR: $err" >&2
    else
      ttft=$(echo "$result" | jq -r '.ttft_ms')
      total=$(echo "$result" | jq -r '.total_ms')
      server=$(echo "$result" | jq -r '.server_latency_ms')
      echo " TTFT=${ttft}ms Total=${total}ms Server=${server}ms" >&2
    fi
    [ "$i" -lt "$TOTAL_RUNS" ] && sleep 1
  done
  echo "" >&2
fi

# ============================================================================
# Aggregate results (excluding warmup)
# ============================================================================
echo "--- Computing latency budget ---" >&2

# Helper: aggregate a provider's results
aggregate_timings() {
  local provider="$1"
  local start=$((WARMUP + 1))
  local files=""

  for i in $(seq "$start" "$TOTAL_RUNS"); do
    local f="$TMPDIR/${provider}_${i}.json"
    [ -f "$f" ] && files="$files $f"
  done

  if [ -z "$files" ]; then
    echo '{}'
    return
  fi

  # Concatenate non-error results and compute stats
  cat $files | jq -s '
    def pctile(arr; p):
      (arr | sort) as $s | ($s | length) as $n |
      if $n == 0 then 0
      else
        (($n - 1) * p) as $k | ($k | floor) as $f |
        if ($f + 1) >= $n then $s[$f]
        else $s[$f] + ($k - $f) * ($s[$f + 1] - $s[$f])
        end
      end;

    [.[] | select(.error == null)] as $ok |
    (length) as $total |
    ($total - ($ok | length)) as $errors |
    if ($ok | length) == 0 then {samples: $total, errors: $errors, error_rate: 1.0}
    else
      {
        samples: $total,
        errors: $errors,
        error_rate: (if $total > 0 then ($errors / $total) else 0 end),
        total_ms: {
          mean: ([$ok[].total_ms] | add / length | . * 100 | round / 100),
          p50:  (pctile([$ok[].total_ms]; 0.5)  | . * 100 | round / 100),
          p90:  (pctile([$ok[].total_ms]; 0.9)  | . * 100 | round / 100),
          p99:  (pctile([$ok[].total_ms]; 0.99) | . * 100 | round / 100)
        },
        output_tokens_mean: ([$ok[].output_tokens] | add / length | round),
        tps_mean: ([$ok[].tokens_per_second] | add / length | . * 100 | round / 100)
      }
      # Add provider-specific fields
      + (if ($ok[0] | has("ttft_ms")) then {
          ttfb_ms: {
            mean: ([$ok[].ttfb_ms] | add / length | . * 100 | round / 100),
            p50:  (pctile([$ok[].ttfb_ms]; 0.5) | . * 100 | round / 100),
            p90:  (pctile([$ok[].ttfb_ms]; 0.9) | . * 100 | round / 100)
          },
          ttft_ms: {
            mean: ([$ok[].ttft_ms] | add / length | . * 100 | round / 100),
            p50:  (pctile([$ok[].ttft_ms]; 0.5) | . * 100 | round / 100),
            p90:  (pctile([$ok[].ttft_ms]; 0.9) | . * 100 | round / 100)
          },
          generation_ms: {
            mean: ([$ok[].generation_ms] | add / length | . * 100 | round / 100),
            p50:  (pctile([$ok[].generation_ms]; 0.5) | . * 100 | round / 100)
          }
        } else {} end)
      + (if ($ok[0] | has("server_latency_ms")) then {
          server_latency_ms: {
            mean: ([$ok[].server_latency_ms] | add / length | . * 100 | round / 100),
            p50:  (pctile([$ok[].server_latency_ms]; 0.5) | . * 100 | round / 100)
          },
          network_overhead_ms: {
            mean: ([$ok[].network_overhead_ms] | add / length | . * 100 | round / 100),
            p50:  (pctile([$ok[].network_overhead_ms]; 0.5) | . * 100 | round / 100)
          }
        } else {} end)
    end
  '
}

DIRECT_STATS="{}"
BEDROCK_STATS="{}"
[ "$HAS_DIRECT" = "true" ] && DIRECT_STATS=$(aggregate_timings "direct")
[ "$HAS_BEDROCK" = "true" ] && BEDROCK_STATS=$(aggregate_timings "bedrock")

# Read current session tool stats
TOOL_STATS="{}"
TOOL_LOG="/tmp/sre-latency-monitor.jsonl"
if [ -f "$TOOL_LOG" ]; then
  TOOL_STATS=$(jq -sr '
    [.[] | select(.event == "tool_call" and .duration_ms != null and .duration_ms > 0)] |
    if length == 0 then {}
    else
      {
        total_calls: length,
        total_tool_ms: ([.[].duration_ms] | add | . * 100 | round / 100),
        by_category: (
          group_by(
            if (.tool_name // "" | startswith("mcp__")) then "MCP"
            elif .tool_name == "Bash" then "Bash"
            elif .tool_name == "Task" then "Task"
            else "CLI" end
          ) | map({
            key: (.[0] |
              if (.tool_name // "" | startswith("mcp__")) then "MCP"
              elif .tool_name == "Bash" then "Bash"
              elif .tool_name == "Task" then "Task"
              else "CLI" end
            ),
            value: {
              calls: length,
              total_ms: ([.[].duration_ms] | add | . * 100 | round / 100),
              mean_ms: ([.[].duration_ms] | add / length | . * 100 | round / 100)
            }
          }) | from_entries
        )
      }
    end
  ' "$TOOL_LOG" 2>/dev/null)
fi

# ============================================================================
# Build the latency budget report
# ============================================================================
# Collect environment metadata for reproducibility and comparison
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ENV_HOSTNAME=$(hostname -s 2>/dev/null || echo "unknown")
ENV_OS=$(uname -s 2>/dev/null || echo "unknown")
ENV_ARCH=$(uname -m 2>/dev/null || echo "unknown")
ENV_OS_VER=$(sw_vers -productVersion 2>/dev/null || uname -r 2>/dev/null || echo "unknown")
ENV_REGION_HINT=$(curl -s --max-time 2 "http://ip-api.com/json?fields=regionName,countryCode" 2>/dev/null | jq -r '"\(.countryCode)/\(.regionName)"' 2>/dev/null || echo "unknown")

REPORT=$(jq -nc \
  --arg ts "$TIMESTAMP" \
  --arg hostname "$ENV_HOSTNAME" \
  --arg os "$ENV_OS" \
  --arg arch "$ENV_ARCH" \
  --arg os_ver "$ENV_OS_VER" \
  --arg region_hint "$ENV_REGION_HINT" \
  --arg prompt "$PROMPT" \
  --argjson max_tokens "$MAX_TOKENS" \
  --argjson iterations "$ITERATIONS" \
  --argjson warmup "$WARMUP" \
  --arg direct_model "$DIRECT_MODEL" \
  --arg bedrock_model "$BEDROCK_MODEL" \
  --arg bedrock_region "$BEDROCK_REGION" \
  --argjson direct "$DIRECT_STATS" \
  --argjson bedrock "$BEDROCK_STATS" \
  --argjson tools "$TOOL_STATS" \
  '{
    timestamp: $ts,
    environment: {
      hostname: $hostname,
      os: "\($os) \($os_ver)",
      arch: $arch,
      client_region: $region_hint
    },
    config: {
      prompt: $prompt,
      max_tokens: $max_tokens,
      iterations: $iterations,
      warmup_discarded: $warmup,
      direct_model: $direct_model,
      bedrock_model: $bedrock_model,
      bedrock_region: $bedrock_region
    },
    providers: {
      anthropic_direct: $direct,
      aws_bedrock: $bedrock
    },
    latency_budget: (
      # Compute the budget breakdown
      if ($direct != {} and $bedrock != {} and
          ($direct.total_ms.mean // 0) > 0 and ($bedrock.total_ms.mean // 0) > 0) then
      {
        direct_total_mean_ms: $direct.total_ms.mean,
        bedrock_total_mean_ms: $bedrock.total_ms.mean,
        bedrock_overhead_ms: (($bedrock.total_ms.mean - $direct.total_ms.mean) | . * 100 | round / 100),
        bedrock_overhead_pct: ((($bedrock.total_ms.mean - $direct.total_ms.mean) / $direct.total_ms.mean * 100) | . * 10 | round / 10)
      }
      # Add TTFT comparison when both providers have streaming data
      + (if ($direct.ttft_ms.mean // 0) > 0 and ($bedrock.ttft_ms.mean // 0) > 0 then {
          direct_ttft_mean_ms: $direct.ttft_ms.mean,
          bedrock_ttft_mean_ms: $bedrock.ttft_ms.mean,
          ttft_overhead_ms: (($bedrock.ttft_ms.mean - $direct.ttft_ms.mean) | . * 100 | round / 100),
          ttft_overhead_pct: ((($bedrock.ttft_ms.mean - $direct.ttft_ms.mean) / $direct.ttft_ms.mean * 100) | . * 10 | round / 10),
          note: "Both providers measured via streaming. TTFT overhead isolates Bedrock routing/guardrails cost before token generation begins."
        } else {
          note: "bedrock_overhead includes: Bedrock routing, guardrails, network hops. Direct TTFT measures pure model latency."
        } end)
      elif ($direct != {} and ($direct.total_ms.mean // 0) > 0) then
      {
        direct_total_mean_ms: $direct.total_ms.mean,
        direct_ttft_mean_ms: ($direct.ttft_ms.mean // null),
        direct_generation_mean_ms: ($direct.generation_ms.mean // null),
        note: "Only Direct API data available. Set AWS credentials to compare with Bedrock."
      }
      elif ($bedrock != {} and ($bedrock.total_ms.mean // 0) > 0) then
      {
        bedrock_total_mean_ms: $bedrock.total_ms.mean,
        bedrock_server_latency_mean_ms: ($bedrock.server_latency_ms.mean // null),
        bedrock_network_overhead_mean_ms: ($bedrock.network_overhead_ms.mean // null),
        note: "Only Bedrock data available. Set ANTHROPIC_API_KEY to compare with Direct API."
      }
      else { note: "No successful benchmark data collected." }
      end
    ),
    session_tool_budget: $tools
  }')

# Save if output file specified
if [ -n "$OUTPUT_FILE" ]; then
  echo "$REPORT" | jq '.' > "$OUTPUT_FILE"
  echo "Full report saved to $OUTPUT_FILE" >&2
fi

# Output the report
echo "$REPORT" | jq '.'
