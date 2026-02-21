#!/bin/bash
# ============================================================================
# SRE Instrumented Claude Code Runner
# ============================================================================
#
# Runs Claude Code from the npm package under Node.js with fetch
# instrumentation injected via --import. Every HTTP call Claude Code
# makes is logged to /tmp/sre-http-calls.jsonl with full timing,
# headers, streaming metrics, and request IDs.
#
# Usage:
#   run-instrumented.sh -p "say hello"
#   run-instrumented.sh -p "say hello" --verbose
#   CLAUDE_CODE_USE_BEDROCK=1 run-instrumented.sh -p "say hello"
#
# Requires: Node.js >= 18, @anthropic-ai/claude-code npm package

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTRUMENT_MJS="$SCRIPT_DIR/instrument.mjs"
HTTP_LOG="${SRE_HTTP_LOG:-/tmp/sre-http-calls.jsonl}"

# --- Locate Claude Code npm package ---
find_claude_cli() {
  local npm_root
  npm_root="$(npm root -g 2>/dev/null)" || true

  local cli_js="$npm_root/@anthropic-ai/claude-code/cli.js"
  if [ -f "$cli_js" ]; then
    echo "$cli_js"
    return
  fi

  # Try npx resolution
  local npx_path
  npx_path="$(npx --yes which @anthropic-ai/claude-code 2>/dev/null)" || true
  if [ -n "$npx_path" ] && [ -f "$npx_path" ]; then
    echo "$npx_path"
    return
  fi

  echo ""
}

CLI_JS="$(find_claude_cli)"

if [ -z "$CLI_JS" ]; then
  echo "ERROR: Claude Code npm package not found." >&2
  echo "Install with: npm install -g @anthropic-ai/claude-code" >&2
  exit 1
fi

# --- Verify instrument.mjs exists ---
if [ ! -f "$INSTRUMENT_MJS" ]; then
  echo "ERROR: instrument.mjs not found at $INSTRUMENT_MJS" >&2
  exit 1
fi

# --- Check --verbose flag (consume it, don't pass to claude) ---
VERBOSE=0
ARGS=()
for arg in "$@"; do
  if [ "$arg" = "--verbose" ] || [ "$arg" = "-v" ]; then
    VERBOSE=1
  else
    ARGS+=("$arg")
  fi
done

# --- Clear previous log ---
> "$HTTP_LOG"

# --- Detect provider ---
PROVIDER="anthropic-direct"
if [ -n "$CLAUDE_CODE_USE_BEDROCK" ] || [ "$CLAUDE_CODE_USE_BEDROCK" = "1" ]; then
  PROVIDER="aws-bedrock"
fi

# --- Capture environment metadata ---
NODE_VER="$(node --version 2>/dev/null || echo unknown)"
AWS_CLI_VER="$(aws --version 2>/dev/null | head -1 || echo 'not installed')"

if [ "$VERBOSE" = "1" ]; then
  echo "[SRE] Provider:    $PROVIDER" >&2
  echo "[SRE] Node:        $NODE_VER" >&2
  echo "[SRE] AWS CLI:     $AWS_CLI_VER" >&2
  echo "[SRE] Claude CLI:  $CLI_JS" >&2
  echo "[SRE] HTTP log:    $HTTP_LOG" >&2
  echo "[SRE] Instrument:  $INSTRUMENT_MJS" >&2
  echo "" >&2
fi

# Write metadata header to log
jq -nc \
  --arg provider "$PROVIDER" \
  --arg node_ver "$NODE_VER" \
  --arg aws_cli "$AWS_CLI_VER" \
  --arg cli_js "$CLI_JS" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{type:"session_metadata", timestamp:$ts, provider:$provider,
    node_version:$node_ver, aws_cli_version:$aws_cli, cli_path:$cli_js}' \
  >> "$HTTP_LOG"

# --- Run instrumented Claude Code ---
# env -u CLAUDECODE: strip Claude Code's env var that blocks nested invocations
# CLAUDE_CODE_ENABLE_TELEMETRY=1: enable native OTel events
export SRE_HTTP_LOG="$HTTP_LOG"
[ "$VERBOSE" = "1" ] && export SRE_VERBOSE=1

exec env -u CLAUDECODE \
  CLAUDE_CODE_ENABLE_TELEMETRY=1 \
  node --import "$INSTRUMENT_MJS" "$CLI_JS" "${ARGS[@]}"
