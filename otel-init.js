/**
 * B3 header injection + OpenTelemetry SDK bootstrap.
 *
 * Intended usage:
 *   export NODE_OPTIONS="--require /scripts/otel-init.js"
 *
 * Two independent concerns are handled here:
 *
 *   1. B3 Header Injection (Phase 1)
 *      Patches http/https/fetch to add X-B3-TraceId, X-B3-SpanId, and
 *      X-B3-Sampled headers to ALL outgoing HTTP requests.  Works without
 *      a collector, without valid-hex trace IDs, and regardless of which
 *      HTTP client the tests use (axios, node-fetch, undici, Playwright
 *      APIRequestContext, etc.).
 *
 *   2. OTel SDK (Phase 2)
 *      Sets up span tracking and OTLP export.  Useful when a collector is
 *      deployed.  Spans include the B3 correlation IDs as resource attributes.
 *
 * This file must be resilient: failures must not prevent tests from running.
 */

/* eslint-disable no-console */

function isTruthy(val) {
  if (val == null) return false;
  const s = String(val).toLowerCase();
  return s === 'true' || s === '1' || s === 'yes';
}

// Allow disabling even if NODE_OPTIONS forces a require.
const otelDisabled = String(process.env.OTEL_ENABLED ?? '').toLowerCase() === 'false';

if (otelDisabled) {
  module.exports = {};
} else {
  try {
    // ═════════════════════════════════════════════════════════════════
    // Freeze B3 values at startup.  Environment variables may be
    // cleared later by clear_sensitive_vars, so we snapshot them now.
    // ═════════════════════════════════════════════════════════════════
    const b3TraceId = process.env.X_B3_TRACE_ID || '';
    const b3SpanId  = process.env.X_B3_SPAN_ID  || '';
    const b3Sampled = process.env.X_B3_SAMPLED   || '1';
    const hasB3     = !!b3TraceId;

    // ═════════════════════════════════════════════════════════════════
    // Phase 1 – B3 header injection
    //
    // We monkey-patch http.request / https.request / globalThis.fetch
    // BEFORE the OTel SDK starts.  This way our wrappers sit between
    // OTel's instrumentation and the real Node.js transport, ensuring
    // the correct env-var B3 values always end up on the wire.
    // ═════════════════════════════════════════════════════════════════
    if (hasB3) {
      const http  = require('http');
      const https = require('https');

      /** Merge B3 headers into a headers object (returns a new object). */
      function withB3(headers) {
        return Object.assign({}, headers, {
          'X-B3-TraceId': b3TraceId,
          'X-B3-SpanId':  b3SpanId,
          'X-B3-Sampled': b3Sampled,
        });
      }

      /**
       * Wrap http.request / http.get (and their https counterparts).
       *
       * The Node.js request() signature is overloaded:
       *   request(url[, options][, callback])
       *   request(options[, callback])
       */
      function wrapRequestFn(original) {
        return function (input, options, callback) {
          if (typeof input === 'string' || input instanceof URL) {
            if (typeof options === 'function') {
              // request(url, callback)
              return original.call(this, input, { headers: withB3({}) }, options);
            }
            // request(url, options[, callback])
            const opts = options || {};
            opts.headers = withB3(opts.headers);
            return original.call(this, input, opts, callback);
          }
          // request(options[, callback])
          const opts = input || {};
          opts.headers = withB3(opts.headers);
          return original.call(this, opts, options);
        };
      }

      http.request  = wrapRequestFn(http.request);
      http.get      = wrapRequestFn(http.get);
      https.request = wrapRequestFn(https.request);
      https.get     = wrapRequestFn(https.get);

      // Patch globalThis.fetch (Node.js 18+ uses undici internally).
      if (typeof globalThis.fetch === 'function') {
        const origFetch = globalThis.fetch;
        globalThis.fetch = function (input, init) {
          init = Object.assign({}, init);
          const h = new Headers(init.headers || {});
          h.set('X-B3-TraceId', b3TraceId);
          h.set('X-B3-SpanId',  b3SpanId);
          h.set('X-B3-Sampled', b3Sampled);
          init.headers = h;
          return origFetch.call(this, input, init);
        };
      }
    }

    // ═════════════════════════════════════════════════════════════════
    // Phase 2 – OpenTelemetry SDK (span tracking / export)
    // ═════════════════════════════════════════════════════════════════
    const { NodeSDK }                   = require('@opentelemetry/sdk-node');
    const { OTLPTraceExporter }         = require('@opentelemetry/exporter-trace-otlp-http');
    const { Resource }                  = require('@opentelemetry/resources');
    const { SemanticResourceAttributes } = require('@opentelemetry/semantic-conventions');
    const { HttpInstrumentation }       = require('@opentelemetry/instrumentation-http');
    const { UndiciInstrumentation }     = require('@opentelemetry/instrumentation-undici');

    const collectorUrl =
      process.env.OTEL_COLLECTOR_ENDPOINT ||
      process.env.OTEL_EXPORTER_OTLP_TRACES_ENDPOINT ||
      (process.env.OTEL_EXPORTER_OTLP_ENDPOINT
        ? String(process.env.OTEL_EXPORTER_OTLP_ENDPOINT).replace(/\/+$/, '') + '/v1/traces'
        : undefined) ||
      'http://otel-collector:4318/v1/traces';

    const resource = new Resource({
      [SemanticResourceAttributes.SERVICE_NAME]:
        process.env.OTEL_SERVICE_NAME || 'atp3-playwright-runner',
      [SemanticResourceAttributes.DEPLOYMENT_ENVIRONMENT]:
        process.env.ENVIRONMENT_NAME,
      'b3.trace_id': b3TraceId,
      'b3.span_id':  b3SpanId,
      'b3.sampled':  b3Sampled,
    });

    // No-op propagator – B3 headers are injected manually in Phase 1.
    // This prevents OTel from adding 'traceparent' or 'b3' headers with
    // random trace IDs that would conflict with our env-var values.
    const noopPropagator = {
      inject() {},
      extract(context) { return context; },
      fields() { return []; },
    };

    const sdk = new NodeSDK({
      resource,
      traceExporter: new OTLPTraceExporter({ url: collectorUrl }),
      textMapPropagator: noopPropagator,
      instrumentations: [
        new HttpInstrumentation(),
        new UndiciInstrumentation(),
      ],
    });

    // Start SDK synchronously (NodeSDK.start() is sync in v0.54+).
    let started = false;
    try {
      sdk.start();
      started = true;
    } catch (startErr) {
      console.error('⚠️ OpenTelemetry failed to start; continuing without tracing.', startErr);
    }

    if (started) {
      if (isTruthy(process.env.OTEL_LOG_STARTUP ?? 'true')) {
        console.log(`✅ OpenTelemetry started (exporter: ${collectorUrl})`);
        if (hasB3) {
          console.log(`✅ B3 headers will be injected (traceId: ${b3TraceId})`);
        }
      }

      const shutdown = () => {
        sdk
          .shutdown()
          .catch((err) => console.error('⚠️ OpenTelemetry shutdown error', err))
          .finally(() => process.exit(0));
      };

      // Best-effort flush on termination.
      process.once('SIGTERM', shutdown);
      process.once('SIGINT', shutdown);
      process.once('beforeExit', () => {
        // Don't force exit; just attempt to flush.
        sdk.shutdown().catch(() => undefined);
      });
    }

    module.exports = {};
  } catch (err) {
    console.error('⚠️ OpenTelemetry bootstrap unavailable; continuing without tracing.', err);
    module.exports = {};
  }
}
