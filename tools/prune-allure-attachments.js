#!/usr/bin/env node
/* global process, console, require */

const fs = require("fs");
const path = require("path");

const resultsDir = process.argv[2] || process.env.ALLURE_RESULTS_DIR || "./allure-results";

if (String(process.env.DEBUG_HTTP_MODE || "").toLowerCase() === "true") {
  console.log("ℹ️ DEBUG_HTTP_MODE=true — keeping Allure attachments.");
  process.exit(0);
}

if (!fs.existsSync(resultsDir)) {
  console.log(`ℹ️ Allure results directory not found — skipping attachment pruning: ${resultsDir}`);
  process.exit(0);
}

function collectAndRemoveAttachments(node, sources) {
  if (!node || typeof node !== "object") {
    return;
  }

  if (Array.isArray(node.attachments)) {
    for (const attachment of node.attachments) {
      if (attachment && typeof attachment.source === "string") {
        sources.add(attachment.source);
      }
    }
    delete node.attachments;
  }

  if (Array.isArray(node.steps)) {
    for (const step of node.steps) {
      collectAndRemoveAttachments(step, sources);
    }
  }
}

function deleteAttachment(source) {
  const attachmentPath = path.resolve(resultsDir, source);
  const resultsPath = path.resolve(resultsDir);

  if (attachmentPath !== resultsPath && !attachmentPath.startsWith(`${resultsPath}${path.sep}`)) {
    console.warn(`⚠️ Skipping attachment outside results directory: ${source}`);
    return false;
  }

  try {
    fs.unlinkSync(attachmentPath);
    return true;
  } catch (error) {
    if (error.code !== "ENOENT") {
      console.warn(`⚠️ Failed to delete attachment ${source}: ${error.message}`);
    }
    return false;
  }
}

let prunedResults = 0;
let deletedAttachments = 0;

for (const filename of fs.readdirSync(resultsDir)) {
  if (!filename.endsWith("-result.json")) {
    continue;
  }

  const resultPath = path.join(resultsDir, filename);
  let result;

  try {
    result = JSON.parse(fs.readFileSync(resultPath, "utf8"));
  } catch (error) {
    console.warn(`⚠️ Failed to parse ${filename} — leaving it unchanged: ${error.message}`);
    continue;
  }

  if (result.status !== "passed") {
    continue;
  }

  const sources = new Set();
  collectAndRemoveAttachments(result, sources);

  if (sources.size === 0) {
    continue;
  }

  for (const source of sources) {
    if (deleteAttachment(source)) {
      deletedAttachments += 1;
    }
  }

  fs.writeFileSync(resultPath, `${JSON.stringify(result, null, 2)}\n`, "utf8");
  prunedResults += 1;
}

console.log(`✅ Pruned ${deletedAttachments} attachment file(s) from ${prunedResults} passed result(s).`);
