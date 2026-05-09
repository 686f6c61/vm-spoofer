#!/usr/bin/env node
"use strict";

const os = require("os");
const banned = require("./banned-programs");

const rawArgs = process.argv.slice(2);

function valueOf(name, fallback = "") {
  const idx = rawArgs.indexOf(name);
  if (idx === -1) return fallback;
  return rawArgs[idx + 1] || fallback;
}

function hasFlag(name) {
  return rawArgs.includes(name);
}

function help() {
  console.log("Usage: node process-watch.js --banned-programs <file> [options]");
  console.log("");
  console.log("Options:");
  console.log("  --banned-platform <auto|windows|macos|linux|all>  Platform slice for structured catalogs");
  console.log("  --duration <seconds>                              Watch window (default: 60)");
  console.log("  --interval <seconds>                              Poll interval (default: 2)");
  console.log("  --strict-processes                                Fail on VM-looking process names");
  console.log("  --include-local-details                           Print hostname and local details in output");
  console.log("  --help                                            Show help");
  console.log("");
  console.log("Run this inside the VM, then open the software you want to test.");
  console.log("It uses systeminformation.processes(), matching the observed client behavior.");
}

if (hasFlag("--help") || hasFlag("-h")) {
  help();
  process.exit(0);
}

let si;
try {
  si = require("systeminformation");
} catch (error) {
  console.error("Missing dependency: systeminformation");
  console.error("Install it inside the VM with: npm install systeminformation@5.31.6");
  process.exit(2);
}

const bannedProgramsPath = valueOf("--banned-programs");
const bannedPlatform = valueOf("--banned-platform", "auto");
const duration = Math.max(5, Math.min(Number(valueOf("--duration", "60")), 1800));
const interval = Math.max(1, Math.min(Number(valueOf("--interval", "2")), 30));
const strictProcesses = hasFlag("--strict-processes");
const includeLocalDetails = hasFlag("--include-local-details");
const notes = [];

if (!bannedProgramsPath) {
  console.error("Missing required option: --banned-programs <file>");
  process.exit(2);
}

const bannedPrograms = banned.loadBannedPrograms(bannedProgramsPath, notes, bannedPlatform);

if (bannedPrograms.length === 0) {
  console.error("No bannedPrograms entries were loaded; dynamic process validation would be meaningless.");
  for (const note of notes) console.error(`- ${note}`);
  process.exit(2);
}

const VM_PROCESS_PATTERNS = [
  /virtualbox/i,
  /\bvbox/i,
  /vmware/i,
  /\bqemu\b/i,
  /\bkvm\b/i,
  /parallels/i,
];

function hasVmProcessText(processInfo) {
  const text = banned.processText(processInfo);
  return VM_PROCESS_PATTERNS.some((pattern) => pattern.test(text));
}

function processLabel(processInfo) {
  return [
    processInfo.pid ? `pid=${processInfo.pid}` : "",
    processInfo.name || processInfo.proc || "unknown",
    processInfo.path ? `path=${processInfo.path}` : "",
  ].filter(Boolean).join(" ");
}

async function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function listProcesses() {
  try {
    const processes = await si.processes();
    return processes.list || [];
  } catch (error) {
    const message = error && error.message ? error.message : String(error);
    notes.push(`systeminformation.processes failed: ${message}`);
    return [];
  }
}

async function main() {
  console.log("[PROCESS WATCH]");
  console.log(`platform         ${process.platform}`);
  console.log(`host             ${includeLocalDetails ? os.hostname() : "<redacted>"}`);
  console.log(`duration         ${duration}s`);
  console.log(`interval         ${interval}s`);
  console.log(`bannedPrograms   ${bannedPrograms.length}`);
  console.log(`strictProcesses  ${strictProcesses ? "yes" : "no"}`);
  console.log("");
  console.log("Open the target analysis software inside the VM now.");
  console.log("");

  const startedAt = Date.now();
  const bannedMatches = new Map();
  const vmProcessNotes = new Map();
  let samples = 0;

  while (Date.now() - startedAt < duration * 1000) {
    samples += 1;
    const processes = await listProcesses();
    for (const processInfo of processes) {
      const label = processLabel(processInfo);
      const matched = banned.findBannedProgramMatch(processInfo, bannedPrograms);
      if (matched) {
        const key = `${matched}|${label}`;
        const current = bannedMatches.get(key) || {
          matched,
          label,
          count: 0,
          firstSeen: new Date().toISOString(),
          lastSeen: "",
        };
        current.count += 1;
        current.lastSeen = new Date().toISOString();
        bannedMatches.set(key, current);
      }

      if (strictProcesses && hasVmProcessText(processInfo)) {
        const key = label;
        const current = vmProcessNotes.get(key) || {
          label,
          count: 0,
          firstSeen: new Date().toISOString(),
          lastSeen: "",
        };
        current.count += 1;
        current.lastSeen = new Date().toISOString();
        vmProcessNotes.set(key, current);
      }
    }

    process.stdout.write(".");
    await sleep(interval * 1000);
  }

  console.log("\n");
  console.log("[SUMMARY]");
  console.log(`samples          ${samples}`);
  console.log(`bannedMatches    ${bannedMatches.size}`);
  console.log(`vmProcessMatches ${vmProcessNotes.size}`);

  if (bannedMatches.size > 0) {
    console.log("\n[BANNED PROGRAM MATCHES]");
    for (const match of bannedMatches.values()) {
      console.log(`- ${match.matched}: ${match.label} count=${match.count} first=${match.firstSeen} last=${match.lastSeen}`);
    }
  }

  if (vmProcessNotes.size > 0) {
    console.log("\n[VM PROCESS MATCHES]");
    for (const match of vmProcessNotes.values()) {
      console.log(`- ${match.label} count=${match.count} first=${match.firstSeen} last=${match.lastSeen}`);
    }
  }

  if (notes.length > 0) {
    console.log("\n[NOTES]");
    for (const note of notes) console.log(`- ${note}`);
  }

  if (bannedMatches.size > 0 || vmProcessNotes.size > 0) {
    console.log("\nRESULT=FAIL");
    process.exit(1);
  }

  console.log("\nRESULT=PASS");
}

main().catch((error) => {
  console.error(error && error.stack ? error.stack : error);
  process.exit(2);
});
