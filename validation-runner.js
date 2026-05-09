#!/usr/bin/env node
"use strict";

const childProcess = require("child_process");
const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");

const args = process.argv.slice(2);

function valueOf(name, fallback = "") {
  const idx = args.indexOf(name);
  if (idx === -1) return fallback;
  return args[idx + 1] || fallback;
}

function hasFlag(name) {
  return args.includes(name);
}

function help() {
  console.log("Usage: node validation-runner.js [options]");
  console.log("");
  console.log("Options:");
  console.log("  --out <dir>                    Report output directory (default: validation-runs/<timestamp>)");
  console.log("  --profile <file>               Optional selected profile/config JSON to copy into the bundle");
  console.log("  --platform <name>              Override platform label");
  console.log("  --advanced                     Run out-of-scope proctoring diagnostics and attach residual indicators");
  console.log("  --skip-advanced                Compatibility flag; keeps advanced checks disabled");
  console.log("  --require-advanced-pass        Treat out-of-scope diagnostic findings as delivery failure");
  console.log("  --run-input-hooks              Run input-hook-check.js");
  console.log("  --hook-provider <provider>     auto|uiohook-napi|keyspy (default: auto)");
  console.log("  --hook-duration <seconds>      Input hook test duration (default: 15)");
  console.log("  --yes                          Pass consent flag to input-hook-check.js");
  console.log("  --run-process-watch            Run process-watch.js for dynamic bannedPrograms validation");
  console.log("  --process-watch-duration <sec> Process watch duration (default: 60)");
  console.log("  --process-watch-interval <sec> Process watch poll interval (default: 2)");
  console.log("  --banned-programs <file>       Banned process list passed to check.js");
  console.log("  --banned-platform <platform>   auto|windows|macos|linux|all for structured catalogs");
  console.log("  --strict-processes             Fail on VM-looking process names, not only banned matches");
  console.log("  --broad-hardware               Also run extra hardware calls not observed in the client bundle");
  console.log("  --client-command <command>     Optional exact client detector command to run");
  console.log("  --include-local-details        Keep absolute paths and hostnames in the generated evidence");
  console.log("  --help                         Show this help");
}

if (hasFlag("--help") || hasFlag("-h")) {
  help();
  process.exit(0);
}

const repoDir = __dirname;
const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
const outDir = path.resolve(valueOf("--out", path.join(repoDir, "validation-runs", timestamp)));
const platformLabel = valueOf("--platform", process.platform);
const profilePath = valueOf("--profile");
const runAdvanced = hasFlag("--advanced") && !hasFlag("--skip-advanced");
const requireAdvancedPass = hasFlag("--require-advanced-pass");
const runInputHooks = hasFlag("--run-input-hooks");
const hookProvider = valueOf("--hook-provider", "auto");
const hookDuration = valueOf("--hook-duration", "15");
const consentYes = hasFlag("--yes");
const runProcessWatch = hasFlag("--run-process-watch");
const processWatchDuration = valueOf("--process-watch-duration", "60");
const processWatchInterval = valueOf("--process-watch-interval", "2");
const bannedProgramsPath = valueOf("--banned-programs");
const bannedPlatform = valueOf("--banned-platform", "auto");
const strictProcesses = hasFlag("--strict-processes");
const broadHardware = hasFlag("--broad-hardware");
const clientCommand = valueOf("--client-command");
const includeLocalDetails = hasFlag("--include-local-details");

if (runProcessWatch && !bannedProgramsPath) {
  console.error("--run-process-watch requires --banned-programs <file>");
  process.exit(2);
}

function ensureDir(dirPath) {
  fs.mkdirSync(dirPath, { recursive: true });
}

function sha256(filePath) {
  const hash = crypto.createHash("sha256");
  hash.update(fs.readFileSync(filePath));
  return hash.digest("hex");
}

function packageVersion(name) {
  try {
    const packageJson = require.resolve(`${name}/package.json`, { paths: [repoDir, process.cwd()] });
    return JSON.parse(fs.readFileSync(packageJson, "utf8")).version || null;
  } catch (error) {
    return null;
  }
}

function writeJson(filePath, value) {
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`);
}

function writeText(filePath, value) {
  fs.writeFileSync(filePath, value);
}

function escapeRegExp(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function redactLocalText(value) {
  if (includeLocalDetails || value === null || value === undefined) return value;

  let redacted = String(value);
  const home = os.homedir();
  if (home && home !== "/") {
    redacted = redacted.replace(new RegExp(escapeRegExp(home), "g"), "<home>");
  }

  redacted = redacted
    .replace(/\/home\/[^/\s"'`]+/g, "/home/<user>")
    .replace(/\/Users\/[^/\s"'`]+/g, "/Users/<user>")
    .replace(/[A-Za-z]:\\Users\\[^\\\s"'`]+/g, "C:\\Users\\<user>");

  return redacted;
}

function redactValue(value) {
  if (includeLocalDetails) return value;
  if (typeof value === "string") return redactLocalText(value);
  if (Array.isArray(value)) return value.map(redactValue);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, redactValue(item)]));
  }
  return value;
}

function publicPath(filePath) {
  if (!filePath) return null;
  const resolved = path.resolve(filePath);
  return includeLocalDetails ? resolved : path.basename(resolved);
}

function runStep(id, commandArgs, options = {}) {
  const startedAt = new Date().toISOString();
  const commandLine = commandArgs.map((part) => JSON.stringify(redactLocalText(part))).join(" ");
  const result = childProcess.spawnSync(commandArgs[0], commandArgs.slice(1), {
    cwd: repoDir,
    encoding: "utf8",
    maxBuffer: 20 * 1024 * 1024,
    shell: options.shell || false,
    timeout: options.timeout || 15 * 60 * 1000,
  });

  const endedAt = new Date().toISOString();
  const stdout = result.stdout || "";
  const stderr = result.stderr || "";
  const status = typeof result.status === "number" ? result.status : 2;
  const signal = result.signal || null;
  const error = result.error ? redactLocalText(result.error.message) : null;
  const output = [
    `$ ${options.shell ? redactLocalText(commandArgs.join(" ")) : commandLine}`,
    "",
    "## STDOUT",
    redactLocalText(stdout || "(empty)"),
    "",
    "## STDERR",
    redactLocalText(stderr || "(empty)"),
    "",
    `exitCode=${status}`,
    signal ? `signal=${signal}` : "",
    error ? `error=${error}` : "",
  ].filter(Boolean).join("\n");

  const outputFile = `${id}.txt`;
  writeText(path.join(outDir, outputFile), output);

  return {
    id,
    command: options.shell ? redactLocalText(commandArgs.join(" ")) : redactValue(commandArgs),
    outputFile,
    startedAt,
    endedAt,
    exitCode: status,
    signal,
    error,
    passed: status === 0,
  };
}

function copyProfile(metadata) {
  if (!profilePath) return;
  const resolved = path.resolve(profilePath);
  const dest = path.join(outDir, path.basename(resolved));
  fs.copyFileSync(resolved, dest);
  metadata.profile = {
    source: publicPath(resolved),
    bundledAs: path.basename(dest),
    sha256: sha256(dest),
  };
}

function copyBannedPrograms(metadata) {
  if (!bannedProgramsPath) return;
  const resolved = path.resolve(bannedProgramsPath);
  const dest = path.join(outDir, path.basename(resolved));
  fs.copyFileSync(resolved, dest);
  metadata.bannedPrograms = {
    source: publicPath(resolved),
    bundledAs: path.basename(dest),
    sha256: sha256(dest),
  };
}

function statusLabel(step) {
  if (!step) return "not run";
  return step.passed ? "PASS" : "FAIL";
}

function buildSummary(metadata, steps) {
  const common = steps.find((step) => step.id === "check-common");
  const advanced = steps.find((step) => step.id === "check-advanced");
  const input = steps.find((step) => step.id === "input-hook");
  const processWatch = steps.find((step) => step.id === "process-watch");
  const client = steps.find((step) => step.id === "client-detector");

  const deliveryFailure =
    !common ||
    !common.passed ||
    (requireAdvancedPass && (!advanced || !advanced.passed)) ||
    (runInputHooks && (!input || !input.passed)) ||
    (runProcessWatch && (!processWatch || !processWatch.passed)) ||
    (clientCommand && (!client || !client.passed));

  const lines = [
    "# OK VM Proctoring Validation Bundle",
    "",
    `Date: ${metadata.createdAt}`,
    `Platform: ${metadata.platform}`,
    `Host: ${metadata.host.hostname}`,
    `Node: ${metadata.node.version}`,
    "",
    "## Results",
    "",
    "| Gate | Status | Evidence |",
    "| --- | --- | --- |",
    `| OK VM Proctoring systeminformation | ${statusLabel(common)} | ${common ? common.outputFile : "-"} |`,
    `| dynamic bannedPrograms process watch | ${statusLabel(processWatch)} | ${processWatch ? processWatch.outputFile : runProcessWatch ? "missing" : "not requested"} |`,
    `| out-of-scope proctoring diagnostics | ${statusLabel(advanced)} | ${advanced ? advanced.outputFile : "not requested"} |`,
    `| input hook checks | ${statusLabel(input)} | ${input ? input.outputFile : runInputHooks ? "missing" : "not requested"} |`,
    `| client detector | ${statusLabel(client)} | ${client ? client.outputFile : clientCommand ? "missing" : "not requested"} |`,
    "",
    "## OK VM Proctoring Status",
    "",
    deliveryFailure ? "FAIL" : "PASS",
    "",
    "## Interpretation",
    "",
    "- `check-common` is the OK VM Proctoring gate for the observed `systeminformation` calls: system, diskLayout, processes, osInfo, mem and cpu.",
    "- `process-watch` keeps polling `systeminformation.processes()` while the operator opens the target analysis software inside the VM.",
    "- `check-advanced` is outside OK VM Proctoring scope. It reports deeper OS-specific residual indicators and is not a blocker unless `--require-advanced-pass` is used or the client detector relies on that signal.",
    "- `input-hook` is only required when the target detector uses `uiohook-napi`, `keyspy` or equivalent global input hooks.",
    "- `client-detector` is the final gate when the exact customer detector is available.",
    "",
    "## Files",
    "",
    "- `metadata.json`",
    "- `steps.json`",
  ];

  for (const step of steps) lines.push(`- \`${step.outputFile}\``);
  if (metadata.profile) lines.push(`- \`${metadata.profile.bundledAs}\``);
  if (metadata.bannedPrograms) lines.push(`- \`${metadata.bannedPrograms.bundledAs}\``);

  lines.push("");
  return `${lines.join("\n")}\n`;
}

function main() {
  ensureDir(outDir);

  const metadata = {
    createdAt: new Date().toISOString(),
    platform: platformLabel,
    repository: includeLocalDetails ? repoDir : path.basename(repoDir),
    host: {
      hostname: includeLocalDetails ? os.hostname() : "<redacted>",
      platform: os.platform(),
      release: os.release(),
      arch: os.arch(),
      type: os.type(),
    },
    node: {
      version: process.version,
      execPath: includeLocalDetails ? process.execPath : path.basename(process.execPath),
    },
    packages: {
      systeminformation: packageVersion("systeminformation"),
      "uiohook-napi": packageVersion("uiohook-napi"),
      keyspy: packageVersion("keyspy"),
    },
    options: {
      runAdvanced,
      requireAdvancedPass,
      runInputHooks,
      hookProvider,
      hookDuration,
      runProcessWatch,
      processWatchDuration,
      processWatchInterval,
      bannedProgramsPath: publicPath(bannedProgramsPath),
      bannedPlatform,
      strictProcesses,
      broadHardware,
      clientCommand: clientCommand ? redactLocalText(clientCommand) : null,
      includeLocalDetails,
    },
  };

  copyProfile(metadata);
  copyBannedPrograms(metadata);
  writeJson(path.join(outDir, "metadata.json"), metadata);

  const steps = [];
  const commonArgs = [process.execPath, path.join(repoDir, "check.js")];
  if (bannedProgramsPath) commonArgs.push("--banned-programs", path.resolve(bannedProgramsPath));
  if (bannedPlatform) commonArgs.push("--banned-platform", bannedPlatform);
  if (strictProcesses) commonArgs.push("--strict-processes");
  if (broadHardware) commonArgs.push("--broad-hardware");
  steps.push(runStep("check-common", commonArgs));

  if (runAdvanced) {
    const advancedArgs = [process.execPath, path.join(repoDir, "check.js"), "--advanced"];
    if (bannedProgramsPath) advancedArgs.push("--banned-programs", path.resolve(bannedProgramsPath));
    if (bannedPlatform) advancedArgs.push("--banned-platform", bannedPlatform);
    if (strictProcesses) advancedArgs.push("--strict-processes");
    if (broadHardware) advancedArgs.push("--broad-hardware");
    steps.push(runStep("check-advanced", advancedArgs));
  }

  if (runInputHooks) {
    const hookArgs = [
      process.execPath,
      path.join(repoDir, "input-hook-check.js"),
      "--provider",
      hookProvider,
      "--duration",
      hookDuration,
    ];
    if (consentYes) hookArgs.push("--yes");
    steps.push(runStep("input-hook", hookArgs, {
      timeout: (Number(hookDuration) + 30) * 1000,
    }));
  }

  if (runProcessWatch) {
    const watchArgs = [
      process.execPath,
      path.join(repoDir, "process-watch.js"),
      "--banned-programs",
      path.resolve(bannedProgramsPath),
      "--banned-platform",
      bannedPlatform,
      "--duration",
      processWatchDuration,
      "--interval",
      processWatchInterval,
    ];
    if (strictProcesses) watchArgs.push("--strict-processes");
    steps.push(runStep("process-watch", watchArgs, {
      timeout: (Number(processWatchDuration) + 30) * 1000,
    }));
  }

  if (clientCommand) {
    steps.push(runStep("client-detector", [clientCommand], {
      shell: true,
      timeout: 30 * 60 * 1000,
    }));
  }

  writeJson(path.join(outDir, "steps.json"), steps);
  writeText(path.join(outDir, "summary.md"), buildSummary(metadata, steps));

  console.log(`Validation bundle written to: ${redactLocalText(outDir)}`);
  const summary = fs.readFileSync(path.join(outDir, "summary.md"), "utf8");
  console.log("");
  console.log(summary);

  const common = steps.find((step) => step.id === "check-common");
  const advanced = steps.find((step) => step.id === "check-advanced");
  const input = steps.find((step) => step.id === "input-hook");
  const processWatch = steps.find((step) => step.id === "process-watch");
  const client = steps.find((step) => step.id === "client-detector");
  const failed =
    !common ||
    !common.passed ||
    (requireAdvancedPass && (!advanced || !advanced.passed)) ||
    (runInputHooks && (!input || !input.passed)) ||
    (runProcessWatch && (!processWatch || !processWatch.passed)) ||
    (clientCommand && (!client || !client.passed));

  process.exit(failed ? 1 : 0);
}

main();
