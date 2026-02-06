#!/bin/bash
# SRE Grade Calculator — assigns health grades (A-F) to benchmark results
# Pure jq, no Python. Reads benchmark JSON and grades against SLO thresholds.

set -eo pipefail

REPORT="${1:?Usage: grade.sh <benchmark.json> [--thresholds slos.json]}"
THRESHOLDS_FILE=""

# Parse optional --thresholds flag
shift
while [ $# -gt 0 ]; do
  case "$1" in
    --thresholds) THRESHOLDS_FILE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# Default SLO thresholds (interactive CLI usage)
DEFAULT_THRESHOLDS='{
  "ttft_p50_ms":          {"A": 500,  "B": 800,  "C": 1200, "D": 2000},
  "ttft_p99_ms":          {"A": 1500, "B": 2500, "C": 4000, "D": 6000},
  "total_p50_ms":         {"A": 3000, "B": 5000, "C": 8000, "D": 12000},
  "throughput_mean_tps":  {"A": 80,   "B": 60,   "C": 40,   "D": 20},
  "error_rate":           {"A": 0.0,  "B": 0.01, "C": 0.05, "D": 0.10}
}'

if [ -n "$THRESHOLDS_FILE" ] && [ -f "$THRESHOLDS_FILE" ]; then
  THRESHOLDS=$(cat "$THRESHOLDS_FILE")
else
  THRESHOLDS="$DEFAULT_THRESHOLDS"
fi

# Grade all providers using jq
jq -r --argjson thresholds "$THRESHOLDS" '
  # Grade a single metric value against thresholds
  def grade_metric(value; metric_thresholds; higher_is_better):
    if value == null then "—"
    elif higher_is_better then
      if value >= metric_thresholds.A then "A"
      elif value >= metric_thresholds.B then "B"
      elif value >= metric_thresholds.C then "C"
      elif value >= metric_thresholds.D then "D"
      else "F" end
    else
      if value <= metric_thresholds.A then "A"
      elif value <= metric_thresholds.B then "B"
      elif value <= metric_thresholds.C then "C"
      elif value <= metric_thresholds.D then "D"
      else "F" end
    end;

  # Map grade letters to numeric order for comparison
  def grade_order:
    if . == "A" then 0
    elif . == "B" then 1
    elif . == "C" then 2
    elif . == "D" then 3
    elif . == "F" then 4
    else -1 end;

  .summary | to_entries | map(
    .key as $provider_key |
    .value as $s |
    {
      ($provider_key): {
        provider: ($s.provider // $provider_key),
        model: ($s.model // "unknown"),
        metric_grades: {
          ttft_p50_ms:         grade_metric($s.ttft_p50_ms;         $thresholds.ttft_p50_ms;         false),
          ttft_p99_ms:         grade_metric($s.ttft_p99_ms;         $thresholds.ttft_p99_ms;         false),
          total_p50_ms:        grade_metric($s.total_p50_ms;        $thresholds.total_p50_ms;        false),
          throughput_mean_tps: grade_metric($s.throughput_mean_tps;  $thresholds.throughput_mean_tps; true),
          error_rate:          grade_metric($s.error_rate;           $thresholds.error_rate;          false)
        },
        overall_grade: (
          [
            grade_metric($s.ttft_p50_ms;         $thresholds.ttft_p50_ms;         false),
            grade_metric($s.ttft_p99_ms;         $thresholds.ttft_p99_ms;         false),
            grade_metric($s.total_p50_ms;        $thresholds.total_p50_ms;        false),
            grade_metric($s.throughput_mean_tps;  $thresholds.throughput_mean_tps; true),
            grade_metric($s.error_rate;           $thresholds.error_rate;          false)
          ] | map(select(. != "—")) |
          if length == 0 then "—"
          else sort_by(grade_order) | last
          end
        )
      }
    }
  ) | add
' "$REPORT"
