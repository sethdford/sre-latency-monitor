#!/bin/bash
# SRE Latency Monitor — Session Timeline Analyzer
# Reads enhanced JSONL (pre_tool + tool_call with ts_ms) to compute:
#   - Model vs tool time split
#   - Inference gaps (time between tool_done and next pre_tool)
#   - Slowest gaps + slowest tools
#   - Per-category breakdown
#   - User wait detection (AskUserQuestion)
# Pure jq — no Python. Designed for real session data, not synthetic benchmarks.

set -euo pipefail

LOG="${1:-/tmp/sre-latency-monitor.jsonl}"

if [ ! -f "$LOG" ]; then
  echo "No session data found at $LOG"
  echo "Start a Claude Code session with the SRE Latency Monitor plugin active."
  exit 1
fi

# Check if we have ts_ms data (enhanced hooks)
HAS_TS_MS=$(jq -sr '[.[] | select(.ts_ms != null)] | length > 0' "$LOG" 2>/dev/null)

if [ "$HAS_TS_MS" != "true" ]; then
  echo "No ts_ms data found — hooks need the enhanced PreToolUse logging."
  echo "Falling back to duration-only analysis."
  echo ""
fi

# Main analysis — single jq invocation
jq -sr '
def fmt_ms:
  . as $ms |
  if $ms >= 3600000 then "\($ms/3600000|floor)h\($ms%3600000/60000|floor)m"
  elif $ms >= 60000 then "\($ms/60000|floor)m\($ms%60000/1000|floor)s"
  elif $ms >= 1000 then "\($ms/1000 * 10 | floor / 10)s"
  else "\($ms)ms" end;

def fmt_pct: . * 100 | floor | tostring + "%";

def pad($n): tostring | if length < $n then . + (" " * ($n - length)) else . end;

def rpad($n): tostring | if length < $n then (" " * ($n - length)) + . else . end;

def categorize:
  if (.tool_name // "" | startswith("mcp__")) then "MCP"
  elif .tool_name == "Bash" then "Bash"
  elif .tool_name == "Task" then "Task"
  elif .tool_name == "AskUserQuestion" then "User"
  else "CLI" end;

# Separate events
(map(select(.event == "session_start")) | first // null) as $session |
[.[] | select(.event == "pre_tool")] as $pre_tools |
[.[] | select(.event == "tool_call")] as $tool_calls |

# Total tool time
($tool_calls | map(.duration_ms // 0) | add // 0) as $total_tool_ms |

# Session span from timestamps (use latest event across all types)
(if ($session.ts_ms // null) != null then
  ([.[] | select(.ts_ms > 0) | .ts_ms] | max // 0) - $session.ts_ms |
  if . > 0 then . else null end
else null end) as $session_span_ms |

# Compute inference gaps: time between each tool_call and the next pre_tool
# Sort all events by ts_ms, then find gaps between tool_call -> pre_tool
(if ($pre_tools | length) > 0 and ($tool_calls | length) > 0 then
  # Merge and sort all events with ts_ms
  [(.[] | select(.ts_ms != null and .ts_ms > 0))] | sort_by(.ts_ms) |

  # Walk pairs: when tool_call is followed by pre_tool, the gap is inference time
  # Also: session_start followed by pre_tool is first inference
  . as $sorted |
  [range(0; ($sorted | length) - 1) |
    . as $i |
    $sorted[$i] as $cur | $sorted[$i + 1] as $nxt |
    if (($cur.event == "tool_call" or $cur.event == "session_start") and $nxt.event == "pre_tool") then
      {
        gap_ms: ($nxt.ts_ms - $cur.ts_ms),
        after_tool: ($cur.tool_name // "session_start"),
        before_tool: $nxt.tool_name,
        after_id: ($cur.tool_use_id // "session"),
        ts_ms: $cur.ts_ms
      }
    else empty end
  ] |
  # Filter out negative/zero gaps (clock skew) and user wait time
  [.[] | select(.gap_ms > 0)]
else [] end) as $gaps |

# Separate user-wait gaps from model inference gaps
# User wait = only the gap AFTER AskUserQuestion completes (user thinking)
# Gap BEFORE AskUserQuestion = model composing the question = inference
([$gaps[] | select(.after_tool == "AskUserQuestion")] | map(.gap_ms) | add // 0) as $user_wait_ms |
([$gaps[] | select(.after_tool != "AskUserQuestion")]) as $inference_gaps |
($inference_gaps | map(.gap_ms) | add // 0) as $model_ms |

# ─── HEADER ───
"╔═══════════════════════════════════════════════════════════════╗",
"║              Session Timeline Analysis                       ║",
"╚═══════════════════════════════════════════════════════════════╝",
"",

# ─── MODEL vs TOOL SPLIT ───
if $session_span_ms != null and $session_span_ms > 0 then
  ($session_span_ms - $total_tool_ms) as $non_tool_ms |
  "  Model vs Tool Time Split",
  "  ─────────────────────────────────────────────────",
  (if ($gaps | length) > 0 then
    "  Model inference:  \($model_ms | fmt_ms | pad(10))  \(($model_ms / $session_span_ms) | fmt_pct)",
    "  Tool execution:   \($total_tool_ms | fmt_ms | pad(10))  \(($total_tool_ms / $session_span_ms) | fmt_pct)",
    (if $user_wait_ms > 0 then
      "  User wait:        \($user_wait_ms | fmt_ms | pad(10))  \(($user_wait_ms / $session_span_ms) | fmt_pct)"
    else empty end),
    "  Unaccounted:      \(([$non_tool_ms - $model_ms - $user_wait_ms, 0] | max) | fmt_ms | pad(10))  \(([($non_tool_ms - $model_ms - $user_wait_ms) / $session_span_ms, 0] | max) | fmt_pct)",
    "  ─────────────────────────────────────────────────",
    "  Session total:    \($session_span_ms | fmt_ms)"
  else
    "  Tool execution:   \($total_tool_ms | fmt_ms | pad(10))  \(($total_tool_ms / $session_span_ms) | fmt_pct)",
    "  Model+idle:       \($non_tool_ms | fmt_ms | pad(10))  \(($non_tool_ms / $session_span_ms) | fmt_pct)",
    "  ─────────────────────────────────────────────────",
    "  Session span:     \($session_span_ms | fmt_ms)",
    "  (Enable PreToolUse ts_ms logging for precise model vs idle breakdown)"
  end)
else
  "  Tool time total:  \($total_tool_ms | fmt_ms)",
  "  (No ts_ms data — cannot compute model/tool split)"
end,
"",

# ─── INFERENCE GAPS (top 5) ───
if ($inference_gaps | length) > 0 then
  "  Top Inference Gaps (model thinking time)",
  "  ─────────────────────────────────────────────────",
  "  \("Duration" | pad(12))  After → Before",
  ($inference_gaps | sort_by(-.gap_ms) | .[:5] | .[] |
    "  \(.gap_ms | fmt_ms | pad(12))  \(.after_tool) → \(.before_tool)"
  ),
  (if ($inference_gaps | length) > 5 then
    "  ... and \($inference_gaps | length - 5) more gaps"
  else empty end),
  ""
else empty end,

# ─── SLOWEST TOOLS (top 5) ───
if ($tool_calls | length) > 0 then
  "  Slowest Tool Calls",
  "  ─────────────────────────────────────────────────",
  "  \("Duration" | pad(12))  Tool",
  ($tool_calls | sort_by(-.duration_ms) | .[:5] | .[] |
    "  \(.duration_ms | fmt_ms | pad(12))  \(.tool_name)"
  ),
  ""
else empty end,

# ─── PER-CATEGORY BREAKDOWN ───
if ($tool_calls | length) > 0 then
  "  Category Breakdown",
  "  ─────────────────────────────────────────────────",
  "  \("Category" | pad(10))  \("Calls" | rpad(6))  \("Total" | pad(10))  \("Avg" | pad(10))  \("P90" | pad(10))",
  (
    $tool_calls | group_by(categorize) |
    map({
      cat: (.[0] | categorize),
      count: length,
      total: (map(.duration_ms // 0) | add),
      avg: ((map(.duration_ms // 0) | add) / length),
      p90: (sort_by(.duration_ms) | .[length * 9 / 10 | floor].duration_ms // 0)
    }) | sort_by(-.total) | .[] |
    "  \(.cat | pad(10))  \(.count | tostring | rpad(6))  \(.total | fmt_ms | pad(10))  \(.avg | floor | fmt_ms | pad(10))  \(.p90 | fmt_ms | pad(10))"
  ),
  ""
else
  "  No tool calls recorded yet.",
  ""
end,

# ─── MCP BREAKDOWN ───
([$tool_calls[] | select(.tool_name | startswith("mcp__"))]) as $mcp_calls |
if ($mcp_calls | length) > 0 then
  "  MCP Server Breakdown",
  "  ─────────────────────────────────────────────────",
  "  \("Server" | pad(24))  \("Calls" | rpad(6))  \("Total" | pad(10))  \("Avg" | pad(10))",
  (
    $mcp_calls |
    map(. + {server: (.tool_name | split("__") | .[1] // "unknown")}) |
    group_by(.server) |
    map({
      server: .[0].server,
      count: length,
      total: (map(.duration_ms // 0) | add),
      avg: ((map(.duration_ms // 0) | add) / length)
    }) | sort_by(-.total) | .[] |
    "  \(.server | pad(24))  \(.count | tostring | rpad(6))  \(.total | fmt_ms | pad(10))  \(.avg | floor | fmt_ms | pad(10))"
  ),
  ""
else empty end,

# ─── SUMMARY STATS ───
"  Summary",
"  ─────────────────────────────────────────────────",
"  Total tool calls:    \($tool_calls | length)",
"  Unique tools used:   \([$tool_calls[].tool_name] | unique | length)",
(if ($gaps | length) > 0 then
  "  Inference gaps:     \($gaps | length)",
  "  Avg inference gap:  \(($inference_gaps | map(.gap_ms) | add // 0) / ([($inference_gaps | length), 1] | max) | floor | fmt_ms)"
else empty end),
""

' "$LOG"
