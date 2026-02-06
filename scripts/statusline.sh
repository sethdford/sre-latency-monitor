#!/bin/bash
# SRE Latency Monitor — Claude Code Status Line (v2)
# Shows where time is spent: Model vs Bash vs MCP vs CLI tools
# Pure bash/jq/awk — no Python, <20ms execution

INPUT=$(cat)

# Single jq call — use @sh for shell-safe quoting
eval "$(echo "$INPUT" | jq -r '
  "MODEL=" + (.model.display_name // "?" | @sh),
  "MODEL_ID=" + (.model.id // "" | @sh),
  "CTX=" + (.context_window.used_percentage // 0 | floor | tostring),
  "COST=" + (.cost.total_cost_usd // 0 | tostring),
  "DUR=" + (.cost.total_duration_ms // 0 | tostring)
' 2>/dev/null)"

# Provider detection
case "$MODEL_ID" in
  *bedrock*|us.*|eu.*|ap.*|global.*) PROV="BR" ;;
  *vertex*) PROV="VX" ;;
  *) PROV="D" ;;
esac

# Duration formatting helper
fmt_dur() {
  local s=$1
  if [ "$s" -ge 3600 ] 2>/dev/null; then
    printf "%dh%dm" $((s/3600)) $((s%3600/60))
  elif [ "$s" -ge 60 ] 2>/dev/null; then
    printf "%dm%ds" $((s/60)) $((s%60))
  else
    printf "%ds" "$s"
  fi
}

# Total session duration
DUR_S=$((${DUR%.*} / 1000))
T=$(fmt_dur $DUR_S)

# Categorized tool time breakdown from hook JSONL
# Categories: Bash, MCP (mcp__*), Task, CLI (all other built-in tools)
BREAKDOWN=""
LOG="/tmp/sre-latency-monitor.jsonl"
if [ -f "$LOG" ]; then
  # Use jq -s to slurp JSONL, categorize, and sum by category
  BREAKDOWN=$(jq -sr '
    def fmt: . as $s |
      if $s >= 3600 then "\($s/3600|floor)h\($s%3600/60|floor)m"
      elif $s >= 60 then "\($s/60|floor)m\($s%60)s"
      else "\($s)s" end;

    [.[] | select(.event == "tool_call" and .duration_ms != null and .duration_ms > 0)] |
    if length == 0 then ""
    else
      # Categorize each tool call
      map({
        cat: (
          if (.tool_name // "" | startswith("mcp__")) then "MCP"
          elif .tool_name == "Bash" then "Bash"
          elif .tool_name == "Task" then "Task"
          else "CLI" end
        ),
        ms: .duration_ms
      }) |
      # Sum by category
      reduce .[] as $x ({}; .[$x.cat] = ((.[$x.cat] // 0) + $x.ms)) |
      # Also compute total tool time
      to_entries |
      (map(.value) | add) as $tool_total |
      sort_by(-.value) |
      # Format each category
      [.[] | select(.value >= 1000) | "\(.key):\(.value / 1000 | floor | fmt)"] |
      # Add total tool time
      if length > 0 then
        ($tool_total / 1000 | floor | fmt) as $tt |
        " | " + join(" ") + " [" + $tt + " tools]"
      else "" end
    end
  ' "$LOG" 2>/dev/null)
fi

# TTFT from last benchmark/latency-check
TTFT_PART=""
TTFT_FILE="/tmp/sre-latency-ttft.json"
if [ -f "$TTFT_FILE" ]; then
  TTFT_VAL=$(jq -r '.ttft_ms // empty' "$TTFT_FILE" 2>/dev/null)
  if [ -n "$TTFT_VAL" ]; then
    TTFT_PART=" | TTFT ${TTFT_VAL}ms"
  fi
fi

# Cost formatting
COST_FMT=$(printf "%.2f" "$COST" 2>/dev/null || echo "0.00")

printf "[%s] %s | Ctx %s%% | $%s | %s%s%s\n" \
  "$PROV" "$MODEL" "$CTX" "$COST_FMT" "$T" "$BREAKDOWN" "$TTFT_PART"
