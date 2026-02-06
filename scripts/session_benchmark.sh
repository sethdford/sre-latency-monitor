#!/bin/bash
# ============================================================================
# SRE Session Benchmark — Real Claude Code session comparison
# ============================================================================
#
# Runs the SAME coding task through Claude Code twice:
#   1. Anthropic Direct API (default)
#   2. AWS Bedrock
#
# Measures actual end-user experience: model selection, tool calls,
# streaming, context management — the whole stack.
#
# Usage:
#   session_benchmark.sh [--task simple|medium|complex] [--output FILE]
#
# Requires: ANTHROPIC_API_KEY, AWS credentials, claude CLI

set -eo pipefail

TASK_LEVEL="medium"
OUTPUT_FILE=""
BEDROCK_REGION="${AWS_REGION:-us-east-1}"
SESSION_MODEL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --task|-t)   TASK_LEVEL="$2"; shift 2 ;;
    --output|-o) OUTPUT_FILE="$2"; shift 2 ;;
    --region|-r) BEDROCK_REGION="$2"; shift 2 ;;
    --model|-m)  SESSION_MODEL="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: session_benchmark.sh [--task simple|medium|complex] [--output FILE]"
      echo ""
      echo "Tasks:"
      echo "  simple   — Write a function + docstring (~2-3 tool calls)"
      echo "  medium   — Write a module with tests (~5-8 tool calls)"
      echo "  complex  — Read existing code, refactor, add tests (~10-15 tool calls)"
      exit 0
      ;;
    *) shift ;;
  esac
done

# --- Timing utility ---
ms_now() { perl -MTime::HiRes=time -e 'printf "%.3f", time()*1000'; }

# --- Task prompts (deterministic, reproducible) ---
TASK_SIMPLE='Write a Python function called "fibonacci" in /tmp/sre-bench/fib.py that returns the nth Fibonacci number using iteration (not recursion). Include a docstring. Then verify it works by running: python3 -c "import sys; sys.path.insert(0, \"/tmp/sre-bench\"); from fib import fibonacci; print([fibonacci(i) for i in range(10)])"'

TASK_MEDIUM='Create a Python module at /tmp/sre-bench/calculator.py with a Calculator class that supports add, subtract, multiply, divide (with ZeroDivisionError handling), and a history() method that returns the last 10 operations. Then create /tmp/sre-bench/test_calculator.py with pytest tests covering all operations including edge cases. Finally run the tests with: python3 -m pytest /tmp/sre-bench/test_calculator.py -v'

TASK_COMPLEX='Read the files in /tmp/sre-bench/legacy/ to understand the existing code. Then refactor the code: extract the data processing logic into a clean DataProcessor class in /tmp/sre-bench/processor.py with proper error handling and type hints. Create /tmp/sre-bench/test_processor.py with comprehensive pytest tests. Run the tests with: python3 -m pytest /tmp/sre-bench/test_processor.py -v'

# Select task
case "$TASK_LEVEL" in
  simple)  TASK_PROMPT="$TASK_SIMPLE" ;;
  medium)  TASK_PROMPT="$TASK_MEDIUM" ;;
  complex) TASK_PROMPT="$TASK_COMPLEX" ;;
  *) echo "Unknown task level: $TASK_LEVEL" >&2; exit 1 ;;
esac

# --- Setup workspace ---
rm -rf /tmp/sre-bench
mkdir -p /tmp/sre-bench

# For complex task, create legacy code to read/refactor
if [ "$TASK_LEVEL" = "complex" ]; then
  mkdir -p /tmp/sre-bench/legacy
  cat > /tmp/sre-bench/legacy/process.py << 'PYEOF'
import json

data = []

def load(path):
    global data
    with open(path) as f:
        data = json.load(f)

def process():
    result = []
    for item in data:
        if item.get("active") and item.get("score", 0) > 50:
            name = item["name"].strip().title()
            result.append({"name": name, "score": item["score"], "grade": "A" if item["score"] > 90 else "B" if item["score"] > 75 else "C"})
    result.sort(key=lambda x: x["score"], reverse=True)
    return result

def summary():
    processed = process()
    total = sum(x["score"] for x in processed)
    return {"count": len(processed), "total": total, "average": total / len(processed) if processed else 0, "top": processed[0]["name"] if processed else None}
PYEOF

  cat > /tmp/sre-bench/legacy/data.json << 'JSONEOF'
[
  {"name": "alice", "score": 95, "active": true},
  {"name": "bob", "score": 42, "active": true},
  {"name": "charlie", "score": 78, "active": false},
  {"name": "diana", "score": 88, "active": true},
  {"name": "eve", "score": 55, "active": true}
]
JSONEOF
fi

# --- Environment metadata ---
ENV_HOSTNAME=$(hostname -s 2>/dev/null || echo "unknown")
ENV_OS=$(uname -s 2>/dev/null || echo "unknown")
ENV_ARCH=$(uname -m 2>/dev/null || echo "unknown")
ENV_OS_VER=$(sw_vers -productVersion 2>/dev/null || uname -r 2>/dev/null || echo "unknown")
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "============================================" >&2
echo "  SRE Session Benchmark" >&2
echo "============================================" >&2
echo "  Task: $TASK_LEVEL" >&2
echo "  Host: $ENV_HOSTNAME ($ENV_OS $ENV_OS_VER $ENV_ARCH)" >&2
echo "  Region: $BEDROCK_REGION" >&2
echo "============================================" >&2
echo "" >&2

# --- Check providers ---
HAS_DIRECT=false
HAS_BEDROCK=false

source ~/.bashrc 2>/dev/null
[ -n "$ANTHROPIC_API_KEY" ] && HAS_DIRECT=true

if [ -n "$AWS_ACCESS_KEY_ID" ] || aws sts get-caller-identity &>/dev/null; then
  HAS_BEDROCK=true
fi

if [ "$HAS_DIRECT" = "false" ] && [ "$HAS_BEDROCK" = "false" ]; then
  echo "ERROR: Need ANTHROPIC_API_KEY for Direct and/or AWS credentials for Bedrock" >&2
  exit 1
fi

RESULTS="{}"

# --- Helper: run a Claude Code session and capture timing ---
run_session() {
  local provider="$1"
  local label="$2"
  local extra_env="$3"

  echo "--- Running: $label ---" >&2

  # Clear the hook JSONL so we only capture this session's tool calls
  rm -f /tmp/sre-latency-session.lock
  echo '{"event":"session_start","timestamp":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}' > /tmp/sre-latency-monitor.jsonl

  # Clean workspace between runs
  rm -f /tmp/sre-bench/fib.py /tmp/sre-bench/calculator.py /tmp/sre-bench/test_calculator.py \
        /tmp/sre-bench/processor.py /tmp/sre-bench/test_processor.py 2>/dev/null

  local t_start t_end
  t_start=$(ms_now)

  # Run Claude Code non-interactively with tool execution enabled
  # --dangerously-skip-permissions allows tool use (Write/Bash/etc) without prompts
  # Safe here because we're writing to /tmp/sre-bench/ only
  local output exit_code=0
  local model_flag=""
  [ -n "$SESSION_MODEL" ] && model_flag="--model $SESSION_MODEL"

  if [ "$provider" = "bedrock" ]; then
    output=$(env \
      CLAUDE_CODE_USE_BEDROCK=1 \
      AWS_REGION="$BEDROCK_REGION" \
      CLAUDE_CODE_MAX_OUTPUT_TOKENS=16384 \
      claude -p "$TASK_PROMPT" \
        $model_flag \
        --dangerously-skip-permissions \
        --max-turns 20 \
        --no-session-persistence \
        --add-dir /tmp/sre-bench 2>&1) || exit_code=$?
  else
    output=$(claude -p "$TASK_PROMPT" \
      $model_flag \
      --dangerously-skip-permissions \
      --max-turns 20 \
      --no-session-persistence \
      --add-dir /tmp/sre-bench 2>&1) || exit_code=$?
  fi

  t_end=$(ms_now)
  local total_ms=$(echo "$t_end - $t_start" | bc)

  echo "  Total session time: ${total_ms}ms (exit: $exit_code)" >&2

  # Capture the hook JSONL for this session
  local tool_stats="{}"
  if [ -f /tmp/sre-latency-monitor.jsonl ]; then
    # Copy session data
    cp /tmp/sre-latency-monitor.jsonl "/tmp/sre-bench/session-${provider}.jsonl"

    tool_stats=$(jq -sr '
      [.[] | select(.event == "tool_call" and (.duration_ms | type) == "number" and .duration_ms > 0)] |
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
                else "CLI" end),
              value: {
                calls: length,
                total_ms: ([.[].duration_ms] | add | . * 100 | round / 100),
                mean_ms: ([.[].duration_ms] | add / length | . * 100 | round / 100),
                tools: ([.[].tool_name] | unique)
              }
            }) | from_entries
          ),
          per_tool: (
            group_by(.tool_name) | map({
              key: .[0].tool_name,
              value: {
                calls: length,
                total_ms: ([.[].duration_ms] | add | . * 100 | round / 100),
                mean_ms: ([.[].duration_ms] | add / length | . * 100 | round / 100)
              }
            }) | from_entries
          )
        }
      end
    ' /tmp/sre-latency-monitor.jsonl 2>/dev/null)
  fi

  # Compute model vs tool time
  local tool_total_ms model_time_ms
  tool_total_ms=$(echo "$tool_stats" | jq '.total_tool_ms // 0')
  model_time_ms=$(echo "$total_ms - $tool_total_ms" | bc)

  # Build result
  jq -nc \
    --arg provider "$provider" \
    --arg label "$label" \
    --argjson total_ms "$total_ms" \
    --argjson model_time_ms "$model_time_ms" \
    --argjson exit_code "$exit_code" \
    --argjson tools "$tool_stats" \
    '{
      provider: $provider,
      label: $label,
      total_session_ms: $total_ms,
      model_time_ms: $model_time_ms,
      exit_code: $exit_code,
      tool_budget: $tools
    }'
}

# --- Run sessions ---
DIRECT_RESULT="{}"
BEDROCK_RESULT="{}"

if [ "$HAS_DIRECT" = "true" ]; then
  DIRECT_RESULT=$(run_session "direct" "Anthropic Direct API" "")
  echo "" >&2
  sleep 2  # brief pause between runs
fi

if [ "$HAS_BEDROCK" = "true" ]; then
  BEDROCK_RESULT=$(run_session "bedrock" "AWS Bedrock ($BEDROCK_REGION)" "")
  echo "" >&2
fi

# --- Build final report ---
REPORT=$(jq -nc \
  --arg ts "$TIMESTAMP" \
  --arg hostname "$ENV_HOSTNAME" \
  --arg os "$ENV_OS $ENV_OS_VER" \
  --arg arch "$ENV_ARCH" \
  --arg task "$TASK_LEVEL" \
  --arg task_prompt "$TASK_PROMPT" \
  --argjson direct "$DIRECT_RESULT" \
  --argjson bedrock "$BEDROCK_RESULT" \
  '{
    type: "session_benchmark",
    timestamp: $ts,
    environment: {hostname: $hostname, os: $os, arch: $arch},
    task: {level: $task, prompt: $task_prompt},
    sessions: {
      anthropic_direct: $direct,
      aws_bedrock: $bedrock
    },
    comparison: (
      if ($direct.total_session_ms // 0) > 0 and ($bedrock.total_session_ms // 0) > 0 then
      {
        total_delta_ms: (($bedrock.total_session_ms - $direct.total_session_ms) | . * 100 | round / 100),
        total_delta_pct: ((($bedrock.total_session_ms - $direct.total_session_ms) / $direct.total_session_ms * 100) | . * 10 | round / 10),
        model_delta_ms: (($bedrock.model_time_ms - $direct.model_time_ms) | . * 100 | round / 100),
        tool_delta_ms: ((($bedrock.tool_budget.total_tool_ms // 0) - ($direct.tool_budget.total_tool_ms // 0)) | . * 100 | round / 100)
      }
      else {note: "Need both providers for comparison"}
      end
    )
  }')

# --- Display summary ---
echo "$REPORT" | jq -r '
  def ms_fmt:
    if type != "number" then "—"
    elif . >= 60000 then "\(. / 60000 | . * 10 | round / 10)m"
    elif . >= 1000 then "\(. / 1000 | . * 10 | round / 10)s"
    else "\(. * 10 | round / 10)ms" end;

  "╔══════════════════════════════════════════════════════════════════╗",
  "║              CLAUDE CODE SESSION BENCHMARK                      ║",
  "╚══════════════════════════════════════════════════════════════════╝",
  "",
  "Task: \(.task.level) | Host: \(.environment.hostname) | \(.timestamp)",
  "",
  "                      Direct API        Bedrock           Delta",
  "                      ──────────        ───────           ─────",
  "Total session:        \(.sessions.anthropic_direct.total_session_ms | ms_fmt | . + "              " | .[:18])\(.sessions.aws_bedrock.total_session_ms | ms_fmt | . + "              " | .[:18])\(.comparison.total_delta_pct // "?" | tostring)%",
  "  Model time:         \(.sessions.anthropic_direct.model_time_ms | ms_fmt | . + "              " | .[:18])\(.sessions.aws_bedrock.model_time_ms | ms_fmt | . + "              " | .[:18])\(.comparison.model_delta_ms | ms_fmt)",
  "  Tool time:          \(.sessions.anthropic_direct.tool_budget.total_tool_ms // 0 | ms_fmt | . + "              " | .[:18])\(.sessions.aws_bedrock.tool_budget.total_tool_ms // 0 | ms_fmt | . + "              " | .[:18])\(.comparison.tool_delta_ms | ms_fmt)",
  "  Tool calls:         \(.sessions.anthropic_direct.tool_budget.total_calls // 0 | tostring | . + "              " | .[:18])\(.sessions.aws_bedrock.tool_budget.total_calls // 0 | tostring)",
  "",
  "TOOL BREAKDOWN (Direct)",
  ([.sessions.anthropic_direct.tool_budget.by_category // {} | to_entries[] | "  \(.key): \(.value.calls)x, \(.value.total_ms | ms_fmt), avg \(.value.mean_ms | ms_fmt)"] | join("\n")),
  "",
  "TOOL BREAKDOWN (Bedrock)",
  ([.sessions.aws_bedrock.tool_budget.by_category // {} | to_entries[] | "  \(.key): \(.value.calls)x, \(.value.total_ms | ms_fmt), avg \(.value.mean_ms | ms_fmt)"] | join("\n"))
' >&2

# Save if output specified
if [ -n "$OUTPUT_FILE" ]; then
  echo "$REPORT" | jq '.' > "$OUTPUT_FILE"
  echo "" >&2
  echo "Full report saved to $OUTPUT_FILE" >&2
fi

# Output JSON
echo "$REPORT" | jq '.'
