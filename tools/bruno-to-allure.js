#!/usr/bin/env node
/* global require, process, module, __dirname, console */

const fs = require("fs");
const path = require("path");
const { randomUUID } = require("node:crypto");
const { URL } = require("node:url");

function splitPathParts(requestPath) {
  if (!requestPath) return ["uncategorized"];
  return requestPath.replace(/\/+|\\+/g, "/").split("/").map(p => p.trim()).filter(Boolean);
}

function normalizeBrunoPath(test) {
  return String(test.path || test.filename || test.file || test.name || "")
    .replace(/\\/g, "/")
    .replace(/^\/+/, "");
}

function isEnvironmentOrMetaFile(test) {
  const bruPath = normalizeBrunoPath(test);
  const parts = splitPathParts(bruPath);
  if (parts.some(part => part.toLowerCase() === "environments")) {
    return true;
  }
  const last = (parts[parts.length - 1] || "").toLowerCase();
  if (last === "collection.bru" || last === "folder.bru") {
    return true;
  }
  const name = String(test.name || "").toLowerCase();
  return name === "collection.bru" || name === "folder.bru" || name === "collection";
}

function parseBrunoResults(brunoReport) {
  if (Array.isArray(brunoReport)) {
    if (brunoReport.every(item => item && Array.isArray(item.results))) {
      return brunoReport.flatMap(item => item.results);
    }
    return brunoReport;
  }
  if (brunoReport && Array.isArray(brunoReport.results)) {
    return brunoReport.results;
  }
  throw new Error("Invalid Bruno report format");
}

function mapBrunoStatus(test, assertionsFailed) {
  const raw = String(test.status || "").toLowerCase();
  const responseStatus = String(test.response?.status ?? "").toLowerCase();
  if (raw === "skip" || raw === "skipped" || responseStatus === "skipped") {
    return "skipped";
  }
  if (assertionsFailed) {
    return "failed";
  }
  if (raw === "pass" || raw === "passed") {
    return "passed";
  }
  return "failed";
}

function createSteps(test, id, allureResultsDir) {
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
        } : undefined
      });
    }
  }

  steps.push({
    name: "Request Headers",
    status: "passed",
    stage: "finished",
    attachments: [{ name: "Request Headers", source: requestHeadersFilename, type: "application/json" }],
    parameters: Object.entries(requestHeaders).map(([k, v]) => ({ name: k, value: String(v) }))
  });

  steps.push({
    name: "Request Body",
    status: "passed",
    stage: "finished",
    attachments: [{ name: "Request Body", source: requestFilename, type: "application/json" }]
  });

  steps.push({
    name: "Response Headers",
    status: "passed",
    stage: "finished",
    attachments: [{ name: "Response Headers", source: responseHeadersFilename, type: "application/json" }],
    parameters: Object.entries(responseHeaders).map(([k, v]) => ({ name: k, value: String(v) }))
  });

  steps.push({
    name: "Response Body",
    status: assertionsFailed ? "failed" : "passed",
    stage: "finished",
    attachments: [{ name: "Response Body", source: responseFilename, type: "application/json" }]
  });

  return { steps, assertionsFailed, failedAssertions };
}

function convertBrunoReport(brunoReportPath, allureResultsDir, collectionName) {
  if (!fs.existsSync(allureResultsDir)) {
    fs.mkdirSync(allureResultsDir, { recursive: true });
  }

  const raw = fs.readFileSync(brunoReportPath, "utf8");
  const brunoReport = JSON.parse(raw);
  const results = parseBrunoResults(brunoReport).filter(test => !isEnvironmentOrMetaFile(test));

  if (results.length === 0) {
    console.log(`ℹ️ No reportable Bruno requests in ${collectionName} — skipping Allure conversion`);
    return 0;
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

    const { steps, assertionsFailed, failedAssertions } = createSteps(test, id, allureResultsDir);
    const finalStatus = mapBrunoStatus(test, assertionsFailed);

    const allureResult = {
      uuid: id,
      historyId: randomUUID(),
      name: test.name || `${test.request?.method || "GET"} ${test.request?.url || ""}`,
      fullName: `${packageName}.${test.name || "test"}`,
      status: finalStatus,
      statusDetails: finalStatus === "failed" ? {
        message: failedAssertions?.map(r =>
          `${r.description || "Test"}: ${r.error || ""}`
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
        { name: "host", value: (() => { try { return new URL(test.request?.url).host; } catch { return "n/a"; } })() },
        { name: "framework", value: "bruno" },
        { name: "language", value: "javascript" },
        { name: "user", value: process.env.TRIGGER_AUTHOR || "runner" }
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

  const triggerAuthor = (process.env.TRIGGER_AUTHOR || "runner").trim();
  const executor = {
    name: triggerAuthor,
    type: "atp3-python-runner"
  };
  fs.writeFileSync(
    path.join(allureResultsDir, "executor.json"),
    JSON.stringify(executor, null, 2),
    "utf8"
  );

  console.log(`✅ Successfully converted Bruno report to Allure format. Results saved in: ${allureResultsDir}`);
  return children.length;
}

function main() {
  const args = process.argv.slice(2);
  const brunoReportPath = args[0];
  const allureResultsDir = args[1] || path.join(__dirname, "allure-results");
  const collectionName = args[2] || "unknown-collection";

  try {
    convertBrunoReport(brunoReportPath, allureResultsDir, collectionName);
  } catch (error) {
    console.error(`❌ Error processing Bruno report: ${error.message}`);
    process.exit(1);
  }
}

if (require.main === module) {
  main();
}

module.exports = {
  convertBrunoReport,
  isEnvironmentOrMetaFile,
  mapBrunoStatus,
  parseBrunoResults
};
