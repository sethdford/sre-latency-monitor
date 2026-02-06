#!/bin/bash
# SRE Report Generator — reads benchmark JSON and produces formatted comparison
# Pure jq, no Python.

set -eo pipefail

INPUT="${1:?Usage: report.sh <benchmark.json|directory> [--trend] [--json]}"
TREND=false
JSON_OUT=false

shift
while [ $# -gt 0 ]; do
  case "$1" in
    --trend) TREND=true; shift ;;
    --json) JSON_OUT=true; shift ;;
    *) shift ;;
  esac
done

# If directory, concatenate all JSON files into an array
if [ -d "$INPUT" ]; then
  REPORTS=$(find "$INPUT" -name '*.json' -type f | sort | while read -r f; do cat "$f"; done | jq -s '.')
  REPORT_COUNT=$(echo "$REPORTS" | jq 'length')
  if [ "$REPORT_COUNT" = "0" ]; then
    echo "No report files found in $INPUT" >&2
    exit 1
  fi
else
  REPORTS=$(jq -s '.' "$INPUT")
fi

if [ "$JSON_OUT" = "true" ]; then
  echo "$REPORTS" | jq '[ .[] | .summary ]'
  exit 0
fi

# Format each report
echo "$REPORTS" | jq -r '
  .[] |
  .timestamp as $ts |
  .config as $cfg |
  .summary as $sum |

  "## Benchmark — \($ts)",
  "Iterations: \($cfg.iterations) | Prompt: \($cfg.prompt_size) | Max tokens: \($cfg.max_tokens)",
  "",

  # Build table
  ($sum | keys) as $providers |
  (
    # Header
    ([("Metric" | . + (" " * (30 - length)))] +
     [$providers[] | . as $p | $sum[$p].provider // $p | . as $label |
      (22 - ($label | length)) as $pad | (" " * (if $pad > 0 then $pad else 0 end)) + $label]
    | " | " + join(" | ")),

    # Separator
    ("-" * 80),

    # Rows
    (
      [
        ["Model",              "model",              "str"],
        ["Samples",            "samples",            "int"],
        ["TTFT P50 (ms)",      "ttft_p50_ms",        "ms"],
        ["TTFT P90 (ms)",      "ttft_p90_ms",        "ms"],
        ["TTFT P95 (ms)",      "ttft_p95_ms",        "ms"],
        ["TTFT P99 (ms)",      "ttft_p99_ms",        "ms"],
        ["TTFT Mean (ms)",     "ttft_mean_ms",        "ms"],
        ["Total P50 (ms)",     "total_p50_ms",        "ms"],
        ["Total P90 (ms)",     "total_p90_ms",        "ms"],
        ["Total P95 (ms)",     "total_p95_ms",        "ms"],
        ["Total P99 (ms)",     "total_p99_ms",        "ms"],
        ["Total Mean (ms)",    "total_mean_ms",       "ms"],
        ["Throughput P50",     "throughput_p50_tps",   "tps"],
        ["Throughput Mean",    "throughput_mean_tps",  "tps"],
        ["Error Rate",         "error_rate",           "pct"]
      ][] |
      . as [$label, $key, $fmt] |
      ([($label + (" " * (30 - ($label | length))))] +
       [$providers[] | . as $p | $sum[$p][$key] as $val |
        (if $val == null then "—"
         elif $fmt == "pct" then "\($val * 100 | . * 10 | round / 10)%"
         elif $fmt == "ms" or $fmt == "tps" then
           (if ($val | type) == "number" then ($val * 100 | round / 100 | tostring) else ($val | tostring) end)
         else ($val | tostring)
         end) as $cell |
        (22 - ($cell | length)) as $pad | (" " * (if $pad > 0 then $pad else 0 end)) + $cell
       ]
      | " | " + join(" | "))
    ),

    # Delta analysis
    (if ($providers | length) == 2 then
      "",
      "### Delta Analysis (\($sum[$providers[0]].provider) vs \($sum[$providers[1]].provider))",
      (
        [
          ["TTFT P50",     "ttft_p50_ms",        "latency"],
          ["TTFT P99",     "ttft_p99_ms",        "latency"],
          ["Total P50",    "total_p50_ms",       "latency"],
          ["Total P99",    "total_p99_ms",       "latency"],
          ["Throughput",   "throughput_mean_tps", "throughput"],
          ["Error Rate",   "error_rate",          "latency"]
        ][] |
        . as [$label, $key, $type] |
        $sum[$providers[0]][$key] as $a |
        $sum[$providers[1]][$key] as $b |
        if ($a | type) == "number" and ($b | type) == "number" and $a != 0 then
          (($b - $a) / $a * 100) as $delta |
          (if $type == "throughput" then
            (if $delta > 0 then "faster" else "slower" end)
          else
            (if $delta > 0 then "slower" else "faster" end)
          end) as $dir |
          "  \($label): \($delta | fabs | . * 10 | round / 10)% \($dir) (\($providers[1]) vs \($providers[0]))"
        else empty
        end
      )
    else empty end),
    ""
  )
'

# Trend analysis
if [ "$TREND" = "true" ]; then
  REPORT_COUNT=$(echo "$REPORTS" | jq 'length')
  if [ "$REPORT_COUNT" -lt 2 ]; then
    echo "Need at least 2 reports for trend analysis."
  else
    echo "## Trend Summary"
    echo ""
    for PROVIDER in "anthropic-direct" "aws-bedrock"; do
      echo "### $PROVIDER"
      echo "$REPORTS" | jq -r --arg p "$PROVIDER" '
        [.[] | .summary[$p] | select(. != null)] |
        if length == 0 then "  No data available."
        else
          "  TTFT Mean trend:      " + ([.[] | .ttft_mean_ms | tostring + "ms"] | join(" -> ")),
          "  Total Mean trend:     " + ([.[] | .total_mean_ms | tostring + "ms"] | join(" -> ")),
          "  Throughput Mean trend: " + ([.[] | .throughput_mean_tps | tostring + "t/s"] | join(" -> "))
        end
      '
      echo ""
    done
  fi
fi
