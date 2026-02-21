// SRE Fetch Instrumentation Module
// Wraps globalThis.fetch BEFORE Claude Code loads to capture every HTTP call.
//
// Usage: node --import ./instrument.mjs /path/to/cli.js -p "prompt"
//
// Output: Appends structured JSON to /tmp/sre-http-calls.jsonl
// Each entry captures: URL, method, headers, timing (TTFB, TTFT, total),
// streaming metrics (chunk count, inter-chunk intervals), request IDs,
// provider classification, response status, and body sizes.

import { appendFileSync } from "node:fs";
import { performance } from "node:perf_hooks";

const LOG_FILE = process.env.SRE_HTTP_LOG || "/tmp/sre-http-calls.jsonl";
const VERBOSE = process.env.SRE_VERBOSE === "1";

// Sequence counter for ordering
let callSeq = 0;

function log(msg) {
  if (VERBOSE) {
    process.stderr.write(`[SRE] ${msg}\n`);
  }
}

function classifyProvider(url) {
  try {
    const u = new URL(url);
    if (u.hostname === "api.anthropic.com") return "anthropic-direct";
    if (u.hostname.includes("bedrock-runtime")) return "aws-bedrock";
    if (u.hostname === "127.0.0.1" || u.hostname === "localhost")
      return "mcp-local";
    if (u.hostname.includes("githubcopilot.com")) return "mcp-github";
    if (u.hostname.includes("anthropic.com")) return "anthropic-other";
    return "external";
  } catch {
    return "unknown";
  }
}

function extractRequestHeaders(headers) {
  const result = {};
  if (!headers) return result;

  // Headers can be: plain object, Headers instance, or array of [key, value]
  const entries =
    typeof headers.entries === "function"
      ? Array.from(headers.entries())
      : Array.isArray(headers)
        ? headers
        : Object.entries(headers);

  for (const [key, value] of entries) {
    const k = key.toLowerCase();
    // Capture select headers, redact auth values
    if (k === "content-type") result.content_type = value;
    if (k === "anthropic-version") result.anthropic_version = value;
    if (k === "x-api-key") result.has_api_key = true;
    if (k === "authorization") result.has_authorization = true;
    if (k === "anthropic-beta") result.anthropic_beta = value;
    if (k === "x-amz-content-sha256") result.has_aws_sig = true;
  }
  return result;
}

function extractResponseHeaders(response) {
  const result = {};
  if (!response || !response.headers) return result;

  // Anthropic request ID
  const reqId = response.headers.get("request-id");
  if (reqId) result.anthropic_request_id = reqId;

  // AWS request IDs
  const awsReqId = response.headers.get("x-amzn-requestid");
  if (awsReqId) result.aws_request_id = awsReqId;

  const amzReqId = response.headers.get("x-amz-request-id");
  if (amzReqId) result.aws_request_id = amzReqId;

  // Content type for streaming detection
  const ct = response.headers.get("content-type");
  if (ct) result.content_type = ct;

  // CF-Ray for CDN tracing
  const cfRay = response.headers.get("cf-ray");
  if (cfRay) result.cf_ray = cfRay;

  // Server timing
  const serverTiming = response.headers.get("server-timing");
  if (serverTiming) result.server_timing = serverTiming;

  return result;
}

function isStreamingResponse(response) {
  const ct = response.headers.get("content-type") || "";
  const te = response.headers.get("transfer-encoding") || "";
  return (
    ct.includes("text/event-stream") ||
    ct.includes("application/x-ndjson") ||
    te.includes("chunked")
  );
}

function round(n) {
  return Math.round(n * 100) / 100;
}

function emitRecord(record) {
  // Round all timing fields
  for (const key of Object.keys(record)) {
    if (key.endsWith("_ms") && typeof record[key] === "number") {
      record[key] = round(record[key]);
    }
  }

  if (record.stream_metrics) {
    for (const key of Object.keys(record.stream_metrics)) {
      if (
        key.endsWith("_ms") &&
        typeof record.stream_metrics[key] === "number"
      ) {
        record.stream_metrics[key] = round(record.stream_metrics[key]);
      }
    }
  }

  const line = JSON.stringify(record) + "\n";
  try {
    appendFileSync(LOG_FILE, line);
  } catch {
    // Silently ignore write failures — don't disrupt Claude Code
  }
  log(
    `>>> FETCH ${record.method} ${record.url} [${record.status || "pending"}] ${record.total_ms || "?"}ms`,
  );
}

function wrapStreamingBody(response, record) {
  if (!response.body) return response;

  const originalBody = response.body;
  const reader = originalBody.getReader();
  const chunkTimings = [];
  let firstChunkTime = null;
  let firstTokenTime = null;
  let totalBytes = 0;
  let chunkCount = 0;

  const wrappedStream = new ReadableStream({
    async pull(controller) {
      try {
        const { done, value } = await reader.read();
        if (done) {
          // Stream complete — finalize timing
          const now = performance.now();
          record.stream_end_ms = now;
          record.total_ms = now - record.start_ms;
          record.streaming = true;
          record.stream_metrics = {
            chunk_count: chunkCount,
            total_bytes: totalBytes,
            ttfb_ms: firstChunkTime ? firstChunkTime - record.start_ms : null,
            chunk_timings_ms: chunkTimings.slice(0, 50), // cap at 50
          };

          // Detect TTFT from SSE data (first content_block_delta)
          if (firstTokenTime) {
            record.stream_metrics.ttft_ms = firstTokenTime - record.start_ms;
          }

          controller.close();
          emitRecord(record);
          return;
        }

        const now = performance.now();
        chunkCount++;
        totalBytes += value.byteLength;

        if (!firstChunkTime) {
          firstChunkTime = now;
          record.ttfb_ms = now - record.start_ms;
        }

        // Record inter-chunk timing for first 50 chunks
        if (chunkTimings.length < 50) {
          chunkTimings.push(round(now - record.start_ms));
        }

        // Detect first content token in SSE stream
        if (!firstTokenTime) {
          const text = new TextDecoder().decode(value);
          if (
            text.includes('"content_block_delta"') ||
            text.includes('"contentBlockDelta"')
          ) {
            firstTokenTime = now;
          }
        }

        controller.enqueue(value);
      } catch (err) {
        record.stream_error = err.message;
        emitRecord(record);
        controller.error(err);
      }
    },
    cancel(reason) {
      record.stream_cancelled = true;
      emitRecord(record);
      reader.cancel(reason);
    },
  });

  // Return a new Response with the wrapped body, preserving everything else
  return new Response(wrappedStream, {
    status: response.status,
    statusText: response.statusText,
    headers: response.headers,
  });
}

// Save original fetch
const originalFetch = globalThis.fetch;

// Wrap globalThis.fetch
globalThis.fetch = async function instrumentedFetch(input, init) {
  const seq = ++callSeq;
  const startMs = performance.now();
  const startWall = Date.now();

  // Extract URL and method
  let url, method;
  if (typeof input === "string") {
    url = input;
    method = init?.method || "GET";
  } else if (input instanceof URL) {
    url = input.toString();
    method = init?.method || "GET";
  } else if (input instanceof Request) {
    url = input.url;
    method = input.method;
  } else {
    url = String(input);
    method = init?.method || "GET";
  }

  const provider = classifyProvider(url);
  const reqHeaders = extractRequestHeaders(
    init?.headers || (input instanceof Request ? input.headers : null),
  );

  // Estimate request body size
  let requestBodySize = null;
  const body = init?.body || (input instanceof Request ? input.body : null);
  if (body) {
    if (typeof body === "string") requestBodySize = body.length;
    else if (body instanceof ArrayBuffer) requestBodySize = body.byteLength;
    else if (body instanceof Uint8Array) requestBodySize = body.byteLength;
  }

  const record = {
    seq,
    timestamp: new Date(startWall).toISOString(),
    method,
    url,
    provider,
    request_headers: reqHeaders,
    request_body_bytes: requestBodySize,
    start_ms: startMs,
    status: null,
    response_headers: {},
    streaming: false,
    total_ms: null,
    ttfb_ms: null,
    error: null,
  };

  try {
    const response = await originalFetch.call(globalThis, input, init);

    const afterFetchMs = performance.now();
    record.ttfb_ms = afterFetchMs - startMs;
    record.status = response.status;
    record.response_headers = extractResponseHeaders(response);

    if (isStreamingResponse(response)) {
      // For streaming: wrap the body to capture chunk timing
      // Record will be emitted when stream completes
      return wrapStreamingBody(response, record);
    } else {
      // Non-streaming: record completes now
      record.total_ms = afterFetchMs - startMs;
      record.streaming = false;
      emitRecord(record);
      return response;
    }
  } catch (err) {
    const errorMs = performance.now();
    record.total_ms = errorMs - startMs;
    record.error = err.message || String(err);
    emitRecord(record);
    throw err;
  }
};

log("Fetch instrumentation loaded — capturing all HTTP calls");
