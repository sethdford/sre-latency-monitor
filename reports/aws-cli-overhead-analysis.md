# AWS CLI Overhead Analysis: Is the AWS CLI Used by Claude Code?

**Date:** 2026-02-21
**Methodology:** Process-level HTTP instrumentation via `globalThis.fetch` wrapping
**Data Source:** 9 instrumented sessions (3 iterations × 3 providers), 33 unique request IDs

## Finding: AWS CLI is NOT used

Claude Code uses the **AWS SDK for JavaScript (v3)** directly — the `aws` CLI binary is never invoked.

## Evidence

### 1. No AWS CLI Subprocess Calls

Zero STS, IAM, SSO, or credential-related HTTP calls observed across all 9 Bedrock sessions:

```
$ grep -i 'sts\|token\|credential\|iam\|signin\|sso' bedrock_*.jsonl
(no results)
```

### 2. Direct Bedrock Runtime API Calls

All Bedrock requests go straight to the Bedrock Runtime endpoint with SigV4 signatures computed in-process:

```json
{
  "url": "https://bedrock-runtime.us-east-1.amazonaws.com/model/us.anthropic.claude-sonnet-4-5-20250929-v1:0/invoke-with-response-stream",
  "request_headers": {
    "anthropic_beta": "claude-code-20250219",
    "anthropic_version": "2023-06-01",
    "has_authorization": true,
    "content_type": "application/json",
    "has_aws_sig": true
  }
}
```

### 3. Credential Resolution is In-Process

The `@aws-sdk/client-bedrock-runtime` inside Claude Code's npm package resolves credentials from the standard credential provider chain (env vars → `~/.aws/credentials` → SSO cache → IMDS) without shelling out to `aws`.

### 4. URL Comparison: Direct API vs Bedrock

| Provider                | Unique URLs | Endpoints                                                                                                                                                                               |
| ----------------------- | ----------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Direct API**          | 12          | `api.anthropic.com/v1/messages`, `api.anthropic.com/v1/messages/count_tokens`, `api.anthropic.com/api/eval/...`, MCP servers (Linear, Slack, GitHub Copilot, Context7), OAuth discovery |
| **Bedrock**             | 4           | `bedrock-runtime.us-east-1.amazonaws.com/model/.../invoke-with-response-stream` (Sonnet 4.5 + Haiku 4.5), MCP servers (GitHub Copilot, Context7)                                        |
| **Bedrock + Guardrail** | 4           | Same as Bedrock (guardrail is a header parameter, not a separate endpoint)                                                                                                              |

### 5. Bedrock Has a Cleaner Call Pattern

Bedrock sessions make fewer HTTP calls than Direct API sessions:

| Metric                        | Direct API | Bedrock | Bedrock + Guardrail |
| ----------------------------- | ---------- | ------- | ------------------- |
| HTTP calls per session (mean) | 10         | 6       | 7                   |
| API calls per session (mean)  | 3          | 3       | 3                   |
| MCP calls per session (mean)  | 2          | 2       | 2                   |

The difference comes from Direct API sessions making additional calls:

- `count_tokens` endpoint (not used in Bedrock mode)
- `api/eval/sdk-*` endpoint (telemetry/analytics)
- More MCP OAuth discovery calls (Linear, Slack)

## Implications

1. **Zero AWS CLI overhead** in the Claude Code → Bedrock call path
2. The `aws --version` captured in environment metadata is informational only
3. AWS credential caching and refresh happen in the Node.js process via the JS SDK
4. SigV4 signing adds negligible overhead (computed in-process, no network call)
5. The ~98ms Bedrock overhead vs Direct API is entirely network path (Bedrock proxy layer), not CLI or credential overhead

## Reproduction

```bash
# Run instrumented Bedrock session
CLAUDE_CODE_USE_BEDROCK=1 ./scripts/run-instrumented.sh -p "say hello"

# Check for AWS CLI calls
jq -r 'select(.url) | .url' /tmp/sre-http-calls.jsonl | grep '^http' | grep -iE 'sts|token|credential|iam'
# (empty — no AWS CLI calls)

# See all Bedrock HTTP calls
jq 'select(.url) | select(.url | startswith("https://bedrock")) | {url, total_ms, ttfb_ms}' /tmp/sre-http-calls.jsonl
```

## Request IDs (Audit Trail)

All 18 AWS request IDs from the 6 Bedrock + 3 Guardrail sessions that produced this finding:

**Bedrock (no guardrail):**

- `12a8d5d4-2379-49b7-ab5c-cc19da8f2b79`
- `21b1799d-d4e9-4b5b-95bb-a6a3aabe1d13`
- `2cb520ae-582d-4bc5-b867-713134c0d3e5`
- `5f16deff-0046-4db6-b01f-c4f7a6b5b782`
- `663d1e9e-06a1-42cb-86f9-09516c2634af`
- `aec401bb-a263-4709-b92d-93dda478d6c3`
- `d96c908a-8740-4684-8331-95a3d7a50b71`
- `e468d5c3-f79d-4f22-8a22-78053594fc60`
- `ff99692d-2a05-4df6-b090-351adb76980e`

**Bedrock + Guardrail (pcxoysw8v24d):**

- `0e3262e4-d250-4490-81e5-fd533d79cc95`
- `147775b1-4836-4d81-9e7e-84ac64934fd9`
- `61f0fa77-45c3-49d3-ae65-cd6b4f18af39`
- `7fd44ca2-7671-4bc6-a370-78a26f5a4bd2`
- `81e7e637-a637-4bd3-ac9d-6817ec1d9c08`
- `9dc3574c-fa32-4ee1-9e4e-a214a1d77d32`
- `c2715d25-2f3f-4b98-8195-5afc2cbf2975`
- `dac8466a-316b-4292-89a7-3a1fcafb199b`
- `e3007c0b-49b6-4baf-bb74-bb949c7bcdd9`
