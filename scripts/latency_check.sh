#!/bin/bash
# Quick latency check — single-request probe against a specific provider
# Pure bash/curl/jq/perl — no Python required.
#
# Usage: latency_check.sh <provider> [--model <id>] [--prompt <text>] [--max-tokens <n>] [--bedrock-region <region>]
# Providers: anthropic-direct, aws-bedrock, both

set -eo pipefail

# --- Locate script directory (for helper scripts) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Bootstrap Python with boto3 for Bedrock streaming ---
STREAM_PYTHON=""
BOTO3_VENV="/tmp/sre-boto3-venv"
find_stream_python() {
  for p in python3 "$BOTO3_VENV/bin/python3"; do
    if "$p" -c "import boto3" 2>/dev/null; then
      STREAM_PYTHON="$p"
      return 0
    fi
  done
  if command -v python3 &>/dev/null; then
    python3 -m venv "$BOTO3_VENV" 2>/dev/null && \
      "$BOTO3_VENV/bin/pip" install -q boto3 2>/dev/null && \
      STREAM_PYTHON="$BOTO3_VENV/bin/python3"
    [ -n "$STREAM_PYTHON" ] && return 0
  fi
  return 1
}

# --- Argument parsing ---
PROVIDER=""
MODEL=""
PROMPT="Respond with exactly: pong"
MAX_TOKENS=64
BEDROCK_REGION="us-east-1"

while [ $# -gt 0 ]; do
  case "$1" in
    anthropic-direct|direct) PROVIDER="anthropic-direct"; shift ;;
    aws-bedrock|bedrock)     PROVIDER="aws-bedrock"; shift ;;
    both)                    PROVIDER="both"; shift ;;
    --model)          MODEL="$2"; shift 2 ;;
    --prompt)         PROMPT="$2"; shift 2 ;;
    --max-tokens)     MAX_TOKENS="$2"; shift 2 ;;
    --bedrock-region) BEDROCK_REGION="$2"; shift 2 ;;
    *) PROVIDER="${PROVIDER:-$1}"; shift ;;
  esac
done
PROVIDER="${PROVIDER:-both}"

# --- Timing utility (millisecond precision via perl) ---
ms_now() { perl -MTime::HiRes=time -e 'printf "%.2f", time()*1000'; }

# --- Anthropic Direct API (curl + SSE streaming) ---
check_direct() {
  local model="${MODEL:-claude-haiku-4-5}"

  if [ -z "$ANTHROPIC_API_KEY" ]; then
    jq -nc --arg m "$model" \
      '{provider:"anthropic-direct", model:$m, status:"error", error:"ANTHROPIC_API_KEY not set"}'
    return
  fi

  local payload
  payload=$(jq -nc --arg m "$model" --arg p "$PROMPT" --argjson t "$MAX_TOKENS" \
    '{model:$m, max_tokens:$t, stream:true, messages:[{role:"user",content:$p}]}')

  local start ttft="" output_tokens=0 input_tokens=0 first=1 got_error=""
  start=$(ms_now)

  while IFS= read -r line; do
    # SSE format: data lines contain the payload
    [[ "$line" != data:* ]] && continue
    local data="${line#data: }"
    [[ "$data" == "[DONE]" ]] && break

    local etype
    etype=$(echo "$data" | jq -r '.type // ""' 2>/dev/null)

    # Check for API error
    if [[ "$etype" == "error" ]]; then
      got_error=$(echo "$data" | jq -r '.error.message // "unknown error"' 2>/dev/null)
      break
    fi

    # TTFT: first content_block_delta event
    if [[ "$etype" == "content_block_delta" && "$first" == "1" ]]; then
      ttft=$(echo "$(ms_now) - $start" | bc)
      first=0
    fi

    # Final usage: message_delta has output_tokens
    if [[ "$etype" == "message_delta" ]]; then
      output_tokens=$(echo "$data" | jq -r '.usage.output_tokens // 0' 2>/dev/null)
    fi

    # Initial usage: message_start has input_tokens
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
      '{provider:"anthropic-direct", model:$m, status:"error", total_ms:$t, error:$e}'
    return
  fi

  tps=$(echo "scale=2; ${output_tokens:-0} / (${total:-1} / 1000)" | bc 2>/dev/null || echo "0")

  jq -nc --arg m "$model" \
    --argjson ttft "${ttft:-0}" --argjson total "${total:-0}" \
    --argjson in_tok "${input_tokens:-0}" --argjson out_tok "${output_tokens:-0}" \
    --argjson tps "${tps:-0}" \
    '{provider:"anthropic-direct", model:$m, status:"ok", ttft_ms:$ttft, total_ms:$total, input_tokens:$in_tok, output_tokens:$out_tok, tokens_per_second:$tps}'

  # Persist TTFT for statusline
  if [ "${ttft:-0}" != "0" ]; then
    jq -nc --arg m "$model" --argjson t "${ttft:-0}" \
      '{provider:"anthropic-direct", model:$m, ttft_ms:$t, timestamp:now|strftime("%Y-%m-%dT%H:%M:%SZ")}' \
      > /tmp/sre-latency-ttft.json 2>/dev/null
  fi
}

# --- AWS Bedrock (streaming via boto3, fallback to non-streaming converse) ---
check_bedrock() {
  local model="${MODEL:-us.anthropic.claude-haiku-4-5-20251001-v1:0}"

  if ! command -v aws &>/dev/null; then
    jq -nc --arg m "$model" \
      '{provider:"aws-bedrock", model:$m, status:"error", error:"aws CLI not installed"}'
    return
  fi

  # Try streaming first
  find_stream_python
  if [ -n "$STREAM_PYTHON" ]; then
    _check_bedrock_streaming "$model"
  else
    _check_bedrock_nonstreaming "$model"
  fi
}

_check_bedrock_streaming() {
  local model="$1"
  local start ttft="" output_tokens=0 input_tokens=0
  start=$(ms_now)

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" == *'"contentBlockDelta"'* && -z "$ttft" ]]; then
      ttft=$(echo "$(ms_now) - $start" | bc)
    fi
    if [[ "$line" == *'"metadata"'* ]]; then
      output_tokens=$(echo "$line" | jq -r '.metadata.usage.outputTokens // 0' 2>/dev/null)
      input_tokens=$(echo "$line" | jq -r '.metadata.usage.inputTokens // 0' 2>/dev/null)
    fi
  done < <("$STREAM_PYTHON" "$SCRIPT_DIR/bedrock_stream.py" \
    --model "$model" --region "$BEDROCK_REGION" \
    --max-tokens "$MAX_TOKENS" --prompt "$PROMPT" 2>/dev/null)

  local end total tps
  end=$(ms_now)
  total=$(echo "$end - $start" | bc)

  if [ -z "$ttft" ] && [ "${output_tokens:-0}" = "0" ]; then
    jq -nc --arg m "$model" --argjson t "${total:-0}" \
      '{provider:"aws-bedrock", model:$m, status:"error", total_ms:$t, error:"boto3 streaming returned no events"}'
    return
  fi

  tps=$(echo "scale=2; ${output_tokens:-0} / (${total:-1} / 1000)" | bc 2>/dev/null || echo "0")

  jq -nc --arg m "$model" \
    --argjson ttft "${ttft:-$total}" --argjson total "${total:-0}" \
    --argjson in_tok "${input_tokens:-0}" --argjson out_tok "${output_tokens:-0}" \
    --argjson tps "${tps:-0}" \
    '{provider:"aws-bedrock", model:$m, status:"ok", ttft_ms:$ttft, total_ms:$total, input_tokens:$in_tok, output_tokens:$out_tok, tokens_per_second:$tps}'

  if [ "${ttft:-0}" != "0" ]; then
    jq -nc --arg m "$model" --argjson t "${ttft:-0}" \
      '{provider:"aws-bedrock", model:$m, ttft_ms:$t, timestamp:now|strftime("%Y-%m-%dT%H:%M:%SZ")}' \
      > /tmp/sre-latency-ttft.json 2>/dev/null
  fi
}

_check_bedrock_nonstreaming() {
  local model="$1"
  local start end total response
  start=$(ms_now)

  response=$(aws bedrock-runtime converse \
    --model-id "$model" \
    --messages "[{\"role\":\"user\",\"content\":[{\"text\":\"$PROMPT\"}]}]" \
    --inference-config "{\"maxTokens\":$MAX_TOKENS}" \
    --region "$BEDROCK_REGION" \
    --output json 2>&1) || {
    end=$(ms_now)
    total=$(echo "$end - $start" | bc)
    jq -nc --arg m "$model" --argjson t "${total:-0}" --arg e "$response" \
      '{provider:"aws-bedrock", model:$m, status:"error", total_ms:$t, error:$e}'
    return
  }

  end=$(ms_now)
  total=$(echo "$end - $start" | bc)

  local output_tokens input_tokens tps
  output_tokens=$(echo "$response" | jq -r '.usage.outputTokens // 0')
  input_tokens=$(echo "$response" | jq -r '.usage.inputTokens // 0')
  tps=$(echo "scale=2; ${output_tokens:-0} / (${total:-1} / 1000)" | bc 2>/dev/null || echo "0")

  jq -nc --arg m "$model" \
    --argjson total "${total:-0}" \
    --argjson in_tok "${input_tokens:-0}" --argjson out_tok "${output_tokens:-0}" \
    --argjson tps "${tps:-0}" \
    '{provider:"aws-bedrock", model:$m, status:"ok", ttft_ms:"N/A (non-streaming)", total_ms:$total, input_tokens:$in_tok, output_tokens:$out_tok, tokens_per_second:$tps}'

  jq -nc --arg m "$model" --argjson t "${total:-0}" \
    '{provider:"aws-bedrock", model:$m, ttft_ms:$t, note:"total latency (non-streaming)", timestamp:now|strftime("%Y-%m-%dT%H:%M:%SZ")}' \
    > /tmp/sre-latency-ttft.json 2>/dev/null
}

# --- Main ---
case "$PROVIDER" in
  anthropic-direct) check_direct ;;
  aws-bedrock)      check_bedrock ;;
  both)
    check_direct
    echo ""
    check_bedrock
    ;;
  *) echo "Unknown provider: $PROVIDER. Use: anthropic-direct, aws-bedrock, or both" >&2; exit 1 ;;
esac
