"use strict";

const fs = require("fs");

function clean(value) {
  if (value === undefined || value === null) return "";
  return String(value).trim();
}

function normalizeMatchText(value) {
  return clean(value)
    .toLowerCase()
    .replace(/\\/g, "/")
    .replace(/^"+|"+$/g, "")
    .replace(/\s+/g, " ");
}

function normalizeProgramToken(value) {
  const text = normalizeMatchText(value);
  return text
    .split("/")
    .pop()
    .replace(/\.(exe|app)$/i, "")
    .trim();
}

function processText(processInfo) {
  return normalizeMatchText([
    processInfo.name,
    processInfo.proc,
    processInfo.command,
    processInfo.path,
    processInfo.params,
  ].filter(Boolean).join(" "));
}

function processCandidates(processInfo) {
  const values = [
    processInfo.name,
    processInfo.proc,
    processInfo.command,
    processInfo.path,
  ].filter(Boolean);

  const candidates = new Set();
  for (const value of values) {
    const normalized = normalizeMatchText(value);
    if (normalized) candidates.add(normalized);
    const token = normalizeProgramToken(value);
    if (token) candidates.add(token);
  }

  const pathText = normalizeMatchText(processInfo.path || processInfo.command || "");
  const appMatch = pathText.match(/\/([^/]+)\.app(?:\/|$)/i);
  if (appMatch) {
    candidates.add(appMatch[1]);
    candidates.add(`${appMatch[1]}.app`);
  }

  return Array.from(candidates).filter(Boolean);
}

function isPlatformKey(key, platform) {
  const normalized = normalizeMatchText(key);
  if (platform === "all") {
    return ["windows", "win", "win32", "mac", "macos", "darwin", "osx", "linux"].includes(normalized);
  }
  if (platform === "windows") return ["windows", "win", "win32"].includes(normalized);
  if (platform === "macos") return ["mac", "macos", "darwin", "osx"].includes(normalized);
  if (platform === "linux") return normalized === "linux";
  return false;
}

function platformForBannedCatalog(platformArg, notes = []) {
  const normalized = normalizeMatchText(platformArg || "auto");
  if (["windows", "win32", "win"].includes(normalized)) return "windows";
  if (["macos", "mac", "darwin", "osx"].includes(normalized)) return "macos";
  if (["linux", "gnu/linux"].includes(normalized)) return "linux";
  if (normalized === "all") return "all";
  if (normalized !== "auto") notes.push(`Unknown banned platform '${platformArg}', using auto.`);
  if (process.platform === "win32") return "windows";
  if (process.platform === "darwin") return "macos";
  return "linux";
}

function hasAnyPlatformKey(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  return Object.keys(value).some((key) => isPlatformKey(key, "all"));
}

function collectStringValues(value, out) {
  if (typeof value === "string") {
    out.push(value);
    return;
  }
  if (Array.isArray(value)) {
    for (const item of value) collectStringValues(item, out);
  }
}

function collectStructuredBannedPrograms(value, platform, out) {
  if (!value) return;

  if (typeof value === "string") {
    out.push(value);
    return;
  }

  if (Array.isArray(value)) {
    for (const item of value) collectStructuredBannedPrograms(item, platform, out);
    return;
  }

  if (typeof value !== "object") return;

  for (const [key, child] of Object.entries(value)) {
    if (isPlatformKey(key, platform)) {
      collectStringValues(child, out);
    }
  }

  const isContainer = ["bannedPrograms", "programs", "items", "children", "categories"].some((key) => value[key]);
  if (!hasAnyPlatformKey(value) && !isContainer) {
    for (const key of ["name", "program", "process", "displayName", "label"]) {
      if (typeof value[key] === "string") out.push(value[key]);
    }
  }

  for (const key of ["bannedPrograms", "programs", "items", "children", "categories"]) {
    if (value[key]) collectStructuredBannedPrograms(value[key], platform, out);
  }

  for (const [key, child] of Object.entries(value)) {
    if (["name", "program", "process", "displayName", "label"].includes(key)) continue;
    if (isPlatformKey(key, "all")) continue;
    if (["bannedPrograms", "programs", "items", "children", "categories"].includes(key)) continue;
    if (child && typeof child === "object") collectStructuredBannedPrograms(child, platform, out);
  }
}

function uniqueNormalized(values) {
  return Array.from(new Set(values.map(normalizeMatchText).filter(Boolean)));
}

function loadBannedPrograms(filePath, notes = [], platformArg = "auto") {
  if (!filePath) return [];
  let raw = "";
  try {
    raw = fs.readFileSync(filePath, "utf8");
  } catch (error) {
    const message = error && error.message ? error.message : String(error);
    notes.push(`bannedPrograms file could not be read: ${message}`);
    return [];
  }

  try {
    const parsed = JSON.parse(raw);
    const platform = platformForBannedCatalog(platformArg, notes);
    const values = [];
    collectStructuredBannedPrograms(parsed, platform, values);
    notes.push(`Loaded ${values.length} bannedPrograms raw entries from JSON for platform=${platform}.`);
    return uniqueNormalized(values);
  } catch (error) {
    const values = raw
      .split(/\r?\n|,/)
      .map((line) => line.replace(/#.*/, ""))
      .map(normalizeMatchText)
      .filter(Boolean);
    notes.push(`Loaded ${values.length} bannedPrograms entries from flat text list.`);
    return uniqueNormalized(values);
  }
}

function findBannedProgramMatch(processInfo, bannedPrograms) {
  if (bannedPrograms.length === 0) return "";
  const candidates = processCandidates(processInfo);
  for (const candidate of candidates) {
    if (bannedPrograms.includes(candidate)) return candidate;
  }

  const text = processText(processInfo);
  return bannedPrograms.find((program) => program.length >= 4 && text.includes(program)) || "";
}

module.exports = {
  clean,
  findBannedProgramMatch,
  loadBannedPrograms,
  normalizeMatchText,
  platformForBannedCatalog,
  processCandidates,
  processText,
};
