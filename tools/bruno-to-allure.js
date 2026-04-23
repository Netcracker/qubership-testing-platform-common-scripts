#!/usr/bin/env node
/* global require, process, __dirname, console */

const fs = require("fs");
const path = require("path");
const { randomUUID } = require("node:crypto");
const { URL } = require("node:url");

const args = process.argv.slice(2);
const brunoReportPath = args[0];
const allureResultsDir = args[1] || path.join(__dirname, "allure-results");
const collectionName = args[2] || "unknown-collection";

// ensure dir
if (!fs.existsSync(allureResultsDir)) fs.mkdirSync(allureResultsDir, { recursive: true });

// split Bruno "path" into folder parts (preserve every level)
function splitPathParts(requestPath) {
  if (!requestPath) return ["uncategorized"];
  return requestPath.replace(/\/+|\\+/g, "/").split("/").map(p => p.trim()).filter(Boolean);
}

// Create steps: Request/Response + Assertion steps
function createSteps(test, id) {
  const requestFilename = `${id}-request.json`;
  const requestHeadersFilename = `${id}-request-headers.json`;
  const responseFilename = `${id}-response.json`;
  const responseHeadersFilename = `${id}-response-headers.json`;

  const requestHeaders = test.request?.headers || {};
  const requestBody = test.request?.data !== undefined
    ? (typeof test.request.data === "string" ? test.request.data : JSON.stringify(test.request.data, null, 2))
    : "/* no request body */";

  fs.writeFileSync(path.join(allureResultsDir, requestHeadersFilename), JSON.stringify(requestHeaders, null, 2));
  fs.writeFileSync(path.join(allureResultsDir, requestFilename), requestBody, "utf8");

  const response = test.response || {};
  const responseHeaders = response.headers || {};
  const responseBody = response.data !== undefined
    ? (typeof response.data === "string" ? response.data : JSON.stringify(response.data, null, 2))
    : "/* no response body */";

  fs.writeFileSync(path.join(allureResultsDir, responseHeadersFilename), JSON.stringify(responseHeaders, null, 2));
  fs.writeFileSync(path.join(allureResultsDir, responseFilename), responseBody, "utf8");

  const steps = [];

    // --- Assertions ---
  const allAssertions = [
    ...(test.preRequestTestResults || []),
    ...(test.testResults || []),
    ...(test.postResponseTestResults || [])
  ];

  let assertionsFailed = false;
  const failedAssertions = [];

  if (allAssertions.length > 0) {
    for (const ar of allAssertions) {
      const isFail = String(ar.status).toLowerCase() !== "pass";
      if (isFail) {
        assertionsFailed = true;
        failedAssertions.push(ar);
      }

      steps.push({
        name: ar.description || "Assertion",
        status: isFail ? "failed" : "passed",
        stage: "finished",
        statusDetails: isFail ? {
              message: ar.description || "Assertion failed",
              trace: ar.error || "No description"
        }: undefined
      });
    }
  }

  // Request Headers step
  steps.push({
    name: "Request Headers",
    status: "passed",
    stage: "finished",
    attachments: [{ name: "Request Headers", source: requestHeadersFilename, type: "application/json" }],
    parameters: Object.entries(requestHeaders).map(([k, v]) => ({ name: k, value: String(v) }))
  });

  // Request Body step
  steps.push({
    name: "Request Body",
    status: "passed",
    stage: "finished",
    attachments: [{ name: "Request Body", source: requestFilename, type: "application/json" }]
  });

  // Response Headers step
  steps.push({
    name: "Response Headers",
    status: "passed",
    stage: "finished",
    attachments: [{ name: "Response Headers", source: responseHeadersFilename, type: "application/json" }],
    parameters: Object.entries(responseHeaders).map(([k, v]) => ({ name: k, value: String(v) }))
  });

  // Response Body step
  steps.push({
    name: "Response Body",
    status: assertionsFailed ? "failed" : "passed",
    stage: "finished",
    attachments: [{ name: "Response Body", source: responseFilename, type: "application/json" }]
  });

  return { steps, assertionsFailed, failedAssertions };
}

try {
  const raw = fs.readFileSync(brunoReportPath, "utf8");
  const brunoReport = JSON.parse(raw);
  let results = [];

  if (Array.isArray(brunoReport)) {
    if (brunoReport.every(item => item && Array.isArray(item.results))) {
      results = brunoReport.flatMap(item => item.results);
    } else {
      results = brunoReport;
    }
  } else if (brunoReport && Array.isArray(brunoReport.results)) {
    results = brunoReport.results;
  } else {
    throw new Error("Invalid Bruno report format");
  }

  const children = [];
  for (const test of results) {
    const id = randomUUID();
    const timestamp = test.timestamp ? new Date(test.timestamp).getTime() : Date.now();
    const duration = test.response?.responseTime ?? test.duration ?? 0;

    const parts = splitPathParts(test.path);

    const parentSuite = "Backend (Bruno)";
    const suite = collectionName;
    const subSuite = parts.length > 1 ? parts.slice(0, -1).join(" / ") : undefined;
    const packageName = `${collectionName}.${parts.join(".")}`;

    const { steps, assertionsFailed, failedAssertions } = createSteps(test, id, timestamp, duration);

    const initialStatus =
      test.status === "pass" ? "passed" : "failed";

    const finalStatus = assertionsFailed ? "failed" : initialStatus;

    const allureResult = {
      uuid: id,
      historyId: randomUUID(),
      name: test.name || `${test.request?.method || "GET"} ${test.request?.url || ""}`,
      fullName: `${packageName}.${test.name || "test"}`,
      status: finalStatus,
      statusDetails: finalStatus === "failed" ? {
        message: failedAssertions?.map(r =>
          `${r.description || "Test"}: ${r.error || ''}`
        ).join("\n") || "Test failed",
        trace: failedAssertions?.map(r =>
          `Status: ${r.status || "Failed"}\nDescription: ${r.description || "No description"}\nError: ${r.error || "No details"}\nActual: ${r.actual}\nExpected: ${r.expected}`
        ).join("\n") || "No details"
      } : undefined,
      steps: steps,
      parameters: [
        { name: "Method", value: test.request?.method || "GET" },
        { name: "URL", value: test.request?.url || "n/a" },
        { name: "Response Code", value: test.response?.status || "n/a" }
      ],
      start: timestamp,
      stop: timestamp + duration,
      labels: [
        { name: "parentSuite", value: parentSuite },
        { name: "suite", value: suite },
        ...(subSuite ? [{ name: "subSuite", value: subSuite }] : []),
        { name: "package", value: packageName },
        { name: "host", value: (() => { try { return new URL(test.request?.url).host } catch { return "n/a"; } })() },
        { name: "framework", value: "bruno" },
        { name: "language", value: "javascript" }
      ].filter(l => l.value !== undefined),
      description: test.description || test.name || "No description provided",
      descriptionHtml: test.description || test.name || "No description provided"
    };

    fs.writeFileSync(path.join(allureResultsDir, `${id}-result.json`), JSON.stringify(allureResult, null, 2));
    children.push(id);
  }

  const container = {
    uuid: randomUUID(),
    children: children,
    befores: [],
    afters: [],
    start: Date.now(),
    stop: Date.now()
  };
  fs.writeFileSync(
    path.join(allureResultsDir, `${randomUUID()}-container.json`),
    JSON.stringify(container, null, 2)
  );
  console.log(`✅ Successfully converted Bruno report to Allure format. Results saved in: ${allureResultsDir}`);
} catch (error) {
  console.error(`❌ Error processing Bruno report: ${error.message}`);
  process.exit(1);
}

