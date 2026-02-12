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

# Total session duration (guard against empty/zero DUR)
DUR_RAW=${DUR%.*}
DUR_S=$(( ${DUR_RAW:-0} / 1000 ))
T=$(fmt_dur $DUR_S)

# Tool time breakdown from hook JSONL
# Prefers precise Model/Tool split (ts_ms) over category breakdown (fallback)
BREAKDOWN=""
LOG="/tmp/sre-latency-monitor.jsonl"
if [ -f "$LOG" ]; then
  # Try precise model/tool split using ts_ms gap data
  BREAKDOWN=$(jq -sr '
    def fmt: . as $s |
      if $s >= 3600 then "\($s/3600|floor)h\($s%3600/60|floor)m"
      elif $s >= 60 then "\($s/60|floor)m\($s%60)s"
      else "\($s)s" end;

    [.[] | select(.event == "tool_call" and .duration_ms != null)] as $tools |
    ($tools | map(.duration_ms // 0) | add // 0) as $tool_total_ms |
    [.[] | select(.ts_ms != null and .ts_ms > 0)] | sort_by(.ts_ms) |
    if length < 2 then null
    else
      . as $sorted |
      [range(0; ($sorted | length) - 1) |
        . as $i | $sorted[$i] as $cur | $sorted[$i+1] as $nxt |
        if (($cur.event == "tool_call" or $cur.event == "session_start") and $nxt.event == "pre_tool" and ($cur.tool_name // "") != "AskUserQuestion") then
          ($nxt.ts_ms - $cur.ts_ms)
        else 0 end
      ] | map(select(. > 0)) | add // 0 |
      . as $model_ms |
      if $model_ms > 0 and $tool_total_ms > 0 then
        ($model_ms / 1000 | floor | fmt) as $mt |
        ($tool_total_ms / 1000 | floor | fmt) as $tt |
        ($model_ms + $tool_total_ms) as $accounted |
        (($model_ms * 100 / $accounted) | floor | tostring) as $mpct |
        (($tool_total_ms * 100 / $accounted) | floor | tostring) as $tpct |
        " | Model:" + $mt + " Tools:" + $tt + " [" + $mpct + "/" + $tpct + "%]"
      else null end
    end
  ' "$LOG" 2>/dev/null)

  # Fallback: category breakdown (no ts_ms data available)
  if [ -z "$BREAKDOWN" ] || [ "$BREAKDOWN" = "null" ]; then
    BREAKDOWN=$(jq -sr '
      def fmt: . as $s |
        if $s >= 3600 then "\($s/3600|floor)h\($s%3600/60|floor)m"
        elif $s >= 60 then "\($s/60|floor)m\($s%60)s"
        else "\($s)s" end;

      [.[] | select(.event == "tool_call" and .duration_ms != null and .duration_ms > 0)] |
      if length == 0 then ""
      else
        map({
          cat: (
            if (.tool_name // "" | startswith("mcp__")) then "MCP"
            elif .tool_name == "Bash" then "Bash"
            elif .tool_name == "Task" then "Task"
            else "CLI" end
          ),
          ms: .duration_ms
        }) |
        reduce .[] as $x ({}; .[$x.cat] = ((.[$x.cat] // 0) + $x.ms)) |
        to_entries |
        (map(.value) | add) as $tool_total |
        sort_by(-.value) |
        [.[] | select(.value >= 1000) | "\(.key):\(.value / 1000 | floor | fmt)"] |
        if length > 0 then
          ($tool_total / 1000 | floor | fmt) as $tt |
          " | " + join(" ") + " [" + $tt + " tools]"
        else "" end
      end
    ' "$LOG" 2>/dev/null)
  fi
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
