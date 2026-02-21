#!/bin/bash
# ============================================================================
# SRE Dashboard Report Generator
# ============================================================================
#
# Generates an interactive HTML dashboard from Todo E2E test results.
#
# Usage:
#   generate_dashboard.sh /tmp/sre-todo-e2e-full.json [--traces-dir /tmp/sre-todo-e2e-XXXXX]
#   generate_dashboard.sh --help
#
# The traces-dir should contain <provider>_<iter>.jsonl files from the test run.

set -eo pipefail

REPORT_FILE="${1:-/tmp/sre-todo-e2e-full.json}"
TRACES_DIR=""
OUTPUT_FILE=""

shift 2>/dev/null || true
while [ $# -gt 0 ]; do
  case "$1" in
    --traces-dir|-t)  TRACES_DIR="$2"; shift 2 ;;
    --output|-o)      OUTPUT_FILE="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: generate_dashboard.sh <report.json> [options]"
      echo ""
      echo "Options:"
      echo "  --traces-dir DIR   Directory with per-run .jsonl trace files"
      echo "  --output FILE      Output HTML file (default: /tmp/sre-dashboard.html)"
      exit 0
      ;;
    *) shift ;;
  esac
done

if [ ! -f "$REPORT_FILE" ]; then
  echo "ERROR: Report file not found: $REPORT_FILE" >&2
  exit 1
fi

[ -z "$OUTPUT_FILE" ] && OUTPUT_FILE="/tmp/sre-dashboard.html"

# --- Extract data from report ---
TIMESTAMP=$(jq -r '.timestamp' "$REPORT_FILE")
HOSTNAME=$(jq -r '.environment.hostname' "$REPORT_FILE")
OS=$(jq -r '.environment.os' "$REPORT_FILE")
ARCH=$(jq -r '.environment.arch' "$REPORT_FILE")
NODE=$(jq -r '.environment.node' "$REPORT_FILE")
AWS_CLI=$(jq -r '.environment.aws_cli // "N/A"' "$REPORT_FILE")
REGION=$(jq -r '.config.region' "$REPORT_FILE")
GUARDRAIL_ID=$(jq -r '.config.guardrail_id' "$REPORT_FILE")
ITERATIONS=$(jq -r '.config.iterations' "$REPORT_FILE")

# Provider results
D_SESSION=$(jq '.results.direct.session_total_ms.mean // null' "$REPORT_FILE")
B_SESSION=$(jq '.results.bedrock.session_total_ms.mean // null' "$REPORT_FILE")
G_SESSION=$(jq '.results.guardrail.session_total_ms.mean // null' "$REPORT_FILE")

D_API=$(jq '.results.direct.api_total_ms.mean // null' "$REPORT_FILE")
B_API=$(jq '.results.bedrock.api_total_ms.mean // null' "$REPORT_FILE")
G_API=$(jq '.results.guardrail.api_total_ms.mean // null' "$REPORT_FILE")

D_TTFB=$(jq '.results.direct.streaming.ttfb_mean_ms // null' "$REPORT_FILE")
B_TTFB=$(jq '.results.bedrock.streaming.ttfb_mean_ms // null' "$REPORT_FILE")
G_TTFB=$(jq '.results.guardrail.streaming.ttfb_mean_ms // null' "$REPORT_FILE")

D_TTFT=$(jq '.results.direct.streaming.ttft_mean_ms // null' "$REPORT_FILE")
B_TTFT=$(jq '.results.bedrock.streaming.ttft_mean_ms // null' "$REPORT_FILE")
G_TTFT=$(jq '.results.guardrail.streaming.ttft_mean_ms // null' "$REPORT_FILE")

D_CHUNKS=$(jq '.results.direct.streaming.chunks_mean // null' "$REPORT_FILE")
B_CHUNKS=$(jq '.results.bedrock.streaming.chunks_mean // null' "$REPORT_FILE")
G_CHUNKS=$(jq '.results.guardrail.streaming.chunks_mean // null' "$REPORT_FILE")

D_HTTP=$(jq '.results.direct.http_calls_mean // null' "$REPORT_FILE")
B_HTTP=$(jq '.results.bedrock.http_calls_mean // null' "$REPORT_FILE")
G_HTTP=$(jq '.results.guardrail.http_calls_mean // null' "$REPORT_FILE")

D_TODO=$(jq '.results.direct.todo_app_size_avg // 0' "$REPORT_FILE")
B_TODO=$(jq '.results.bedrock.todo_app_size_avg // 0' "$REPORT_FILE")
G_TODO=$(jq '.results.guardrail.todo_app_size_avg // 0' "$REPORT_FILE")

D_CREATED=$(jq '.results.direct.todo_apps_created // 0' "$REPORT_FILE")
B_CREATED=$(jq '.results.bedrock.todo_apps_created // 0' "$REPORT_FILE")
G_CREATED=$(jq '.results.guardrail.todo_apps_created // 0' "$REPORT_FILE")

# Deltas
BD_DELTA=$(jq '.comparison.bedrock_vs_direct.api_total_delta_ms // null' "$REPORT_FILE")
BD_PCT=$(jq '.comparison.bedrock_vs_direct.api_total_delta_pct // null' "$REPORT_FILE")
BD_TTFT=$(jq '.comparison.bedrock_vs_direct.stream_ttft_delta_ms // null' "$REPORT_FILE")
GO_DELTA=$(jq '.comparison.guardrail_overhead.api_total_delta_ms // null' "$REPORT_FILE")
GO_PCT=$(jq '.comparison.guardrail_overhead.api_total_delta_pct // null' "$REPORT_FILE")
GO_TTFT=$(jq '.comparison.guardrail_overhead.stream_ttft_delta_ms // null' "$REPORT_FILE")

# Request IDs
D_REQIDS=$(jq -r '[.results.direct.request_ids.anthropic // []] | flatten | join(", ")' "$REPORT_FILE")
B_REQIDS=$(jq -r '[.results.bedrock.request_ids.aws // []] | flatten | join(", ")' "$REPORT_FILE")
G_REQIDS=$(jq -r '[.results.guardrail.request_ids.aws // []] | flatten | join(", ")' "$REPORT_FILE")

# --- Extract per-call traces if available ---
TRACES_JSON="{}"
if [ -n "$TRACES_DIR" ] && [ -d "$TRACES_DIR" ]; then
  extract_calls() {
    local file="$1" result="[]"
    while IFS= read -r line; do
      url=$(echo "$line" | jq -r '.url // empty' 2>/dev/null)
      [ -z "$url" ] && continue
      case "$url" in http*) ;; *) continue ;; esac
      call=$(echo "$line" | jq -c '{
        seq, method, status, provider, url: (.url | split("?")[0]),
        total_ms: (.total_ms // null), ttfb_ms: (.ttfb_ms // null),
        streaming: (.streaming // false), chunks: (.stream_metrics.chunk_count // null),
        ttft_ms: (.stream_metrics.ttft_ms // null), bytes: (.stream_metrics.total_bytes // null),
        request_id: (.response_headers.anthropic_request_id // .response_headers.aws_request_id // null),
        error: (.error // null)
      }' 2>/dev/null)
      [ -n "$call" ] && result=$(echo "$result" | jq --argjson c "$call" '. + [$c]')
    done < "$file"
    echo "$result"
  }

  for prov in direct bedrock guardrail; do
    trace_file="$TRACES_DIR/${prov}_1.jsonl"
    if [ -f "$trace_file" ]; then
      calls=$(extract_calls "$trace_file")
      TRACES_JSON=$(echo "$TRACES_JSON" | jq --arg p "$prov" --argjson c "$calls" '.[$p] = $c')
    fi
  done
fi

# --- Compute bar widths (percentage of max value) ---
max_of() {
  local max=0
  for v in "$@"; do
    [ "$v" = "null" ] && continue
    if [ "$(echo "$v > $max" | bc 2>/dev/null)" = "1" ]; then
      max="$v"
    fi
  done
  echo "$max"
}

bar_pct() {
  local val="$1" max="$2"
  [ "$val" = "null" ] || [ "$max" = "0" ] && echo "0" && return
  echo "scale=0; ($val * 100) / $max" | bc 2>/dev/null || echo "0"
}

SESSION_MAX=$(max_of "$D_SESSION" "$B_SESSION" "$G_SESSION")
API_MAX=$(max_of "$D_API" "$B_API" "$G_API")
TTFB_MAX=$(max_of "$D_TTFB" "$B_TTFB" "$G_TTFB")
TTFT_MAX=$(max_of "$D_TTFT" "$B_TTFT" "$G_TTFT")

fmt_ms() {
  local v="$1"
  [ "$v" = "null" ] && echo "—" && return
  if [ "$(echo "$v >= 1000" | bc 2>/dev/null)" = "1" ]; then
    echo "$(echo "scale=1; $v / 1000" | bc 2>/dev/null)s"
  else
    echo "$(echo "scale=0; $v / 1" | bc 2>/dev/null)ms"
  fi
}

# --- Generate HTML ---
cat > "$OUTPUT_FILE" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>SRE Todo App E2E — HTTP Instrumentation Dashboard</title>
<style>
  :root {
    --bg: #0d1117;
    --surface: #161b22;
    --surface2: #1c2333;
    --border: #30363d;
    --text: #e6edf3;
    --text-dim: #8b949e;
    --cyan: #00d4ff;
    --green: #4ade80;
    --yellow: #fbbf24;
    --red: #f87171;
    --purple: #7c3aed;
    --blue: #0066ff;
    --direct-color: #00d4ff;
    --bedrock-color: #fbbf24;
    --guardrail-color: #7c3aed;
  }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: 'SF Mono', 'Cascadia Code', 'Fira Code', 'JetBrains Mono', monospace;
    background: var(--bg);
    color: var(--text);
    padding: 24px;
    line-height: 1.5;
  }
  .container { max-width: 1200px; margin: 0 auto; }

  /* Header */
  .header {
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 24px;
    margin-bottom: 24px;
    background: var(--surface);
  }
  .header h1 {
    font-size: 1.4rem;
    color: var(--cyan);
    margin-bottom: 4px;
    font-weight: 600;
  }
  .header .subtitle {
    color: var(--text-dim);
    font-size: 0.85rem;
  }
  .meta-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
    gap: 8px;
    margin-top: 16px;
  }
  .meta-item { font-size: 0.8rem; }
  .meta-item .label { color: var(--text-dim); }
  .meta-item .value { color: var(--text); font-weight: 500; }

  /* Status badges */
  .badge {
    display: inline-block;
    padding: 2px 8px;
    border-radius: 12px;
    font-size: 0.75rem;
    font-weight: 600;
  }
  .badge-pass { background: rgba(74, 222, 128, 0.15); color: var(--green); }
  .badge-fail { background: rgba(248, 113, 113, 0.15); color: var(--red); }
  .badge-direct { background: rgba(0, 212, 255, 0.15); color: var(--direct-color); }
  .badge-bedrock { background: rgba(251, 191, 36, 0.15); color: var(--bedrock-color); }
  .badge-guardrail { background: rgba(124, 58, 237, 0.15); color: var(--guardrail-color); }

  /* Cards */
  .card {
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 20px;
    margin-bottom: 20px;
    background: var(--surface);
  }
  .card h2 {
    font-size: 1rem;
    color: var(--cyan);
    margin-bottom: 16px;
    padding-bottom: 8px;
    border-bottom: 1px solid var(--border);
  }

  /* Grid layouts */
  .grid-2 { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; }
  .grid-3 { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 20px; }

  /* Comparison table */
  .comp-table {
    width: 100%;
    border-collapse: collapse;
    font-size: 0.85rem;
  }
  .comp-table th {
    text-align: left;
    padding: 10px 12px;
    border-bottom: 2px solid var(--border);
    color: var(--text-dim);
    font-weight: 500;
  }
  .comp-table td {
    padding: 10px 12px;
    border-bottom: 1px solid var(--border);
  }
  .comp-table tr:last-child td { border-bottom: none; }
  .comp-table .metric-name { color: var(--text-dim); }
  .comp-table .val-direct { color: var(--direct-color); }
  .comp-table .val-bedrock { color: var(--bedrock-color); }
  .comp-table .val-guardrail { color: var(--guardrail-color); }

  /* Bar charts */
  .bar-row {
    display: flex;
    align-items: center;
    margin-bottom: 8px;
    gap: 8px;
  }
  .bar-label {
    width: 90px;
    text-align: right;
    font-size: 0.8rem;
    color: var(--text-dim);
    flex-shrink: 0;
  }
  .bar-track {
    flex: 1;
    height: 28px;
    background: var(--surface2);
    border-radius: 4px;
    overflow: hidden;
    position: relative;
  }
  .bar-fill {
    height: 100%;
    border-radius: 4px;
    display: flex;
    align-items: center;
    padding-left: 8px;
    font-size: 0.75rem;
    font-weight: 600;
    color: var(--bg);
    transition: width 0.6s ease;
    min-width: fit-content;
  }
  .bar-fill.direct { background: var(--direct-color); }
  .bar-fill.bedrock { background: var(--bedrock-color); }
  .bar-fill.guardrail { background: var(--guardrail-color); }

  /* Delta indicators */
  .delta {
    font-size: 0.85rem;
    padding: 12px 16px;
    border-radius: 6px;
    background: var(--surface2);
    margin-bottom: 8px;
  }
  .delta .label { color: var(--text-dim); font-size: 0.8rem; }
  .delta .value { font-weight: 600; font-size: 1.1rem; }
  .delta .positive { color: var(--red); }
  .delta .negative { color: var(--green); }
  .delta .neutral { color: var(--text-dim); }
  .delta .sub { color: var(--text-dim); font-size: 0.8rem; margin-left: 8px; }

  /* Timeline */
  .timeline { margin-top: 12px; }
  .timeline-row {
    display: flex;
    align-items: center;
    padding: 6px 0;
    border-bottom: 1px solid rgba(48, 54, 61, 0.5);
    font-size: 0.8rem;
    gap: 8px;
  }
  .timeline-row:last-child { border-bottom: none; }
  .timeline-seq {
    width: 30px;
    color: var(--text-dim);
    text-align: right;
    flex-shrink: 0;
  }
  .timeline-method {
    width: 45px;
    font-weight: 600;
    flex-shrink: 0;
  }
  .timeline-status {
    width: 35px;
    flex-shrink: 0;
  }
  .timeline-status.s200 { color: var(--green); }
  .timeline-status.s400, .timeline-status.s401 { color: var(--red); }
  .timeline-status.snull { color: var(--text-dim); }
  .timeline-url {
    flex: 1;
    color: var(--text-dim);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .timeline-timing {
    width: 120px;
    text-align: right;
    flex-shrink: 0;
    font-variant-numeric: tabular-nums;
  }
  .timeline-bar {
    width: 100px;
    flex-shrink: 0;
  }
  .timeline-bar-inner {
    height: 12px;
    border-radius: 2px;
    min-width: 2px;
  }
  .timeline-meta {
    width: 70px;
    text-align: right;
    color: var(--text-dim);
    flex-shrink: 0;
  }

  /* Request IDs */
  .reqid-list { font-size: 0.75rem; }
  .reqid-list .provider-label {
    font-weight: 600;
    margin-top: 8px;
    margin-bottom: 4px;
  }
  .reqid-list code {
    display: block;
    padding: 2px 0;
    color: var(--text-dim);
    word-break: break-all;
  }

  /* Provider summary cards */
  .provider-card {
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 16px;
    background: var(--surface2);
  }
  .provider-card h3 {
    font-size: 0.9rem;
    margin-bottom: 12px;
  }
  .provider-card .stat {
    display: flex;
    justify-content: space-between;
    padding: 4px 0;
    font-size: 0.8rem;
  }
  .provider-card .stat .label { color: var(--text-dim); }
  .provider-card .stat .value { font-weight: 600; font-variant-numeric: tabular-nums; }

  /* Footer */
  .footer {
    text-align: center;
    padding: 20px;
    color: var(--text-dim);
    font-size: 0.75rem;
  }
  .footer a { color: var(--cyan); text-decoration: none; }

  @media (max-width: 800px) {
    .grid-2, .grid-3 { grid-template-columns: 1fr; }
    .meta-grid { grid-template-columns: 1fr 1fr; }
  }
</style>
</head>
<body>
<div class="container">
HTMLEOF

# Header
cat >> "$OUTPUT_FILE" << EOF
  <div class="header">
    <h1>SRE Todo App E2E &mdash; HTTP Instrumentation Dashboard</h1>
    <div class="subtitle">Real HTTP call instrumentation via Node.js fetch wrapping &mdash; zero proxy overhead</div>
    <div class="meta-grid">
      <div class="meta-item"><span class="label">Timestamp:</span> <span class="value">$TIMESTAMP</span></div>
      <div class="meta-item"><span class="label">Host:</span> <span class="value">$HOSTNAME ($OS/$ARCH)</span></div>
      <div class="meta-item"><span class="label">Node:</span> <span class="value">$NODE</span></div>
      <div class="meta-item"><span class="label">Region:</span> <span class="value">$REGION</span></div>
      <div class="meta-item"><span class="label">Guardrail:</span> <span class="value">$GUARDRAIL_ID</span></div>
      <div class="meta-item"><span class="label">Iterations:</span> <span class="value">$ITERATIONS</span></div>
    </div>
  </div>
EOF

# Provider summary cards
cat >> "$OUTPUT_FILE" << EOF
  <div class="grid-3" style="margin-bottom: 20px;">
    <div class="provider-card">
      <h3><span class="badge badge-direct">DIRECT</span> Anthropic Direct API</h3>
      <div class="stat"><span class="label">Session</span> <span class="value" style="color:var(--direct-color)">$(fmt_ms "$D_SESSION")</span></div>
      <div class="stat"><span class="label">API Total (avg)</span> <span class="value">$(fmt_ms "$D_API")</span></div>
      <div class="stat"><span class="label">TTFB</span> <span class="value">$(fmt_ms "$D_TTFB")</span></div>
      <div class="stat"><span class="label">TTFT</span> <span class="value">$(fmt_ms "$D_TTFT")</span></div>
      <div class="stat"><span class="label">Chunks</span> <span class="value">$D_CHUNKS</span></div>
      <div class="stat"><span class="label">HTTP Calls</span> <span class="value">$D_HTTP</span></div>
      <div class="stat"><span class="label">Todo Created</span> <span class="value">${D_CREATED} (${D_TODO}B)</span></div>
    </div>
    <div class="provider-card">
      <h3><span class="badge badge-bedrock">BEDROCK</span> AWS Bedrock</h3>
      <div class="stat"><span class="label">Session</span> <span class="value" style="color:var(--bedrock-color)">$(fmt_ms "$B_SESSION")</span></div>
      <div class="stat"><span class="label">API Total (avg)</span> <span class="value">$(fmt_ms "$B_API")</span></div>
      <div class="stat"><span class="label">TTFB</span> <span class="value">$(fmt_ms "$B_TTFB")</span></div>
      <div class="stat"><span class="label">TTFT</span> <span class="value">$(fmt_ms "$B_TTFT")</span></div>
      <div class="stat"><span class="label">Chunks</span> <span class="value">$B_CHUNKS</span></div>
      <div class="stat"><span class="label">HTTP Calls</span> <span class="value">$B_HTTP</span></div>
      <div class="stat"><span class="label">Todo Created</span> <span class="value">${B_CREATED} (${B_TODO}B)</span></div>
    </div>
    <div class="provider-card">
      <h3><span class="badge badge-guardrail">GUARDRAIL</span> Bedrock + Guardrail</h3>
      <div class="stat"><span class="label">Session</span> <span class="value" style="color:var(--guardrail-color)">$(fmt_ms "$G_SESSION")</span></div>
      <div class="stat"><span class="label">API Total (avg)</span> <span class="value">$(fmt_ms "$G_API")</span></div>
      <div class="stat"><span class="label">TTFB</span> <span class="value">$(fmt_ms "$G_TTFB")</span></div>
      <div class="stat"><span class="label">TTFT</span> <span class="value">$(fmt_ms "$G_TTFT")</span></div>
      <div class="stat"><span class="label">Chunks</span> <span class="value">$G_CHUNKS</span></div>
      <div class="stat"><span class="label">HTTP Calls</span> <span class="value">$G_HTTP</span></div>
      <div class="stat"><span class="label">Todo Created</span> <span class="value">${G_CREATED} (${G_TODO}B)</span></div>
    </div>
  </div>
EOF

# Latency comparison bars
cat >> "$OUTPUT_FILE" << EOF
  <div class="grid-2">
    <div class="card">
      <h2>Session Total Time</h2>
      <div class="bar-row">
        <div class="bar-label">Direct</div>
        <div class="bar-track"><div class="bar-fill direct" style="width:$(bar_pct "$D_SESSION" "$SESSION_MAX")%">$(fmt_ms "$D_SESSION")</div></div>
      </div>
      <div class="bar-row">
        <div class="bar-label">Bedrock</div>
        <div class="bar-track"><div class="bar-fill bedrock" style="width:$(bar_pct "$B_SESSION" "$SESSION_MAX")%">$(fmt_ms "$B_SESSION")</div></div>
      </div>
      <div class="bar-row">
        <div class="bar-label">Guardrail</div>
        <div class="bar-track"><div class="bar-fill guardrail" style="width:$(bar_pct "$G_SESSION" "$SESSION_MAX")%">$(fmt_ms "$G_SESSION")</div></div>
      </div>
    </div>

    <div class="card">
      <h2>API Total (avg per call)</h2>
      <div class="bar-row">
        <div class="bar-label">Direct</div>
        <div class="bar-track"><div class="bar-fill direct" style="width:$(bar_pct "$D_API" "$API_MAX")%">$(fmt_ms "$D_API")</div></div>
      </div>
      <div class="bar-row">
        <div class="bar-label">Bedrock</div>
        <div class="bar-track"><div class="bar-fill bedrock" style="width:$(bar_pct "$B_API" "$API_MAX")%">$(fmt_ms "$B_API")</div></div>
      </div>
      <div class="bar-row">
        <div class="bar-label">Guardrail</div>
        <div class="bar-track"><div class="bar-fill guardrail" style="width:$(bar_pct "$G_API" "$API_MAX")%">$(fmt_ms "$G_API")</div></div>
      </div>
    </div>

    <div class="card">
      <h2>Stream TTFB</h2>
      <div class="bar-row">
        <div class="bar-label">Direct</div>
        <div class="bar-track"><div class="bar-fill direct" style="width:$(bar_pct "$D_TTFB" "$TTFB_MAX")%">$(fmt_ms "$D_TTFB")</div></div>
      </div>
      <div class="bar-row">
        <div class="bar-label">Bedrock</div>
        <div class="bar-track"><div class="bar-fill bedrock" style="width:$(bar_pct "$B_TTFB" "$TTFB_MAX")%">$(fmt_ms "$B_TTFB")</div></div>
      </div>
      <div class="bar-row">
        <div class="bar-label">Guardrail</div>
        <div class="bar-track"><div class="bar-fill guardrail" style="width:$(bar_pct "$G_TTFB" "$TTFB_MAX")%">$(fmt_ms "$G_TTFB")</div></div>
      </div>
    </div>

    <div class="card">
      <h2>Stream TTFT (first token)</h2>
      <div class="bar-row">
        <div class="bar-label">Direct</div>
        <div class="bar-track"><div class="bar-fill direct" style="width:$(bar_pct "$D_TTFT" "$TTFT_MAX")%">$(fmt_ms "$D_TTFT")</div></div>
      </div>
      <div class="bar-row">
        <div class="bar-label">Bedrock</div>
        <div class="bar-track"><div class="bar-fill bedrock" style="width:$(bar_pct "$B_TTFT" "$TTFT_MAX")%">$(fmt_ms "$B_TTFT")</div></div>
      </div>
      <div class="bar-row">
        <div class="bar-label">Guardrail</div>
        <div class="bar-track"><div class="bar-fill guardrail" style="width:$(bar_pct "$G_TTFT" "$TTFT_MAX")%">$(fmt_ms "$G_TTFT")</div></div>
      </div>
    </div>
  </div>
EOF

# Delta cards
delta_class() {
  local v="$1"
  [ "$v" = "null" ] && echo "neutral" && return
  if [ "$(echo "$v > 50" | bc 2>/dev/null)" = "1" ]; then echo "positive"
  elif [ "$(echo "$v < -50" | bc 2>/dev/null)" = "1" ]; then echo "negative"
  else echo "neutral"
  fi
}

delta_sign() {
  local v="$1"
  [ "$v" = "null" ] && echo "—" && return
  if [ "$(echo "$v > 0" | bc 2>/dev/null)" = "1" ]; then echo "+$(fmt_ms "$v")"
  else echo "$(fmt_ms "$v")"
  fi
}

cat >> "$OUTPUT_FILE" << EOF
  <div class="grid-2">
    <div class="card">
      <h2>Bedrock vs Direct API</h2>
      <div class="delta">
        <div class="label">API Total Delta</div>
        <div class="value $(delta_class "$BD_DELTA")">$(delta_sign "$BD_DELTA") <span class="sub">(${BD_PCT:-0}%)</span></div>
      </div>
      <div class="delta">
        <div class="label">TTFT Delta</div>
        <div class="value $(delta_class "$BD_TTFT")">$(delta_sign "$BD_TTFT")</div>
      </div>
    </div>
    <div class="card">
      <h2>Guardrail Overhead (vs Bedrock)</h2>
      <div class="delta">
        <div class="label">API Total Delta</div>
        <div class="value $(delta_class "$GO_DELTA")">$(delta_sign "$GO_DELTA") <span class="sub">(${GO_PCT:-0}%)</span></div>
      </div>
      <div class="delta">
        <div class="label">TTFT Delta</div>
        <div class="value $(delta_class "$GO_TTFT")">$(delta_sign "$GO_TTFT")</div>
      </div>
    </div>
  </div>
EOF

# Per-call HTTP trace timelines
if [ "$TRACES_JSON" != "{}" ]; then
  for prov in direct bedrock guardrail; do
    calls=$(echo "$TRACES_JSON" | jq --arg p "$prov" '.[$p] // []')
    call_count=$(echo "$calls" | jq 'length')
    [ "$call_count" = "0" ] && continue

    case "$prov" in
      direct) badge_class="badge-direct"; bar_class="direct" ;;
      bedrock) badge_class="badge-bedrock"; bar_class="bedrock" ;;
      guardrail) badge_class="badge-guardrail"; bar_class="guardrail" ;;
    esac

    # Find max total_ms for this provider
    max_ms=$(echo "$calls" | jq '[.[].total_ms // 0] | max')

    prov_upper=$(echo "$prov" | tr '[:lower:]' '[:upper:]')
    cat >> "$OUTPUT_FILE" << EOF
  <div class="card">
    <h2><span class="badge $badge_class">$prov_upper</span> Per-Call HTTP Trace</h2>
    <div class="timeline">
      <div class="timeline-row" style="font-weight:600; color:var(--text-dim); font-size:0.75rem;">
        <div class="timeline-seq">#</div>
        <div class="timeline-method">Verb</div>
        <div class="timeline-status">Code</div>
        <div class="timeline-url">URL</div>
        <div class="timeline-timing">TTFB / Total</div>
        <div class="timeline-bar">Waterfall</div>
        <div class="timeline-meta">Chunks</div>
      </div>
EOF

    # Render each call
    echo "$calls" | jq -c '.[]' | while IFS= read -r call; do
      seq=$(echo "$call" | jq -r '.seq')
      method=$(echo "$call" | jq -r '.method')
      status=$(echo "$call" | jq -r '.status // "—"')
      url=$(echo "$call" | jq -r '.url')
      total_ms=$(echo "$call" | jq '.total_ms // 0')
      ttfb_ms=$(echo "$call" | jq '.ttfb_ms // 0')
      chunks=$(echo "$call" | jq -r '.chunks // "—"')
      streaming=$(echo "$call" | jq -r '.streaming')
      err=$(echo "$call" | jq -r '.error // empty')

      # Shorten URL for display
      short_url=$(echo "$url" | sed 's|https://||' | sed 's|http://||')
      [ ${#short_url} -gt 70 ] && short_url="${short_url:0:67}..."

      status_class="snull"
      [ "$status" = "200" ] && status_class="s200"
      [ "$status" = "400" ] || [ "$status" = "401" ] && status_class="s400"

      ttfb_fmt="—"
      [ "$ttfb_ms" != "0" ] && [ "$ttfb_ms" != "null" ] && ttfb_fmt=$(fmt_ms "$ttfb_ms")
      total_fmt="—"
      [ "$total_ms" != "0" ] && [ "$total_ms" != "null" ] && total_fmt=$(fmt_ms "$total_ms")

      bar_width=2
      if [ "$max_ms" != "0" ] && [ "$total_ms" != "0" ]; then
        bar_width=$(echo "scale=0; ($total_ms * 100) / $max_ms" | bc 2>/dev/null || echo 2)
        [ "$bar_width" -lt 2 ] && bar_width=2
      fi

      # TTFB portion of bar
      ttfb_width=0
      if [ "$ttfb_ms" != "0" ] && [ "$total_ms" != "0" ]; then
        ttfb_width=$(echo "scale=0; ($ttfb_ms * $bar_width) / $total_ms" | bc 2>/dev/null || echo 0)
      fi

      error_indicator=""
      [ -n "$err" ] && error_indicator=" title=\"Error: $err\" style=\"opacity:0.5\""

      cat >> "$OUTPUT_FILE" << ROWEOF
      <div class="timeline-row"$error_indicator>
        <div class="timeline-seq">$seq</div>
        <div class="timeline-method">$method</div>
        <div class="timeline-status $status_class">$status</div>
        <div class="timeline-url" title="$url">$short_url</div>
        <div class="timeline-timing">${ttfb_fmt} / ${total_fmt}</div>
        <div class="timeline-bar"><div class="timeline-bar-inner $bar_class" style="width:${bar_width}%"></div></div>
        <div class="timeline-meta">${chunks}${streaming:+ }</div>
      </div>
ROWEOF
    done

    echo "    </div></div>" >> "$OUTPUT_FILE"
  done
fi

# Request IDs
cat >> "$OUTPUT_FILE" << EOF
  <div class="card">
    <h2>Request IDs</h2>
    <div class="reqid-list">
      <div class="provider-label" style="color:var(--direct-color)">Direct API (Anthropic)</div>
EOF

IFS=',' read -ra D_IDS <<< "$(echo "$D_REQIDS" | tr ' ' ',')"
for id in "${D_IDS[@]}"; do
  id=$(echo "$id" | tr -d ' ')
  [ -n "$id" ] && echo "      <code>$id</code>" >> "$OUTPUT_FILE"
done

cat >> "$OUTPUT_FILE" << EOF
      <div class="provider-label" style="color:var(--bedrock-color); margin-top:12px;">Bedrock (AWS)</div>
EOF

IFS=',' read -ra B_IDS <<< "$(echo "$B_REQIDS" | tr ' ' ',')"
for id in "${B_IDS[@]}"; do
  id=$(echo "$id" | tr -d ' ')
  [ -n "$id" ] && echo "      <code>$id</code>" >> "$OUTPUT_FILE"
done

cat >> "$OUTPUT_FILE" << EOF
      <div class="provider-label" style="color:var(--guardrail-color); margin-top:12px;">Guardrail (AWS)</div>
EOF

IFS=',' read -ra G_IDS <<< "$(echo "$G_REQIDS" | tr ' ' ',')"
for id in "${G_IDS[@]}"; do
  id=$(echo "$id" | tr -d ' ')
  [ -n "$id" ] && echo "      <code>$id</code>" >> "$OUTPUT_FILE"
done

cat >> "$OUTPUT_FILE" << EOF
    </div>
  </div>
EOF

# Methodology
cat >> "$OUTPUT_FILE" << 'EOF'
  <div class="card">
    <h2>Methodology</h2>
    <div style="font-size:0.8rem; color:var(--text-dim); line-height:1.7;">
      <p><strong>Instrumentation:</strong> Node.js <code>--import</code> hook wraps <code>globalThis.fetch</code> before Claude Code loads. Every HTTP call is captured with sub-ms precision from inside the process &mdash; zero proxy overhead, no MITM, no network hop added.</p>
      <p style="margin-top:8px;"><strong>Task:</strong> Create a single-file Todo HTML application (input field, add button, checkboxes, delete, completion counter). Deterministic prompt designed to minimize behavioral variation across providers.</p>
      <p style="margin-top:8px;"><strong>Metrics:</strong> TTFB = time from fetch() call to first response byte. TTFT = time to first <code>content_block_delta</code> in SSE stream. Chunks = number of streaming ReadableStream reads. Session Total = wall clock from runner start to exit.</p>
      <p style="margin-top:8px;"><strong>Models:</strong> Claude Code selects models automatically. Direct API uses Anthropic's routing. Bedrock routes through <code>us.anthropic.claude-sonnet-4-5</code> (main) and <code>global.anthropic.claude-haiku-4-5</code> (lightweight calls).</p>
    </div>
  </div>
EOF

# Footer
cat >> "$OUTPUT_FILE" << 'EOF'
  <div class="footer">
    Generated by <a href="#">SRE Latency Monitor</a> &mdash; Real HTTP Instrumentation via Node.js fetch wrapping
  </div>
</div>
</body>
</html>
EOF

echo "Dashboard generated: $OUTPUT_FILE" >&2
echo "$OUTPUT_FILE"
