#!/bin/bash
# SRE Latency Benchmark — Anthropic Direct vs AWS Bedrock
# Pure bash/curl/jq/perl — no Python required.
#
# Usage: benchmark.sh [-n iterations] [-p providers] [--prompt-size short|medium|long]
#        [--max-tokens N] [--direct-model ID] [--bedrock-model ID]
#        [--bedrock-region REGION] [-o output.json]

set -eo pipefail

# --- Defaults ---
ITERATIONS=5
PROMPT_SIZE="medium"
MAX_TOKENS=512
DIRECT_MODEL="claude-haiku-4-5"
BEDROCK_MODEL="us.anthropic.claude-haiku-4-5-20251001-v1:0"
BEDROCK_REGION="us-east-1"
OUTPUT_FILE=""
PROVIDERS=""

# --- Argument parsing ---
while [ $# -gt 0 ]; do
  case "$1" in
    -n|--iterations)    ITERATIONS="$2"; shift 2 ;;
    -p|--providers)     shift; while [ $# -gt 0 ] && [[ "$1" != -* ]]; do PROVIDERS="$PROVIDERS $1"; shift; done ;;
    --prompt-size)      PROMPT_SIZE="$2"; shift 2 ;;
    --max-tokens)       MAX_TOKENS="$2"; shift 2 ;;
    --direct-model)     DIRECT_MODEL="$2"; shift 2 ;;
    --bedrock-model)    BEDROCK_MODEL="$2"; shift 2 ;;
    --bedrock-region)   BEDROCK_REGION="$2"; shift 2 ;;
    -o|--output)        OUTPUT_FILE="$2"; shift 2 ;;
    *) shift ;;
  esac
done
PROVIDERS="${PROVIDERS:-anthropic-direct aws-bedrock}"

# --- Test prompts ---
case "$PROMPT_SIZE" in
  short)  PROMPT="Say hello in exactly 5 words." ;;
  long)   PROMPT="Write a detailed technical analysis of how consistent hashing works, including virtual nodes, rebalancing strategies, and failure scenarios. Cover at least 5 key implementation considerations." ;;
  *)      PROMPT="Explain the CAP theorem in distributed systems in 3 paragraphs." ;;
esac

# --- Timing utility ---
ms_now() { perl -MTime::HiRes=time -e 'printf "%.2f", time()*1000'; }

# --- Temp directory for results ---
TMPDIR=$(mktemp -d /tmp/sre-bench-XXXXXX)
trap "rm -rf $TMPDIR" EXIT

# --- Run single Direct API request (streaming, measures TTFT) ---
run_direct_once() {
  local model="$1" prompt="$2" max_tokens="$3" iter="$4"

  if [ -z "$ANTHROPIC_API_KEY" ]; then
    jq -nc --arg m "$model" '{provider:"anthropic-direct",model:$m,ttft_ms:0,total_ms:0,output_tokens:0,input_tokens:0,tokens_per_second:0,error:"ANTHROPIC_API_KEY not set"}'
    return
  fi

  local payload
  payload=$(jq -nc --arg m "$model" --arg p "$prompt" --argjson t "$max_tokens" \
    '{model:$m, max_tokens:$t, stream:true, messages:[{role:"user",content:$p}]}')

  local start ttft="" output_tokens=0 input_tokens=0 first=1 got_error=""
  start=$(ms_now)

  while IFS= read -r line; do
    [[ "$line" != data:* ]] && continue
    local data="${line#data: }"
    [[ "$data" == "[DONE]" ]] && break

    local etype
    etype=$(echo "$data" | jq -r '.type // ""' 2>/dev/null)

    if [[ "$etype" == "error" ]]; then
      got_error=$(echo "$data" | jq -r '.error.message // "unknown"' 2>/dev/null)
      break
    fi

    if [[ "$etype" == "content_block_delta" && "$first" == "1" ]]; then
      ttft=$(echo "$(ms_now) - $start" | bc)
      first=0
    fi

    if [[ "$etype" == "message_delta" ]]; then
      output_tokens=$(echo "$data" | jq -r '.usage.output_tokens // 0' 2>/dev/null)
    fi

    if [[ "$etype" == "message_start" ]]; then
      input_tokens=$(echo "$data" | jq -r '.message.usage.input_tokens // 0' 2>/dev/null)
    fi
  done < <(curl -sN -X POST "https://api.anthropic.com/v1/messages" \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d "$payload" 2>/dev/null)

  local end total tps
  end=$(ms_now)
  total=$(echo "$end - $start" | bc)

  if [ -n "$got_error" ]; then
    jq -nc --arg m "$model" --argjson t "${total:-0}" --arg e "$got_error" \
      '{provider:"anthropic-direct",model:$m,ttft_ms:0,total_ms:$t,output_tokens:0,input_tokens:0,tokens_per_second:0,error:$e}'
    return
  fi

  tps=$(echo "scale=2; ${output_tokens:-0} / (${total:-1} / 1000)" | bc 2>/dev/null || echo "0")

  jq -nc --arg m "$model" \
    --argjson ttft "${ttft:-0}" --argjson total "${total:-0}" \
    --argjson in_tok "${input_tokens:-0}" --argjson out_tok "${output_tokens:-0}" \
    --argjson tps "${tps:-0}" \
    '{provider:"anthropic-direct",model:$m,ttft_ms:$ttft,total_ms:$total,input_tokens:$in_tok,output_tokens:$out_tok,tokens_per_second:$tps}'
}

# --- Run single Bedrock request (non-streaming) ---
run_bedrock_once() {
  local model="$1" prompt="$2" max_tokens="$3" region="$4" iter="$5"

  if ! command -v aws &>/dev/null; then
    jq -nc --arg m "$model" '{provider:"aws-bedrock",model:$m,ttft_ms:0,total_ms:0,output_tokens:0,input_tokens:0,tokens_per_second:0,error:"aws CLI not installed"}'
    return
  fi

  local start end total response
  start=$(ms_now)

  response=$(aws bedrock-runtime converse \
    --model-id "$model" \
    --messages "[{\"role\":\"user\",\"content\":[{\"text\":\"$prompt\"}]}]" \
    --inference-config "{\"maxTokens\":$max_tokens}" \
    --region "$region" \
    --output json 2>&1) || {
    end=$(ms_now)
    total=$(echo "$end - $start" | bc)
    jq -nc --arg m "$model" --argjson t "${total:-0}" --arg e "$response" \
      '{provider:"aws-bedrock",model:$m,ttft_ms:0,total_ms:$t,output_tokens:0,input_tokens:0,tokens_per_second:0,error:$e}'
    return
  }

  end=$(ms_now)
  total=$(echo "$end - $start" | bc)

  local output_tokens input_tokens tps
  output_tokens=$(echo "$response" | jq -r '.usage.outputTokens // 0')
  input_tokens=$(echo "$response" | jq -r '.usage.inputTokens // 0')
  tps=$(echo "scale=2; ${output_tokens:-0} / (${total:-1} / 1000)" | bc 2>/dev/null || echo "0")

  # For non-streaming, TTFT ≈ total (all tokens arrive at once)
  jq -nc --arg m "$model" \
    --argjson ttft "${total:-0}" --argjson total "${total:-0}" \
    --argjson in_tok "${input_tokens:-0}" --argjson out_tok "${output_tokens:-0}" \
    --argjson tps "${tps:-0}" \
    '{provider:"aws-bedrock",model:$m,ttft_ms:$ttft,total_ms:$total,input_tokens:$in_tok,output_tokens:$out_tok,tokens_per_second:$tps}'
}

# --- Run benchmark for a provider ---
run_provider() {
  local provider="$1"
  local model results_file

  if [ "$provider" = "anthropic-direct" ]; then
    model="$DIRECT_MODEL"
  else
    model="$BEDROCK_MODEL"
  fi

  results_file="$TMPDIR/${provider}.jsonl"
  > "$results_file"

  echo "--- Benchmarking $provider ($model) ---" >&2
  echo "    Prompt size: $PROMPT_SIZE | Max tokens: $MAX_TOKENS | Iterations: $ITERATIONS" >&2

  for i in $(seq 1 "$ITERATIONS"); do
    printf "    Run %d/%d..." "$i" "$ITERATIONS" >&2

    local result
    if [ "$provider" = "anthropic-direct" ]; then
      result=$(run_direct_once "$model" "$PROMPT" "$MAX_TOKENS" "$i")
    else
      result=$(run_bedrock_once "$model" "$PROMPT" "$MAX_TOKENS" "$BEDROCK_REGION" "$i")
    fi

    echo "$result" >> "$results_file"

    local err ttft total tps
    err=$(echo "$result" | jq -r '.error // empty')
    if [ -n "$err" ]; then
      echo " ERROR: $err" >&2
    else
      ttft=$(echo "$result" | jq -r '.ttft_ms')
      total=$(echo "$result" | jq -r '.total_ms')
      tps=$(echo "$result" | jq -r '.tokens_per_second')
      echo " TTFT=${ttft}ms  Total=${total}ms  ${tps} t/s" >&2
    fi

    # Brief pause between requests
    [ "$i" -lt "$ITERATIONS" ] && sleep 1
  done
}

# --- Aggregate results using jq ---
aggregate_provider() {
  local provider="$1" results_file="$TMPDIR/${provider}.jsonl"

  if [ ! -s "$results_file" ]; then
    echo '{}'
    return
  fi

  jq -s --arg p "$provider" '
    . as $all |
    [.[] | select(.error == null)] as $ok |
    ($all | length) as $total |
    ($all | length - ($ok | length)) as $errors |

    if ($ok | length) == 0 then
      {provider: $p, model: $all[0].model, samples: $total,
       ttft_p50_ms:0, ttft_p90_ms:0, ttft_p95_ms:0, ttft_p99_ms:0, ttft_mean_ms:0,
       total_p50_ms:0, total_p90_ms:0, total_p95_ms:0, total_p99_ms:0, total_mean_ms:0,
       throughput_p50_tps:0, throughput_mean_tps:0, error_rate:1.0}
    else
      def pctile(arr; p):
        (arr | sort) as $s | ($s | length) as $n |
        (($n - 1) * p) as $k | ($k | floor) as $f |
        if ($f + 1) >= $n then $s[$f]
        else $s[$f] + ($k - $f) * ($s[$f + 1] - $s[$f])
        end;

      [$ok[].ttft_ms] as $ttfts |
      [$ok[].total_ms] as $totals |
      [$ok[].tokens_per_second] as $tps |

      {
        provider: $p,
        model: $ok[0].model,
        samples: $total,
        ttft_p50_ms:  (pctile($ttfts; 0.5)  | . * 100 | round / 100),
        ttft_p90_ms:  (pctile($ttfts; 0.9)  | . * 100 | round / 100),
        ttft_p95_ms:  (pctile($ttfts; 0.95) | . * 100 | round / 100),
        ttft_p99_ms:  (pctile($ttfts; 0.99) | . * 100 | round / 100),
        ttft_mean_ms: (($ttfts | add / length) | . * 100 | round / 100),
        total_p50_ms:  (pctile($totals; 0.5)  | . * 100 | round / 100),
        total_p90_ms:  (pctile($totals; 0.9)  | . * 100 | round / 100),
        total_p95_ms:  (pctile($totals; 0.95) | . * 100 | round / 100),
        total_p99_ms:  (pctile($totals; 0.99) | . * 100 | round / 100),
        total_mean_ms: (($totals | add / length) | . * 100 | round / 100),
        throughput_p50_tps:  (pctile($tps; 0.5) | . * 100 | round / 100),
        throughput_mean_tps: (($tps | add / length) | . * 100 | round / 100),
        error_rate: (($errors / $total) * 10000 | round / 10000)
      }
    end
  ' "$results_file"
}

# --- Main benchmark loop ---
echo "" >&2
for PROV in $PROVIDERS; do
  run_provider "$PROV"
done

# --- Build report ---
SUMMARY="{}"
RAW_RESULTS="{}"

for PROV in $PROVIDERS; do
  AGG=$(aggregate_provider "$PROV")
  SUMMARY=$(echo "$SUMMARY" | jq --arg p "$PROV" --argjson a "$AGG" '.[$p] = $a')

  RAW=$(jq -s '.' "$TMPDIR/${PROV}.jsonl" 2>/dev/null || echo '[]')
  RAW_RESULTS=$(echo "$RAW_RESULTS" | jq --arg p "$PROV" --argjson r "$RAW" '.[$p] = $r')
done

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

REPORT=$(jq -nc \
  --arg ts "$TIMESTAMP" \
  --argjson iter "$ITERATIONS" \
  --arg ps "$PROMPT_SIZE" \
  --argjson mt "$MAX_TOKENS" \
  --argjson summary "$SUMMARY" \
  --argjson raw "$RAW_RESULTS" \
  '{
    timestamp: $ts,
    config: {iterations: $iter, prompt_size: $ps, max_tokens: $mt, providers: ($summary | keys)},
    summary: $summary,
    raw_results: $raw
  }')

# Save full report if output file specified
if [ -n "$OUTPUT_FILE" ]; then
  echo "$REPORT" | jq '.' > "$OUTPUT_FILE"
  echo "" >&2
  echo "Report saved to $OUTPUT_FILE" >&2
fi

# Persist last TTFT for statusline
for PROV in $PROVIDERS; do
  MEAN_TTFT=$(echo "$SUMMARY" | jq -r --arg p "$PROV" '.[$p].ttft_mean_ms // 0')
  if [ "$MEAN_TTFT" != "0" ]; then
    MODEL=$(echo "$SUMMARY" | jq -r --arg p "$PROV" '.[$p].model // "unknown"')
    P99_TTFT=$(echo "$SUMMARY" | jq -r --arg p "$PROV" '.[$p].ttft_p99_ms // 0')
    jq -nc --arg p "$PROV" --arg m "$MODEL" \
      --argjson t "$MEAN_TTFT" --argjson p99 "$P99_TTFT" \
      '{provider:$p, model:$m, ttft_ms:$t, ttft_p99_ms:$p99, timestamp:now|strftime("%Y-%m-%dT%H:%M:%SZ")}' \
      > /tmp/sre-latency-ttft.json 2>/dev/null
  fi
done

# Print summary to stdout
echo "$SUMMARY" | jq '.'
