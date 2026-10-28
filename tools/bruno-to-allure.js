#!/usr/bin/env node
/* global require, process, module, __dirname, console */

const fs = require("fs");
const path = require("path");
const { randomUUID, createHash } = require("node:crypto");
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

function getMetaBlock(source) {
  const match = String(source || "").match(/\bmeta\s*\{([\s\S]*?)^\s*\}/m);
  return match ? match[1] : "";
}

function stripBrunoComment(value) {
  return value.replace(/\s+#.*$/, "").trim();
}

function parseBrunoTags(source) {
  const meta = getMetaBlock(source);
  const match = meta.match(/\btags\s*:\s*\[([\s\S]*?)\]/m);
  if (!match) return [];

  return match[1]
    .split(/[,\r\n]+/)
    .map(value => stripBrunoComment(value).replace(/^["']|["']$/g, "").trim())
    .filter(Boolean);
}

function parseBrunoAllureLabels(source) {
  const meta = getMetaBlock(source);
  const labels = [];
  const labelPattern = /^\s*allure\.label\.([A-Za-z0-9_.-]+)\s*:\s*(.*?)\s*$/gm;
  let match;

  while ((match = labelPattern.exec(meta)) !== null) {
    const name = match[1].trim();
    const value = stripBrunoComment(match[2]).replace(/^["']|["']$/g, "").trim();
    if (name && value) labels.push({ name, value });
  }

  return labels;
}

function toAllureLabels({ tags = [], allureLabels = [] } = {}) {
  return [
    ...tags.map(value => ({ name: "tag", value })),
    ...allureLabels
  ];
}

function resolveBrunoSourceFile(test, collectionDir) {
  if (!collectionDir) return undefined;

  const reportPath = normalizeBrunoPath(test);
  if (!reportPath || path.isAbsolute(reportPath)) return undefined;

  const relativePath = reportPath.endsWith(".bru") ? reportPath : `${reportPath}.bru`;
  const collectionRoot = path.resolve(collectionDir);
  const sourceFile = path.resolve(collectionRoot, relativePath);
  const relativeToRoot = path.relative(collectionRoot, sourceFile);
  if (relativeToRoot.startsWith("..") || path.isAbsolute(relativeToRoot)) return undefined;

  return fs.existsSync(sourceFile) ? sourceFile : undefined;
}

function getBrunoSourceLabels(test, collectionDir) {
  const sourceFile = resolveBrunoSourceFile(test, collectionDir);
  if (!sourceFile) return [];

  const source = fs.readFileSync(sourceFile, "utf8");
  return toAllureLabels({
    tags: parseBrunoTags(source),
    allureLabels: parseBrunoAllureLabels(source)
  });
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

function isDebugHttpMode() {
  return String(process.env.DEBUG_HTTP_MODE || "").toLowerCase() === "true";
}

function createSteps(test) {
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

  return { steps, assertionsFailed, failedAssertions };
}

function extractBody(data) {
  if (typeof data === "string") {
    try {
      return JSON.parse(data);
    } catch {
      return data;
    }
  }
  return data || {};
}

function convertBrunoReport(brunoReportPath, allureResultsDir, collectionName, collectionDir) {
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

  // Bruno report often has no per-request timestamp; lay requests out sequentially
  // (ending "now") so retries get strictly increasing start times and Allure picks the last one.
  const durationOf = t => t.response?.responseTime ?? t.duration ?? 0;
  let cursor = Date.now() - results.reduce((sum, t) => sum + durationOf(t) + 1, 0);

  let count = 0;
  for (const test of results) {
    const id = randomUUID();
    const duration = durationOf(test);
    const timestamp = test.timestamp ? new Date(test.timestamp).getTime() : cursor;
    cursor = Math.max(cursor, timestamp) + duration + 1;

    const parts = splitPathParts(test.path);
    const parentSuite = "Backend (Bruno)";
    const suite = collectionName;
    const subSuite = parts.length > 1 ? parts.slice(0, -1).join(" / ") : undefined;
    const packageName = `${collectionName}.${parts.join(".")}`;

    const { steps, assertionsFailed, failedAssertions } = createSteps(test);

    const finalStatus = mapBrunoStatus(test, assertionsFailed);
    const sourceLabels = getBrunoSourceLabels(test, collectionDir);
    if (finalStatus === "failed" || finalStatus === "broken" || isDebugHttpMode()) {
      const requestFilename = `${id}-request.json`;
      const responseFilename = `${id}-response.json`;

      const request = {
        url: test.request?.url || "n/a",
        method: test.request?.method || "n/a",
        headers: test.request?.headers || {},
        requestBody: extractBody(test.request?.data)
      };
      const response = {
        status: test.response?.status || "n/a",
        headers: test.response?.headers || {},
        responseBody: extractBody(test.response?.data)
      };

      fs.writeFileSync(path.join(allureResultsDir, requestFilename), JSON.stringify(request, null, 2), "utf8");
      fs.writeFileSync(path.join(allureResultsDir, responseFilename), JSON.stringify(response, null, 2), "utf8");

      steps.push({
        name: "Request",
        status: "passed",
        stage: "finished",
        attachments: [{ name: "Request", source: requestFilename, type: "application/json" }]
      });

      steps.push({
        name: "Response",
        status: assertionsFailed ? "failed" : "passed",
        stage: "finished",
        attachments: [{ name: "Response", source: responseFilename, type: "application/json" }]
      });
    }

    const allureResult = {
      uuid: id,
      historyId: createHash("md5").update(`${packageName}.${test.name || "test"}`).digest("hex"),
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
        { name: "user", value: process.env.TRIGGER_AUTHOR || "runner" },
        ...sourceLabels
      ].filter(l => l.value !== undefined),
      description: test.description || test.name || "No description provided",
      descriptionHtml: test.description || test.name || "No description provided"
    };

    fs.writeFileSync(path.join(allureResultsDir, `${id}-result.json`), JSON.stringify(allureResult, null, 2));
    count++;
  }

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
  return count;
}

function main() {
  const args = process.argv.slice(2);
  const brunoReportPath = args[0];
  const allureResultsDir = args[1] || path.join(__dirname, "allure-results");
  const collectionName = args[2] || "unknown-collection";
  const collectionDir = args[3];

  try {
    convertBrunoReport(brunoReportPath, allureResultsDir, collectionName, collectionDir);
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
  parseBrunoAllureLabels,
  parseBrunoResults,
  parseBrunoTags,
  toAllureLabels
};
