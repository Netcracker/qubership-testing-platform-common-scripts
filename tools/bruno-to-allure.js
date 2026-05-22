#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const { randomUUID } = require("node:crypto");
const { URL } = require("node:url");

const JIRA_BASE_URL = process.env.JIRA_URL || "https://tms.netcracker.com/browse/";

const args = process.argv.slice(2);
const brunoReportPath = args[0];
const allureResultsDir = args[1] || path.join(__dirname, "allure-results");
const collectionName = args[2] || "unknown-collection";

if (!fs.existsSync(allureResultsDir)) fs.mkdirSync(allureResultsDir, { recursive: true });

function splitPathParts(pathStr) {
  if (!pathStr) return [];
  return String(pathStr).replace(/\/+|\\+/g, "/").split("/").map(p => p.trim()).filter(Boolean);
}

function createSteps(test, id) {
  const requestFilename = `${id}-request.json`;
  const requestHeadersFilename = `${id}-request-headers.json`;
  const responseFilename = `${id}-response.json`;
  const responseHeadersFilename = `${id}-response-headers.json`;

  const requestHeaders = test.request?.headers || {};
  const requestBody = test.request?.data !== undefined
    ? (typeof test.request.data === "string" ? test.request.data : JSON.stringify(test.request.data, null, 2))
    : "";

  fs.writeFileSync(path.join(allureResultsDir, requestHeadersFilename), JSON.stringify(requestHeaders, null, 2));
  fs.writeFileSync(path.join(allureResultsDir, requestFilename), requestBody, "utf8");

  const response = test.response || {};
  const responseHeaders = response.headers || {};
  const responseBody = response.data !== undefined
    ? (typeof response.data === "string" ? response.data : JSON.stringify(response.data, null, 2))
    : "";

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
        }: undefined
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

  const groupedResults = {};
  for (const test of results) {
    const folderStr = test.folder || test.path || "Root";
    if (!groupedResults[folderStr]) {
      groupedResults[folderStr] = [];
    }
    groupedResults[folderStr].push(test);
  }

  const children = [];

  for (const [folderStr, testsInFolder] of Object.entries(groupedResults)) {
    const testCaseId = randomUUID();
    let testCaseStart = Infinity;
    let testCaseStop = 0;
    let testCaseStatus = "passed";
    const testCaseFailedAssertions = [];
    const testCaseSteps = [];

    const folderParts = splitPathParts(folderStr);
    
    const parentSuite = "Backend (Bruno)";
    let suite = collectionName;
    let subSuite = undefined;
    let testCaseName = "Unnamed";

    if (folderParts.length === 0) {
      suite = collectionName;
      testCaseName = "Root";
    } else if (folderParts.length === 1) {
      suite = collectionName;
      testCaseName = folderParts[0];
    } else if (folderParts.length === 2) {
      suite = folderParts[0];
      testCaseName = folderParts[1];
    } else if (folderParts.length === 3) {
      suite = folderParts[0];
      subSuite = folderParts[1];
      testCaseName = folderParts[2];
    } else if (folderParts.length > 3) {
      suite = folderParts[0];
      subSuite = folderParts.slice(1, -1).join(" / ");
      testCaseName = folderParts[folderParts.length - 1];
    }

    const packageName = folderParts.length > 0 ? folderParts.join(".") : collectionName;

    const rawTickets = folderStr.match(/[a-zA-Z]+-\d+/g) || [];
    const uniqueTickets = [...new Set(rawTickets.map(t => t.toUpperCase()))];
    const testCaseLinks = uniqueTickets.map(t => ({
      name: t,
      url: `${JIRA_BASE_URL}${t}`,
      type: "tms"
    }));

    for (const test of testsInFolder) {
      const requestId = randomUUID();
      const timestamp = test.timestamp ? new Date(test.timestamp).getTime() : Date.now();
      const duration = test.response?.responseTime ?? test.duration ?? 0;

      if (timestamp < testCaseStart) testCaseStart = timestamp;
      if (timestamp + duration > testCaseStop) testCaseStop = timestamp + duration;

      const { steps, assertionsFailed, failedAssertions } = createSteps(test, requestId);

      const initialStatus = test.status === "pass" ? "passed" : "failed";
      const requestStatus = assertionsFailed ? "failed" : initialStatus;

      if (requestStatus === "failed") {
        testCaseStatus = "failed";
        if (failedAssertions) testCaseFailedAssertions.push(...failedAssertions);
      }

      testCaseSteps.push({
        name: test.name || `${test.request?.method || "GET"} ${test.request?.url || ""}`,
        status: requestStatus,
        stage: "finished",
        start: timestamp,
        stop: timestamp + duration,
        steps: steps,
        parameters: [
          { name: "Method", value: test.request?.method || "GET" },
          { name: "URL", value: test.request?.url || "n/a" },
          { name: "Response Code", value: test.response?.status || "n/a" }
        ]
      });
    }

    if (testCaseStart === Infinity) testCaseStart = Date.now();
    if (testCaseStop === 0) testCaseStop = Date.now();

    const allureResult = {
      uuid: testCaseId,
      historyId: randomUUID(),
      name: testCaseName,
      fullName: `${packageName}`,
      status: testCaseStatus,
      statusDetails: testCaseStatus === "failed" ? {
        message: testCaseFailedAssertions.length > 0
            ? testCaseFailedAssertions.map(r => `${r.description || "Test"}: ${r.error || ''}`).join("\n") 
            : "One or more requests failed in this folder",
        trace: testCaseFailedAssertions.length > 0
            ? testCaseFailedAssertions.map(r => `Status: ${r.status || "Failed"}\nDescription: ${r.description || "No description"}\nError: ${r.error || "No details"}\nActual: ${r.actual}\nExpected: ${r.expected}`).join("\n") 
            : "No details"
      } : undefined,
      steps: testCaseSteps,
      links: testCaseLinks,
      start: testCaseStart,
      stop: testCaseStop,
      labels: [
        { name: "parentSuite", value: parentSuite },
        { name: "suite", value: suite },
        ...(subSuite ? [{ name: "subSuite", value: subSuite }] : []),
        { name: "package", value: packageName },
        { name: "framework", value: "bruno" },
        { name: "language", value: "javascript" },
        ...uniqueTickets.map(t => ({ name: "jiraTicketId", value: t }))
      ].filter(l => l.value !== undefined)
    };

    fs.writeFileSync(path.join(allureResultsDir, `${testCaseId}-result.json`), JSON.stringify(allureResult, null, 2));
    children.push(testCaseId);
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