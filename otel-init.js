/**
 * OpenTelemetry SDK bootstrap.
 *
 * Intended usage:
 *   export NODE_OPTIONS="--require /scripts/otel-init.js"
 *
 * This file must be resilient: failures should not prevent tests from running.
 */

/* eslint-disable no-console */

function isTruthy(val) {
  if (val == null) return false;
  return String(val).toLowerCase() === 'true' || String(val) === '1' || String(val).toLowerCase() === 'yes';
}

// Allow disabling even if NODE_OPTIONS forces a require.
const otelDisabled = String(process.env.OTEL_ENABLED ?? '').toLowerCase() === 'false';

if (otelDisabled) {
  module.exports = {};
} else {
  try {
  const { NodeSDK } = require('@opentelemetry/sdk-node');
  const { B3Propagator } = require('@opentelemetry/propagator-b3');
  const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-http');
  const { Resource } = require('@opentelemetry/resources');
  const { SemanticResourceAttributes } = require('@opentelemetry/semantic-conventions');
  const { HttpInstrumentation } = require('@opentelemetry/instrumentation-http');
  const { UndiciInstrumentation } = require('@opentelemetry/instrumentation-undici');

  // Prefer an explicit runner-specific variable, but also respect standard OTEL env vars if present.
  const collectorUrl =
    process.env.OTEL_COLLECTOR_ENDPOINT ||
    process.env.OTEL_EXPORTER_OTLP_TRACES_ENDPOINT ||
    (process.env.OTEL_EXPORTER_OTLP_ENDPOINT
      ? String(process.env.OTEL_EXPORTER_OTLP_ENDPOINT).replace(/\/+$/, '') + '/v1/traces'
      : undefined) ||
    'http://otel-collector:4318/v1/traces';

  const resource = new Resource({
    [SemanticResourceAttributes.SERVICE_NAME]: process.env.OTEL_SERVICE_NAME || 'atp3-playwright-runner',
    [SemanticResourceAttributes.DEPLOYMENT_ENVIRONMENT]: process.env.ENVIRONMENT_NAME,
    'b3.trace_id': process.env.X_B3_TRACE_ID,
    'b3.span_id': process.env.X_B3_SPAN_ID,
    'b3.sampled': process.env.X_B3_SAMPLED,
  });

  const sdk = new NodeSDK({
    resource,
    traceExporter: new OTLPTraceExporter({ url: collectorUrl }),
    textMapPropagator: new B3Propagator(),
    instrumentations: [
      new HttpInstrumentation(),    // instruments Node.js http/https (used by axios)
      new UndiciInstrumentation(),  // instruments undici / global fetch
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

