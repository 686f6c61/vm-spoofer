#!/usr/bin/env node
"use strict";

const os = require("os");
const readline = require("readline");

const args = process.argv.slice(2);
const providerArg = valueOf("--provider") || "auto";
const duration = Math.max(3, Math.min(Number(valueOf("--duration") || 15), 120));
const assumeYes = args.includes("--yes");

function valueOf(name) {
  const idx = args.indexOf(name);
  if (idx === -1) return "";
  return args[idx + 1] || "";
}

function help() {
  console.log("Usage: node input-hook-check.js --provider <auto|uiohook-napi|keyspy> [--duration 15] [--yes]");
  console.log("");
  console.log("Consent-based keyboard/mouse hook validation. It does not print or store key names,");
  console.log("typed text, clipboard contents or mouse coordinates. It only reports event counts.");
}

if (args.includes("--help") || args.includes("-h")) {
  help();
  process.exit(0);
}

function requireOptional(name) {
  try {
    return require(name);
  } catch (error) {
    return null;
  }
}

function printEnvironment() {
  console.log("[ENVIRONMENT]");
  console.log(`platform        ${process.platform}`);
  console.log(`arch            ${process.arch}`);
  console.log(`node            ${process.version}`);
  console.log(`release         ${os.release()}`);
  console.log(`display         ${process.env.DISPLAY || "-"}`);
  console.log(`wayland         ${process.env.WAYLAND_DISPLAY || "-"}`);
  console.log(`session         ${process.env.XDG_SESSION_TYPE || "-"}`);
  console.log("");
}

function consentPrompt() {
  if (assumeYes) return Promise.resolve();
  if (!process.stdin.isTTY) {
    console.error("Refusing to run without explicit consent. Re-run with --yes in an interactive authorized test.");
    process.exit(2);
  }

  console.log("This test listens for global keyboard/mouse events for validation only.");
  console.log("It records counters, not key names, typed text or mouse coordinates.");
  console.log(`Move the mouse, click, and press a few non-sensitive keys during the ${duration}s window.`);

  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((resolve) => {
    rl.question("Press Enter to start, or Ctrl+C to cancel. ", () => {
      rl.close();
      resolve();
    });
  });
}

function emptyCounts(provider) {
  return {
    provider,
    keyboardDown: 0,
    keyboardUp: 0,
    mouseDown: 0,
    mouseUp: 0,
    mouseMove: 0,
    wheel: 0,
    errors: [],
  };
}

function printResult(counts) {
  const total =
    counts.keyboardDown +
    counts.keyboardUp +
    counts.mouseDown +
    counts.mouseUp +
    counts.mouseMove +
    counts.wheel;

  console.log("\n[INPUT HOOK RESULT]");
  console.log(`provider        ${counts.provider}`);
  console.log(`keyboardDown    ${counts.keyboardDown}`);
  console.log(`keyboardUp      ${counts.keyboardUp}`);
  console.log(`mouseDown       ${counts.mouseDown}`);
  console.log(`mouseUp         ${counts.mouseUp}`);
  console.log(`mouseMove       ${counts.mouseMove}`);
  console.log(`wheel           ${counts.wheel}`);
  console.log(`totalEvents     ${total}`);

  if (counts.errors.length > 0) {
    console.log("\n[ERRORS]");
    for (const error of counts.errors) console.log(`- ${error}`);
  }

  if (total > 0 && counts.errors.length === 0) {
    console.log("\nRESULT=PASS");
    process.exit(0);
  }

  if (total > 0) {
    console.log("\nRESULT=PASS_WITH_WARNINGS");
    process.exit(0);
  }

  console.log("\nRESULT=NO_INPUT_EVENTS");
  process.exit(1);
}

function runUiohook() {
  const mod = requireOptional("uiohook-napi");
  if (!mod || !mod.uIOhook) return null;

  const counts = emptyCounts("uiohook-napi");
  const hook = mod.uIOhook;

  hook.on("keydown", () => { counts.keyboardDown += 1; });
  hook.on("keyup", () => { counts.keyboardUp += 1; });
  hook.on("mousedown", () => { counts.mouseDown += 1; });
  hook.on("mouseup", () => { counts.mouseUp += 1; });
  hook.on("mousemove", () => { counts.mouseMove += 1; });
  hook.on("wheel", () => { counts.wheel += 1; });

  try {
    hook.start();
  } catch (error) {
    counts.errors.push(error && error.message ? error.message : String(error));
    printResult(counts);
  }

  return new Promise((resolve) => {
    setTimeout(() => {
      try {
        hook.stop();
      } catch (error) {
        counts.errors.push(error && error.message ? error.message : String(error));
      }
      if (typeof hook.removeAllListeners === "function") hook.removeAllListeners();
      resolve(counts);
    }, duration * 1000);
  });
}

async function runKeyspy() {
  const mod = requireOptional("keyspy");
  if (!mod || !mod.GlobalKeyboardListener) return null;

  const counts = emptyCounts("keyspy");
  const listener = new mod.GlobalKeyboardListener({
    appName: "VM Spoofer Input Validation",
    windows: {
      onError: (code) => counts.errors.push(`windows:${code}`),
    },
    mac: {
      appName: "VM Spoofer Input Validation",
      onError: (code) => counts.errors.push(`macos:${code}`),
    },
    x11: {
      appName: "VM Spoofer Input Validation",
      onError: (code) => counts.errors.push(`x11:${code}`),
    },
  });

  const handler = (event) => {
    const state = String(event && event.state ? event.state : "").toUpperCase();
    const name = String(event && event.name ? event.name : "").toUpperCase();
    const isMouse = name.includes("MOUSE") || name.includes("WHEEL");

    if (name.includes("WHEEL")) counts.wheel += 1;
    else if (isMouse && state === "DOWN") counts.mouseDown += 1;
    else if (isMouse && state === "UP") counts.mouseUp += 1;
    else if (state === "DOWN") counts.keyboardDown += 1;
    else if (state === "UP") counts.keyboardUp += 1;
  };

  try {
    await listener.addListener(handler);
  } catch (error) {
    counts.errors.push(error && error.message ? error.message : String(error));
    printResult(counts);
  }

  return new Promise((resolve) => {
    setTimeout(() => {
      try {
        listener.removeListener(handler);
        listener.kill();
      } catch (error) {
        counts.errors.push(error && error.message ? error.message : String(error));
      }
      resolve(counts);
    }, duration * 1000);
  });
}

async function main() {
  const allowed = new Set(["auto", "uiohook-napi", "keyspy"]);
  if (!allowed.has(providerArg)) {
    help();
    process.exit(2);
  }

  printEnvironment();
  await consentPrompt();

  let result = null;
  if (providerArg === "uiohook-napi") result = await runUiohook();
  if (providerArg === "keyspy") result = await runKeyspy();
  if (providerArg === "auto") result = await runUiohook() || await runKeyspy();

  if (!result) {
    console.error(`No supported input hook provider is installed for provider=${providerArg}.`);
    console.error("Install one explicitly inside the guest: npm install uiohook-napi or npm install keyspy@1.1.1");
    process.exit(2);
  }

  printResult(result);
}

main().catch((error) => {
  console.error(error && error.stack ? error.stack : error);
  process.exit(2);
});
