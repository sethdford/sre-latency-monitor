#!/bin/bash
# ============================================================================
# SRE Latency Budget Comparison
# ============================================================================
# Compares multiple latency budget results side by side.
#
# Usage:
#   compare.sh <file1.json> <file2.json> [file3.json ...]
#   compare.sh <results-directory> [--latest N]

set -eo pipefail

FILES=()
LATEST=0

while [ $# -gt 0 ]; do
  case "$1" in
    --latest|-l) LATEST="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: compare.sh <file1.json> [file2.json ...] | <directory> [--latest N]"
      exit 0
      ;;
    *) FILES+=("$1"); shift ;;
  esac
done

if [ ${#FILES[@]} -eq 0 ]; then
  echo "Usage: compare.sh <file1.json> [file2.json ...] | <directory> [--latest N]" >&2
  exit 1
fi

# If single arg is a directory, collect JSON files
if [ ${#FILES[@]} -eq 1 ] && [ -d "${FILES[0]}" ]; then
  DIR="${FILES[0]}"
  FILES=()
  while IFS= read -r f; do
    FILES+=("$f")
  done < <(find "$DIR" -name '*.json' -type f | sort)

  if [ ${#FILES[@]} -eq 0 ]; then
    echo "No JSON files found in $DIR" >&2
    exit 1
  fi

  if [ "$LATEST" -gt 0 ] && [ ${#FILES[@]} -gt "$LATEST" ]; then
    START=$(( ${#FILES[@]} - LATEST ))
    FILES=("${FILES[@]:$START}")
  fi
fi

# Slurp all files into a JSON array
REPORTS=$(for f in "${FILES[@]}"; do cat "$f"; done | jq -s '.')

# Generate the comparison report
echo "$REPORTS" | jq -r '
  # ── helpers ──
  def pad(n): tostring | (. + ("                    " | .[:([n - length, 0] | max)])) | .[:n];
  def rpad(n): tostring | (("                    " | .[:([n - length, 0] | max)]) + .) | .[-n:];
  def ms_fmt:
    if type != "number" then "—"
    elif . >= 10000 then "\(. / 1000 | . * 10 | round / 10)s"
    else "\(. * 10 | round / 10)ms" end;
  def tps_fmt: if type != "number" then "—" else "\(. * 10 | round / 10) t/s" end;
  def pct_fmt: if type != "number" then "—" else "\(. * 10 | round / 10)%" end;
  def col_w: 18;

  . as $all |

  # ── Header ──
  "╔══════════════════════════════════════════════════════════════════════════════╗",
  "║                      SRE LATENCY BUDGET COMPARISON                         ║",
  "╚══════════════════════════════════════════════════════════════════════════════╝",
  "",

  # ── Environments ──
  "ENVIRONMENTS",
  "───────────────────────────────────────────────────────",
  ($all[] | "  [\(.environment.hostname // "?")] \(.environment.os // "?") (\(.environment.arch // "?")) — \(.environment.client_region // "?")"),
  ($all[] | "    \(.timestamp) | \(.config.direct_model // "?") | \(.config.iterations) iter + \(.config.warmup_discarded) warmup"),
  "",

  # ── Direct API comparison ──
  (
    [$all[] | select(.providers.anthropic_direct.error_rate != null and .providers.anthropic_direct.error_rate < 1)] as $runs |
    if ($runs | length) == 0 then "DIRECT API: No successful data\n"
    else
      "DIRECT API (Anthropic)",
      "───────────────────────────────────────────────────────",
      # Column headers
      (["Metric" | pad(20)] + [$runs[] | (.environment.hostname // .timestamp[:16]) | pad(col_w)] | join(" │ ")),
      ("─" * 20 + ($runs | [range(length)] | map(" ┼ " + ("─" * col_w)) | join(""))),
      # Data rows
      (
        {
          "TTFB mean":     [$runs[].providers.anthropic_direct.ttfb_ms.mean],
          "TTFB P90":      [$runs[].providers.anthropic_direct.ttfb_ms.p90],
          "TTFT mean":     [$runs[].providers.anthropic_direct.ttft_ms.mean],
          "TTFT P90":      [$runs[].providers.anthropic_direct.ttft_ms.p90],
          "Generation":    [$runs[].providers.anthropic_direct.generation_ms.mean],
          "Total mean":    [$runs[].providers.anthropic_direct.total_ms.mean],
          "Total P90":     [$runs[].providers.anthropic_direct.total_ms.p90],
          "Total P99":     [$runs[].providers.anthropic_direct.total_ms.p99],
          "Throughput":    [$runs[].providers.anthropic_direct.tps_mean],
          "Output tokens": [$runs[].providers.anthropic_direct.output_tokens_mean],
          "Error rate":    [$runs[].providers.anthropic_direct.error_rate]
        } | to_entries[] |
        .key as $label | .value as $vals |
        ([$label | pad(20)] +
         [$vals[] |
          (if $label == "Throughput" then tps_fmt
           elif $label == "Error rate" then pct_fmt
           elif $label == "Output tokens" then (if type != "number" then "—" else "\(.)" end)
           else ms_fmt end) | rpad(col_w)
         ]) | join(" │ ")
      ),
      ""
    end
  ),

  # ── Bedrock comparison ──
  (
    [$all[] | select(.providers.aws_bedrock.error_rate != null and .providers.aws_bedrock.error_rate < 1)] as $runs |
    if ($runs | length) == 0 then "BEDROCK: No successful data\n"
    else
      "BEDROCK (AWS)",
      "───────────────────────────────────────────────────────",
      (["Metric" | pad(20)] + [$runs[] | (.environment.hostname // .timestamp[:16]) | pad(col_w)] | join(" │ ")),
      ("─" * 20 + ($runs | [range(length)] | map(" ┼ " + ("─" * col_w)) | join(""))),
      (
        {
          "Server latency":  [$runs[].providers.aws_bedrock.server_latency_ms.mean],
          "Network overhead": [$runs[].providers.aws_bedrock.network_overhead_ms.mean],
          "Total mean":       [$runs[].providers.aws_bedrock.total_ms.mean],
          "Total P90":        [$runs[].providers.aws_bedrock.total_ms.p90],
          "Throughput":       [$runs[].providers.aws_bedrock.tps_mean],
          "Error rate":       [$runs[].providers.aws_bedrock.error_rate]
        } | to_entries[] |
        .key as $label | .value as $vals |
        ([$label | pad(20)] +
         [$vals[] |
          (if $label == "Throughput" then tps_fmt
           elif $label == "Error rate" then pct_fmt
           else ms_fmt end) | rpad(col_w)
         ]) | join(" │ ")
      ),
      ""
    end
  ),

  # ── Bedrock overhead delta ──
  (
    [$all[] | select(
      (.providers.anthropic_direct.error_rate // 1) < 1 and
      (.providers.aws_bedrock.error_rate // 1) < 1
    )] as $runs |
    if ($runs | length) == 0 then "BEDROCK OVERHEAD: Need both Direct + Bedrock data in at least one run\n"
    else
      "BEDROCK OVERHEAD (vs Direct)",
      "───────────────────────────────────────────────────────",
      ($runs[] |
        .environment.hostname as $h |
        .providers.anthropic_direct.total_ms.mean as $d |
        .providers.aws_bedrock.total_ms.mean as $b |
        (if $d > 0 then (($b - $d) / $d * 100 | . * 10 | round / 10) else null end) as $pct |
        "  [\($h)] Direct: \($d | ms_fmt) → Bedrock: \($b | ms_fmt)  Δ +\($b - $d | . * 10 | round / 10)ms (\($pct // "?")%)"
      ),
      ""
    end
  ),

  # ── Session tool budgets ──
  (
    [$all[] | select((.session_tool_budget.total_calls // 0) > 0)] as $runs |
    if ($runs | length) == 0 then "SESSION TOOLS: No tool timing data"
    else
      "SESSION TOOL BUDGETS",
      "───────────────────────────────────────────────────────",
      ($runs[] |
        "  [\(.environment.hostname // "?")] \(.session_tool_budget.total_calls) calls, \(.session_tool_budget.total_tool_ms / 1000 | . * 10 | round / 10)s total" +
        (if .session_tool_budget.by_category then
          " — " + ([.session_tool_budget.by_category | to_entries[] |
            "\(.key):\(.value.calls)x/\(.value.total_ms / 1000 | . * 10 | round / 10)s"] | join(", "))
        else "" end)
      )
    end
  )
'
