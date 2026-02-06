#!/bin/bash
# SRE Grade Calculator — assigns health grades (A-F) to benchmark results
# Pure jq, no Python. Reads benchmark JSON and grades against SLO thresholds.
# Supports both benchmark.sh (.summary) and latency_budget.sh (.providers) schemas.

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
# Auto-detects schema: .summary (benchmark.sh) or .providers (latency_budget.sh)
jq -r --argjson thresholds "$THRESHOLDS" '
  # Normalize: convert any schema to .summary format
  # Supports: benchmark.sh (.summary), latency_budget.sh (.providers), session_benchmark.sh (.sessions)
  def normalize:
    if .summary then .summary
    elif .providers then
      .providers | to_entries | map({
        key: .key,
        value: {
          provider: .key,
          model: (.value.model // "unknown"),
          samples: (.value.samples // 0),
          ttft_p50_ms:         (.value.ttft_ms.p50 // null),
          ttft_p90_ms:         (.value.ttft_ms.p90 // null),
          ttft_p99_ms:         (.value.ttft_ms.p99 // null),
          ttft_mean_ms:        (.value.ttft_ms.mean // null),
          total_p50_ms:        (.value.total_ms.p50 // null),
          total_p90_ms:        (.value.total_ms.p90 // null),
          total_p99_ms:        (.value.total_ms.p99 // null),
          total_mean_ms:       (.value.total_ms.mean // null),
          throughput_mean_tps: (.value.tps_mean // null),
          error_rate:          (.value.error_rate // 0)
        }
      }) | from_entries
    elif .sessions then
      .sessions | to_entries | map({
        key: .key,
        value: {
          provider: .value.label,
          model: "auto",
          samples: 1,
          total_mean_ms:       .value.total_session_ms,
          total_p50_ms:        .value.total_session_ms,
          throughput_mean_tps: null,
          error_rate:          (if .value.exit_code == 0 then 0 else 1 end)
        }
      }) | from_entries
    else error("Unknown schema: expected .summary, .providers, or .sessions")
    end;

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

  normalize | to_entries | map(
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
