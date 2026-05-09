#!/usr/bin/env node
"use strict";

const fs = require("fs");
const childProcess = require("child_process");
const os = require("os");
const banned = require("./banned-programs");

const rawArgs = process.argv.slice(2);
const args = new Set(rawArgs);
if (args.has("--help") || args.has("-h")) {
  console.log("Usage: node check.js [--advanced] [--broad-hardware] [--skip-processes]");
  console.log("                     [--strict-processes] [--banned-programs <file>]");
  console.log("                     [--banned-platform <auto|windows|macos|linux|all>]");
  console.log("                     [--include-services]");
  console.log("");
  console.log("  --advanced   Add OS-specific low-level checks for CPUID exposure, PCI IDs,");
  console.log("               Guest Additions artifacts, modules/drivers, ACPI/IORegistry,");
  console.log("               services, packages, registry/receipts and logs where available.");
  console.log("  --broad-hardware       Also query baseboard, chassis, graphics and networkInterfaces.");
  console.log("  --skip-processes       Do not run systeminformation.processes().");
  console.log("  --strict-processes     Treat VM-looking process names as blocking findings.");
  console.log("  --banned-programs      Flat list or structured local banned-programs JSON to enforce.");
  console.log("  --banned-platform      Platform slice used for structured catalogs (default: auto).");
  console.log("  --include-services     Also query systeminformation.services('*') as an extra check.");
  console.log("");
  console.log("  OK VM Proctoring/default scope matches the observed client calls:");
  console.log("  diskLayout(), processes(), system(), osInfo(), mem() and cpu().");
  process.exit(0);
}

function valueOf(name, fallback = "") {
  const idx = rawArgs.indexOf(name);
  if (idx === -1) return fallback;
  return rawArgs[idx + 1] || fallback;
}

const broadHardware = args.has("--broad-hardware");
const includeProcesses = !args.has("--skip-processes");
const strictProcesses = args.has("--strict-processes");
const includeServices = args.has("--include-services");
const bannedProgramsPath = valueOf("--banned-programs");
const bannedPlatform = valueOf("--banned-platform", "auto");
const maxProcessNotes = 20;

let si;
try {
  si = require("systeminformation");
} catch (error) {
  console.error("Missing dependency: systeminformation");
  console.error("Install it inside the VM with: npm install systeminformation");
  process.exit(2);
}

const VM_TEXT_PATTERNS = [
  /virtualbox/i,
  /\bvbox\b/i,
  /oracle/i,
  /innotek/i,
  /vmware/i,
  /qemu/i,
  /\bkvm\b/i,
  /\bxen\b/i,
  /hyper-v/i,
  /parallels/i,
  /bochs/i,
];

const VM_MAC_PREFIXES = new Map([
  ["080027", "Oracle VirtualBox"],
  ["000569", "VMware"],
  ["000C29", "VMware"],
  ["001C14", "VMware"],
  ["005056", "VMware"],
  ["00163E", "Xen"],
  ["525400", "QEMU/KVM"],
]);

const VM_PCI_VENDOR_IDS = new Map([
  ["0x80ee", "Oracle VirtualBox"],
  ["0x15ad", "VMware"],
  ["0x1af4", "Virtio/QEMU/KVM"],
  ["0x1b36", "QEMU"],
  ["0x1234", "QEMU/Bochs"],
  ["0x5853", "Xen"],
  ["0x1414", "Microsoft Hyper-V"],
  ["0x1ab8", "Parallels"],
]);

const VM_PCI_VENDOR_IDS_WINDOWS = new Map(
  Array.from(VM_PCI_VENDOR_IDS.entries()).map(([id, vendor]) => [id.replace(/^0x/i, "").toUpperCase(), vendor])
);

const VM_LINUX_MODULE_PATTERNS = [
  /^vbox/i,
  /^vmw/i,
  /^virtio/i,
  /^xen/i,
  /^hv_/i,
  /^hyperv/i,
  /^qxl/i,
  /^bochs/i,
];

const VM_ARTIFACT_PATHS = [
  "/dev/vboxguest",
  "/dev/vboxuser",
  "/dev/vmci",
  "/dev/virtio-ports",
  "/dev/xen",
  "/usr/bin/VBoxClient",
  "/usr/sbin/VBoxService",
  "/sbin/mount.vboxsf",
  "/lib/systemd/system/vboxadd.service",
  "/lib/systemd/system/vboxadd-service.service",
  "/lib/systemd/system/vboxadd-x11.service",
  "/usr/lib/systemd/system/vboxadd.service",
  "/usr/lib/systemd/system/vboxadd-service.service",
  "/usr/lib/systemd/system/vboxadd-x11.service",
  "/usr/lib/systemd/system/vboxservice.service",
  "/usr/lib/systemd/system/vmtoolsd.service",
  "/usr/lib/systemd/system/qemu-guest-agent.service",
  "/usr/lib/systemd/system/spice-vdagent.service",
  "/etc/init.d/vboxadd",
  "/etc/init.d/vboxadd-service",
  "/etc/init.d/vmware-tools",
];

function clean(value) {
  if (value === undefined || value === null) return "";
  return String(value).trim();
}

function normalizeMac(value) {
  return clean(value).replace(/[^0-9a-f]/gi, "").toUpperCase();
}

function hasVmText(value) {
  const text = clean(value);
  return VM_TEXT_PATTERNS.some((pattern) => pattern.test(text));
}

function addFinding(findings, severity, source, field, value) {
  const cleaned = clean(value);
  if (!cleaned) return;
  findings.push({ severity, source, field, value: cleaned });
}

function addTextFinding(findings, source, field, value, severity = "high") {
  if (hasVmText(value)) {
    addFinding(findings, severity, source, field, value);
  }
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

function platformForBannedCatalog(platformArg, notes) {
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
  return Array.from(new Set(
    values
      .map(normalizeMatchText)
      .filter(Boolean)
  ));
}

function loadBannedPrograms(filePath, notes, platformArg) {
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

function addMacFinding(findings, iface) {
  const mac = normalizeMac(iface.mac);
  if (!mac || mac.length < 6) return;
  const vendor = VM_MAC_PREFIXES.get(mac.slice(0, 6));
  if (vendor) {
    findings.push({
      severity: "high",
      source: "networkInterfaces",
      field: iface.iface || iface.ifaceName || "mac",
      value: `${iface.mac} (${vendor})`,
    });
  }
}

function printObject(title, rows) {
  console.log(`\n[${title}]`);
  for (const [label, value] of rows) {
    console.log(`${label.padEnd(18)} ${clean(value) || "-"}`);
  }
}

function formatBytes(value) {
  const bytes = Number(value);
  if (!Number.isFinite(bytes) || bytes <= 0) return clean(value);
  return `${Math.round(bytes / 1024 / 1024 / 1024)} GB`;
}

function score(findings) {
  return findings.reduce((total, item) => {
    if (item.severity === "high") return total + 35;
    if (item.severity === "medium") return total + 20;
    return total + 10;
  }, 0);
}

async function safeSi(label, operation, fallback, notes) {
  try {
    return await operation();
  } catch (error) {
    const message = error && error.message ? error.message : String(error);
    notes.push(`systeminformation.${label} failed: ${message}`);
    return fallback;
  }
}

function getOsNetworkInterfaces(notes) {
  try {
    const interfaces = os.networkInterfaces();
    const rows = [];
    for (const [iface, addresses] of Object.entries(interfaces)) {
      for (const address of addresses || []) {
        if (!address.mac) continue;
        rows.push({ iface, mac: address.mac });
      }
    }
    return rows;
  } catch (error) {
    const message = error && error.message ? error.message : String(error);
    notes.push(`os.networkInterfaces failed: ${message}`);
    return [];
  }
}

function canProbeNetworkInterfaces(notes) {
  try {
    os.networkInterfaces();
    return true;
  } catch (error) {
    const message = error && error.message ? error.message : String(error);
    notes.push(`network interface inventory unavailable in this runtime: ${message}`);
    return false;
  }
}

function normalizeNetworkInterfaces(siRows, notes) {
  if (Array.isArray(siRows) && siRows.length > 0) {
    return siRows.map((iface) => ({
      iface: iface.iface || iface.ifaceName || iface.name || "",
      ifaceName: iface.ifaceName || iface.iface || iface.name || "",
      mac: iface.mac || iface.macAddress || "",
    }));
  }
  notes.push("systeminformation.networkInterfaces returned no interfaces; falling back to os.networkInterfaces.");
  return getOsNetworkInterfaces(notes);
}

function readText(filePath, maxBytes = 1024 * 1024) {
  try {
    const data = fs.readFileSync(filePath);
    return data.subarray(0, maxBytes).toString("utf8");
  } catch (error) {
    return "";
  }
}

function readBinaryText(filePath, maxBytes = 2 * 1024 * 1024) {
  try {
    const data = fs.readFileSync(filePath);
    return data.subarray(0, maxBytes).toString("latin1");
  } catch (error) {
    return "";
  }
}

function readDir(dirPath) {
  try {
    return fs.readdirSync(dirPath);
  } catch (error) {
    return [];
  }
}

function pathExists(filePath) {
  try {
    return fs.existsSync(filePath);
  } catch (error) {
    return false;
  }
}

function runCommand(command, commandArgs) {
  try {
    return childProcess.execFileSync(command, commandArgs, {
      encoding: "utf8",
      maxBuffer: 1024 * 1024,
      stdio: ["ignore", "pipe", "ignore"],
      timeout: 3000,
    });
  } catch (error) {
    return "";
  }
}

function scanTextForVm(findings, source, field, text, severity = "medium") {
  if (!text) return;
  const lines = clean(text).split(/\r?\n/).filter(Boolean);
  for (const line of lines.slice(0, 200)) {
    if (hasVmText(line) || /\bhypervisor\b/i.test(line)) {
      addFinding(findings, severity, source, field, line.slice(0, 180));
      return;
    }
  }
}

function addLinuxCpuFindings(findings, notes) {
  const cpuinfo = readText("/proc/cpuinfo");
  if (!cpuinfo) return;

  const flagsLine = cpuinfo.split(/\r?\n/).find((line) => /^flags\s*:/i.test(line));
  if (flagsLine && /\bhypervisor\b/i.test(flagsLine)) {
    addFinding(findings, "high", "cpuinfo", "flags", "hypervisor flag present");
  }

  for (const field of ["vendor_id", "model name", "Hardware"]) {
    const line = cpuinfo.split(/\r?\n/).find((entry) => entry.toLowerCase().startsWith(field.toLowerCase()));
    if (line) scanTextForVm(findings, "cpuinfo", field, line, "high");
  }

  const cpuid = runCommand("cpuid", ["-1"]);
  if (cpuid) {
    scanTextForVm(findings, "cpuid", "raw", cpuid, "high");
  } else {
    notes.push("Raw CPUID instruction output was not tested because the `cpuid` utility is not installed.");
  }
}

function addLinuxPciFindings(findings) {
  for (const device of readDir("/sys/bus/pci/devices")) {
    const base = `/sys/bus/pci/devices/${device}`;
    const vendor = clean(readText(`${base}/vendor`)).toLowerCase();
    const deviceId = clean(readText(`${base}/device`)).toLowerCase();
    const vendorName = VM_PCI_VENDOR_IDS.get(vendor);
    if (vendorName) {
      addFinding(findings, "high", "pci.sysfs", device, `${vendor} ${deviceId} (${vendorName})`);
    }

    scanTextForVm(findings, "pci.sysfs", `${device}.uevent`, readText(`${base}/uevent`), "medium");
  }
}

function addLinuxDmiFindings(findings) {
  for (const dirPath of ["/sys/class/dmi/id", "/sys/devices/virtual/dmi/id"]) {
    for (const entry of readDir(dirPath)) {
      const filePath = `${dirPath}/${entry}`;
      if (!pathExists(filePath)) continue;
      addTextFinding(findings, "dmi.sysfs", entry, readText(filePath), "high");
    }
  }
}

function addLinuxModuleFindings(findings) {
  const modules = readText("/proc/modules");
  for (const line of modules.split(/\r?\n/)) {
    const moduleName = line.split(/\s+/)[0];
    if (!moduleName) continue;
    if (VM_LINUX_MODULE_PATTERNS.some((pattern) => pattern.test(moduleName))) {
      addFinding(findings, "high", "kernelModule", moduleName, line.slice(0, 180));
    }
  }
}

function addLinuxArtifactFindings(findings) {
  for (const artifactPath of VM_ARTIFACT_PATHS) {
    if (pathExists(artifactPath)) {
      addFinding(findings, "medium", "guestArtifact", artifactPath, "path exists");
    }
  }

  for (const entry of readDir("/opt")) {
    if (/VBoxGuestAdditions|vmware-tools/i.test(entry)) {
      addFinding(findings, "medium", "guestArtifact", `/opt/${entry}`, "directory exists");
    }
  }

  const dpkgStatus = readText("/var/lib/dpkg/status", 3 * 1024 * 1024);
  const packageMatches = dpkgStatus.match(/^Package:\s+(virtualbox-guest\S*|open-vm-tools\S*|qemu-guest-agent|spice-vdagent)$/gim) || [];
  for (const match of packageMatches.slice(0, 20)) {
    addFinding(findings, "medium", "package", "dpkg", match.replace(/^Package:\s*/i, ""));
  }

  const systemdUnits = runCommand("systemctl", ["list-unit-files", "--no-pager", "--type=service"]);
  for (const line of systemdUnits.split(/\r?\n/)) {
    if (/\b(vbox|virtualbox|vmtools|qemu-guest|spice-vdagent)\b/i.test(line)) {
      addFinding(findings, "medium", "systemd", "unit", line.trim());
    }
  }
}

function addLinuxAcpiFindings(findings) {
  const acpiDir = "/sys/firmware/acpi/tables";
  for (const entry of readDir(acpiDir)) {
    const tableText = readBinaryText(`${acpiDir}/${entry}`);
    if (!tableText) continue;
    if (hasVmText(tableText) || /\b(VBOX|ORCL|BOCHS|QEMU|VMWARE|XEN)\b/i.test(tableText)) {
      addFinding(findings, "high", "acpi", entry, "VM-related text found in ACPI table");
    }
  }
}

function addLinuxLogFindings(findings) {
  const dmesg = runCommand("dmesg", ["--color=never"]);
  scanTextForVm(findings, "kernelLog", "dmesg", dmesg, "low");

  for (const logPath of ["/var/log/dmesg", "/var/log/kern.log", "/var/log/syslog"]) {
    scanTextForVm(findings, "kernelLog", logPath, readText(logPath), "low");
  }
}

function addWindowsAdvancedFindings(findings) {
  const notes = [];
  const ps = (script) => {
    for (const command of ["powershell.exe", "pwsh"]) {
      const output = runCommand(command, [
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-Command",
        script,
      ]);
      if (output) return output;
    }
    return "";
  };

  const pnp = ps("Get-CimInstance Win32_PnPEntity | Select-Object Name,Manufacturer,DeviceID | ConvertTo-Json -Compress");
  if (pnp) {
    scanTextForVm(findings, "windows.pnp", "Win32_PnPEntity", pnp, "high");
    for (const [vendorId, vendorName] of VM_PCI_VENDOR_IDS_WINDOWS.entries()) {
      if (new RegExp(`VEN_${vendorId}`, "i").test(pnp)) {
        addFinding(findings, "high", "windows.pnp", `VEN_${vendorId}`, vendorName);
      }
    }
  } else {
    notes.push("Windows PnP inventory was not available; run from an elevated PowerShell-capable session inside the guest.");
  }

  const drivers = ps("Get-CimInstance Win32_SystemDriver | Select-Object Name,DisplayName,PathName,State | ConvertTo-Json -Compress");
  scanTextForVm(findings, "windows.driver", "Win32_SystemDriver", drivers, "high");

  const services = ps("Get-CimInstance Win32_Service | Select-Object Name,DisplayName,PathName,State | ConvertTo-Json -Compress");
  scanTextForVm(findings, "windows.service", "Win32_Service", services, "medium");

  const uninstall = ps("Get-ItemProperty HKLM:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*,HKLM:\\Software\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\* -ErrorAction SilentlyContinue | Select-Object DisplayName,Publisher | ConvertTo-Json -Compress");
  scanTextForVm(findings, "windows.registry", "Uninstall", uninstall, "medium");

  const computer = ps("Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer,Model,HypervisorPresent | ConvertTo-Json -Compress");
  if (/\bHypervisorPresent\b[^}]*true/i.test(computer)) {
    addFinding(findings, "high", "windows.cim", "HypervisorPresent", "true");
  }
  scanTextForVm(findings, "windows.cim", "Win32_ComputerSystem", computer, "high");

  for (const artifactPath of [
    "C:\\Windows\\System32\\drivers\\VBoxGuest.sys",
    "C:\\Windows\\System32\\drivers\\VBoxMouse.sys",
    "C:\\Windows\\System32\\drivers\\VBoxSF.sys",
    "C:\\Windows\\System32\\drivers\\VBoxVideo.sys",
    "C:\\Windows\\System32\\drivers\\VBoxWddm.sys",
    "C:\\Windows\\System32\\drivers\\vmmouse.sys",
    "C:\\Windows\\System32\\drivers\\vmhgfs.sys",
    "C:\\Program Files\\Oracle\\VirtualBox Guest Additions\\VBoxService.exe",
    "C:\\Program Files\\VMware\\VMware Tools\\vmtoolsd.exe",
  ]) {
    if (pathExists(artifactPath)) {
      addFinding(findings, "medium", "windows.artifact", artifactPath, "path exists");
    }
  }

  notes.push("Raw CPUID and timing side channels require the target detector or a native helper; Node.js cannot fully assert them on Windows.");
  return notes;
}

function addMacosAdvancedFindings(findings) {
  const notes = [];

  const systemProfiler = runCommand("system_profiler", [
    "SPHardwareDataType",
    "SPPCIDataType",
    "SPDisplaysDataType",
    "SPExtensionsDataType",
  ]);
  if (systemProfiler) {
    scanTextForVm(findings, "macos.system_profiler", "hardware", systemProfiler, "high");
  } else {
    notes.push("macOS system_profiler inventory was not available.");
  }

  const ioreg = runCommand("ioreg", ["-l"]);
  scanTextForVm(findings, "macos.ioreg", "IORegistry", ioreg, "high");

  const kextstat = runCommand("kextstat", []);
  const kmutil = runCommand("kmutil", ["showloaded"]);
  scanTextForVm(findings, "macos.kernelExtension", "kextstat", kextstat, "high");
  scanTextForVm(findings, "macos.kernelExtension", "kmutil", kmutil, "high");

  const launchDaemons = runCommand("launchctl", ["list"]);
  scanTextForVm(findings, "macos.launchd", "launchctl", launchDaemons, "medium");

  const receipts = runCommand("pkgutil", ["--pkgs"]);
  scanTextForVm(findings, "macos.pkgutil", "receipts", receipts, "medium");

  const sysctlCpu = runCommand("sysctl", ["-a", "machdep.cpu"]);
  scanTextForVm(findings, "macos.sysctl", "machdep.cpu", sysctlCpu, "high");
  if (/\bmachdep\.cpu\.features\b.*\bVMM\b/i.test(sysctlCpu)) {
    addFinding(findings, "medium", "macos.sysctl", "machdep.cpu.features", "VMM feature present");
  }

  for (const artifactPath of [
    "/Library/Application Support/VirtualBox Guest Additions",
    "/Library/Extensions/VBoxDrv.kext",
    "/Library/Extensions/VBoxGuest.kext",
    "/Library/Extensions/VBoxSF.kext",
    "/Library/Extensions/VBoxVideo.kext",
    "/Library/LaunchDaemons/org.virtualbox.startup.plist",
    "/Library/LaunchDaemons/com.vmware.launchd.tools.plist",
    "/Library/Application Support/VMware Tools",
  ]) {
    if (pathExists(artifactPath)) {
      addFinding(findings, "medium", "macos.artifact", artifactPath, "path exists");
    }
  }

  notes.push("Raw CPUID and timing side channels require the target detector or a native helper; Node.js cannot fully assert them on macOS.");
  return notes;
}

function addAdvancedFindings(findings) {
  if (process.platform === "linux") {
    const notes = [];
    addLinuxCpuFindings(findings, notes);
    addLinuxPciFindings(findings);
    addLinuxDmiFindings(findings);
    addLinuxModuleFindings(findings);
    addLinuxArtifactFindings(findings);
    addLinuxAcpiFindings(findings);
    addLinuxLogFindings(findings);
    notes.push("Timing side-channel detection is not asserted by this local verifier; use the target detector or an external timing harness for acceptance.");
    return notes;
  }

  if (process.platform === "win32") return addWindowsAdvancedFindings(findings);
  if (process.platform === "darwin") return addMacosAdvancedFindings(findings);

  return [`Advanced low-level checks are not implemented for platform: ${process.platform}.`];
}

async function main() {
  const runtimeNotes = [];
  const bannedPrograms = banned.loadBannedPrograms(bannedProgramsPath, runtimeNotes, bannedPlatform);
  const [system, osInfo, memory, cpu, disks, processInventory] = await Promise.all([
    safeSi("system", () => si.system(), {}, runtimeNotes),
    safeSi("osInfo", () => si.osInfo(), {}, runtimeNotes),
    safeSi("mem", () => si.mem(), {}, runtimeNotes),
    safeSi("cpu", () => si.cpu(), {}, runtimeNotes),
    safeSi("diskLayout", () => si.diskLayout(), [], runtimeNotes),
    includeProcesses
      ? safeSi("processes", () => si.processes(), { list: [] }, runtimeNotes)
      : Promise.resolve({ list: [] }),
  ]);

  let bios = {};
  let baseboard = {};
  let chassis = {};
  let graphics = { controllers: [] };
  let networkInterfaces = [];
  if (broadHardware) {
    [bios, baseboard, chassis, graphics] = await Promise.all([
      safeSi("bios", () => si.bios(), {}, runtimeNotes),
      safeSi("baseboard", () => si.baseboard(), {}, runtimeNotes),
      safeSi("chassis", () => si.chassis(), {}, runtimeNotes),
      safeSi("graphics", () => si.graphics(), { controllers: [] }, runtimeNotes),
    ]);
    const siNetworkInterfaces = canProbeNetworkInterfaces(runtimeNotes)
      ? await safeSi("networkInterfaces", () => si.networkInterfaces(), [], runtimeNotes)
      : [];
    networkInterfaces = normalizeNetworkInterfaces(siNetworkInterfaces, runtimeNotes);
  }

  const findings = [];
  const processNotes = [];

  if (system.virtual === true || clean(system.virtual).toLowerCase() === "true") {
    addFinding(findings, "high", "system", "virtual", "true");
  }
  if (clean(system.virtualHost)) {
    addTextFinding(findings, "system", "virtualHost", system.virtualHost, "high");
  }

  for (const [field, value] of Object.entries(system)) addTextFinding(findings, "system", field, value);
  for (const [field, value] of Object.entries(osInfo)) addTextFinding(findings, "osInfo", field, value, "medium");
  for (const [field, value] of Object.entries(cpu)) addTextFinding(findings, "cpu", field, value, "medium");

  for (const disk of disks) {
    addTextFinding(findings, "diskLayout", "name", disk.name);
    addTextFinding(findings, "diskLayout", "vendor", disk.vendor);
    addTextFinding(findings, "diskLayout", "serialNum", disk.serialNum);
  }

  if (includeProcesses) {
    for (const processInfo of processInventory.list || []) {
      const field = clean(processInfo.name || processInfo.proc || processInfo.pid || "process");
      const text = processText(processInfo);
      const matchedBan = banned.findBannedProgramMatch(processInfo, bannedPrograms);
      if (matchedBan) {
        addFinding(findings, "high", "processes", field, `matches bannedPrograms entry: ${matchedBan}`);
      }

      if (hasVmText(text)) {
        if (strictProcesses) {
          addFinding(findings, "high", "processes", field, text.slice(0, 180));
        } else if (processNotes.length < maxProcessNotes) {
          processNotes.push(`VM-looking process observed but not blocking in OK VM Proctoring mode: ${field}`);
        }
      }
    }
  }

  if (broadHardware) {
    for (const [field, value] of Object.entries(bios)) addTextFinding(findings, "bios", field, value);
    for (const [field, value] of Object.entries(baseboard)) addTextFinding(findings, "baseboard", field, value);
    for (const [field, value] of Object.entries(chassis)) addTextFinding(findings, "chassis", field, value);

    for (const controller of graphics.controllers || []) {
      addTextFinding(findings, "graphics", "vendor", controller.vendor, "medium");
      addTextFinding(findings, "graphics", "model", controller.model, "medium");
    }

    for (const iface of networkInterfaces) addMacFinding(findings, iface);
  }

  if (includeServices) {
    const services = await safeSi("services", () => si.services("*"), [], runtimeNotes);
    for (const service of services || []) {
      scanTextForVm(
        findings,
        "services",
        clean(service.name || "service"),
        `${service.name || ""} ${service.displayName || ""} ${service.path || ""}`,
        "high"
      );
    }
  }

  const advancedNotes = args.has("--advanced") ? addAdvancedFindings(findings) : [];

  printObject("SYSTEM", [
    ["manufacturer", system.manufacturer],
    ["model", system.model],
    ["version", system.version],
    ["serial", system.serial],
    ["uuid", system.uuid],
    ["sku", system.sku],
    ["virtual", system.virtual],
    ["virtualHost", system.virtualHost],
  ]);

  printObject("OS", [
    ["platform", osInfo.platform],
    ["distro", osInfo.distro],
    ["release", osInfo.release],
    ["codename", osInfo.codename],
    ["kernel", osInfo.kernel],
  ]);

  printObject("MEMORY", [
    ["total", formatBytes(memory.total)],
    ["available", formatBytes(memory.available)],
    ["free", formatBytes(memory.free)],
  ]);

  printObject("CPU", [
    ["manufacturer", cpu.manufacturer],
    ["brand", cpu.brand],
    ["speed", cpu.speed],
    ["cores", cpu.cores],
    ["physicalCores", cpu.physicalCores],
  ]);

  console.log("\n[DISKS]");
  for (const disk of disks) {
    console.log(`- ${clean(disk.vendor) || "-"} ${clean(disk.name) || "-"} serial=${clean(disk.serialNum) || "-"}`);
  }

  console.log("\n[PROCESSES]");
  console.log(`total             ${clean(processInventory.all) || (processInventory.list || []).length || 0}`);
  console.log(`listed            ${(processInventory.list || []).length}`);
  console.log(`bannedPrograms    ${bannedPrograms.length}`);
  console.log(`strictProcesses   ${strictProcesses ? "yes" : "no"}`);
  if (processNotes.length > 0) {
    console.log("notes");
    for (const note of processNotes) console.log(`- ${note}`);
  }

  if (broadHardware) {
    printObject("BIOS", [
      ["vendor", bios.vendor],
      ["version", bios.version],
      ["releaseDate", bios.releaseDate],
      ["revision", bios.revision],
    ]);

    printObject("BASEBOARD", [
      ["manufacturer", baseboard.manufacturer],
      ["model", baseboard.model],
      ["version", baseboard.version],
      ["serial", baseboard.serial],
    ]);

    console.log("\n[GRAPHICS]");
    for (const controller of graphics.controllers || []) {
      console.log(`- ${clean(controller.vendor) || "-"} ${clean(controller.model) || "-"}`);
    }

    console.log("\n[NETWORK]");
    for (const iface of networkInterfaces) {
      if (!iface.mac) continue;
      console.log(`- ${clean(iface.iface || iface.ifaceName) || "-"} ${iface.mac}`);
    }
  }

  console.log("\n[FINDINGS]");
  if (findings.length === 0) {
    console.log(args.has("--advanced")
      ? "No common or advanced VM indicators detected by this verifier."
      : "No common VM indicators detected by this verifier.");
  } else {
    for (const finding of findings) {
      console.log(`- ${finding.severity.toUpperCase()} ${finding.source}.${finding.field}: ${finding.value}`);
    }
  }

  if (args.has("--advanced")) {
    console.log("\n[ADVANCED NOTES]");
    for (const note of runtimeNotes) console.log(`- ${note}`);
    for (const note of advancedNotes) console.log(`- ${note}`);
  } else {
    if (runtimeNotes.length > 0) {
      console.log("\n[RUNTIME NOTES]");
      for (const note of runtimeNotes) console.log(`- ${note}`);
    }
    console.log("\n[ADVANCED]");
    console.log("Not run. Use `node check.js --advanced` inside a Linux guest for low-level residual indicators.");
  }

  const riskScore = Math.min(score(findings), 100);
  console.log(`\nScore: ${riskScore}/100`);
  process.exit(riskScore >= 35 ? 1 : 0);
}

main().catch((error) => {
  console.error(error && error.stack ? error.stack : error);
  process.exit(2);
});
