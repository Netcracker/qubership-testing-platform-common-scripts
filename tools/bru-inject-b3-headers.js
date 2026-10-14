#!/usr/bin/env node
/* global require, process, console */
// bru-inject-b3-headers.js — idempotently adds a collection-level pre-request
// script that stamps every request with B3 trace/span headers.
//
// Usage: node bru-inject-b3-headers.js <collection-dir>
//
// Runs once per discovered Bruno collection, against the collection.bru file
// inside the temporary clone (never the user's source repository). The
// injected script reads the trace id from the X_B3_TRACE_ID runtime variable
// (set per collection run via `bru run --env-var`, see collection-runner.sh)
// and generates a fresh span id per request with Math.random() — bru run's
// default "safe" sandbox executes pre-request scripts in QuickJS, which has
// no require('crypto'); a span id is a correlation id, not a security token,
// so Math.random() is an adequate source here.

const fs = require('fs');
const path = require('path');
const { collectionBruToJson, jsonToCollectionBru } = require('@usebruno/lang');

const MARKER = '__ATP_B3_HEADERS__';

const SNIPPET = `// ${MARKER} — auto-injected, do not edit by hand
(() => {
  const traceId = bru.getEnvVar('X_B3_TRACE_ID');
  if (!traceId) { return; }
  const spanId = Array.from({ length: 16 }, () => Math.floor(Math.random() * 16).toString(16)).join('');
  req.setHeader('X-B3-TraceId', traceId);
  req.setHeader('X-B3-SpanId', spanId);
  req.setHeader('X-B3-Sampled', '1');
})();`;

function main() {
  const collectionDir = process.argv[2];
  if (!collectionDir) {
    console.error('Usage: bru-inject-b3-headers.js <collection-dir>');
    process.exit(1);
  }

  const bruPath = path.join(collectionDir, 'collection.bru');
  if (!fs.existsSync(bruPath)) {
    console.warn(`⚠️ collection.bru not found in ${collectionDir} — skipping B3 header injection`);
    return;
  }

  const raw = fs.readFileSync(bruPath, 'utf8');
  const json = collectionBruToJson(raw);

  const existingScript = (json.script && json.script.req) || '';
  if (existingScript.includes(MARKER)) {
    return; // already injected in a previous run
  }

  json.script = json.script || {};
  json.script.req = existingScript ? `${existingScript}\n\n${SNIPPET}` : SNIPPET;

  fs.writeFileSync(bruPath, jsonToCollectionBru(json), 'utf8');
  console.log(`✅ B3 header pre-request script injected into ${bruPath}`);
}

try {
  main();
} catch (err) {
  console.warn(`⚠️ Failed to inject B3 headers into collection.bru — continuing without them: ${err.message}`);
}
