#!/usr/bin/env node
"use strict";

const childProcess = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");
const readline = require("readline");

const repoDir = __dirname;
const nodeBin = process.execPath;

function rel(fileName) {
  return path.join(repoDir, fileName);
}

function ask(question, fallback = "") {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((resolve) => {
    const suffix = fallback ? ` [${fallback}]` : "";
    rl.question(`${question}${suffix}: `, (answer) => {
      rl.close();
      resolve(answer.trim() || fallback);
    });
  });
}

async function yesNo(question, fallback = true) {
  const marker = fallback ? "S/n" : "s/N";
  const answer = (await ask(`${question} (${marker})`)).toLowerCase();
  if (!answer) return fallback;
  return ["s", "si", "y", "yes"].includes(answer);
}

function run(command, args, options = {}) {
  console.log("");
  console.log(`> ${[command, ...args].join(" ")}`);
  const result = childProcess.spawnSync(command, args, {
    cwd: repoDir,
    stdio: "inherit",
    shell: options.shell || false,
    env: process.env,
  });
  if (result.error) {
    console.error(`No se pudo ejecutar: ${result.error.message}`);
    return 2;
  }
  return typeof result.status === "number" ? result.status : 2;
}

function commandExists(command) {
  const checker = process.platform === "win32" ? "where" : "command";
  const args = process.platform === "win32" ? [command] : ["-v", command];
  const result = childProcess.spawnSync(checker, args, {
    stdio: "ignore",
    shell: process.platform !== "win32",
  });
  return result.status === 0;
}

function packageInstalled(name) {
  try {
    require.resolve(`${name}/package.json`, { paths: [repoDir, process.cwd()] });
    return true;
  } catch (error) {
    return false;
  }
}

async function ensurePackage(name, spec) {
  if (packageInstalled(name)) return true;
  console.log("");
  console.log(`Falta el paquete Node: ${spec}`);
  if (!(await yesNo("Instalarlo ahora con npm?", true))) return false;
  return run("npm", ["install", spec]) === 0;
}

function platformName() {
  if (process.platform === "win32") return "Windows";
  if (process.platform === "darwin") return "macOS";
  if (process.platform === "linux") return "Linux";
  return process.platform;
}

function printHeader() {
  console.clear();
  console.log("============================================");
  console.log("  VM Spoofer - Menu de ejecucion");
  console.log("============================================");
  console.log(`Sistema detectado: ${platformName()} ${os.arch()}`);
  console.log("");
}

async function pause() {
  await ask("Pulsa Enter para continuar");
}

async function runHostSpoofer() {
  console.log("");
  console.log("Esta opcion se ejecuta en el HOST donde esta VirtualBox.");
  console.log("Aqui eliges el sistema aparente: fabricante, modelo, CPU, disco, red, GPU y chipset.");
  console.log("Aplica/restaura el perfil OK VM Proctoring: escritorio normal, audio, Guest Additions intactas.");
  if (!(await yesNo("Continuar?", true))) return;

  if (process.platform === "linux") {
    run("bash", [rel("vm-spoofer.sh")]);
    return;
  }

  if (process.platform === "darwin") {
    run("bash", [rel("vm-spoofer-mac.sh")]);
    return;
  }

  if (process.platform === "win32") {
    const shell = commandExists("pwsh") ? "pwsh" : "powershell.exe";
    run(shell, ["-ExecutionPolicy", "Bypass", "-File", rel("vm-spoofer.ps1")]);
    return;
  }

  console.log("Plataforma no soportada para preparar VMs desde el host.");
}

function linuxNodeCommand(script, extraArgs) {
  if (process.platform !== "linux") return [nodeBin, [script, ...extraArgs]];
  if (typeof process.getuid === "function" && process.getuid() === 0) {
    return [nodeBin, [script, ...extraArgs]];
  }
  return ["sudo", ["-E", nodeBin, script, ...extraArgs]];
}

async function runCheck(advanced) {
  if (!(await ensurePackage("systeminformation", "systeminformation@5.31.6"))) return;
  const script = rel("check.js");
  const args = advanced ? ["--advanced"] : [];
  const bannedPrograms = await ask("Ruta bannedPrograms opcional");
  if (bannedPrograms) {
    args.push("--banned-programs", bannedPrograms);
    const platform = await ask("Plataforma del catalogo bannedPrograms", "auto");
    args.push("--banned-platform", platform);
  }
  const [command, commandArgs] = advanced || process.platform === "linux"
    ? linuxNodeCommand(script, args)
    : [nodeBin, [script, ...args]];
  run(command, commandArgs);
}

async function chooseHookProvider() {
  console.log("");
  console.log("Proveedor de hooks:");
  console.log("  [1] uiohook-napi@1.5.5");
  console.log("  [2] keyspy@1.1.1");
  console.log("  [3] auto");
  const choice = await ask("Elige una opcion", "2");
  if (choice === "1") return { provider: "uiohook-napi", packageName: "uiohook-napi", spec: "uiohook-napi@1.5.5" };
  if (choice === "3") return { provider: "auto", packageName: "", spec: "" };
  return { provider: "keyspy", packageName: "keyspy", spec: "keyspy@1.1.1" };
}

async function runInputHooks() {
  console.log("");
  console.log("Esta prueba requiere consentimiento y una sesion grafica real.");
  console.log("No guarda teclas, texto, portapapeles ni coordenadas: solo contadores.");
  if (!(await yesNo("Continuar?", true))) return;

  const selected = await chooseHookProvider();
  if (selected.provider !== "auto" && !(await ensurePackage(selected.packageName, selected.spec))) return;
  if (selected.provider === "auto" && !packageInstalled("uiohook-napi") && !packageInstalled("keyspy")) {
    console.log("No hay proveedor instalado. Instala uiohook-napi@1.5.5 o keyspy@1.1.1.");
    if (await yesNo("Instalar keyspy@1.1.1 ahora?", true)) {
      if (!(await ensurePackage("keyspy", "keyspy@1.1.1"))) return;
    } else {
      return;
    }
  }

  const duration = await ask("Duracion en segundos", "15");
  run(nodeBin, [rel("input-hook-check.js"), "--provider", selected.provider, "--duration", duration]);
}

async function runProcessWatch() {
  if (!(await ensurePackage("systeminformation", "systeminformation@5.31.6"))) return;

  console.log("");
  console.log("Esta prueba se ejecuta dentro de la VM.");
  console.log("Durante la ventana de prueba, abre el software que quieres analizar.");
  console.log("Se usa systeminformation.processes(), igual que el cliente observado.");

  const bannedPrograms = await ask("Ruta bannedPrograms");
  if (!bannedPrograms) {
    console.log("Necesito una lista o catalogo bannedPrograms para comparar procesos.");
    return;
  }

  const platform = await ask("Plataforma del catalogo bannedPrograms", "auto");
  const duration = await ask("Duracion en segundos", "60");
  const interval = await ask("Intervalo de muestreo en segundos", "2");
  const commandArgs = [
    rel("process-watch.js"),
    "--banned-programs",
    bannedPrograms,
    "--banned-platform",
    platform,
    "--duration",
    duration,
    "--interval",
    interval,
  ];
  run(nodeBin, commandArgs);
}

async function generateBundle() {
  if (!(await ensurePackage("systeminformation", "systeminformation@5.31.6"))) return;

  const defaultOut = path.join("validation-runs", `${process.platform}-${new Date().toISOString().slice(0, 10)}`);
  const outDir = await ask("Carpeta del informe", defaultOut);
  const args = [rel("validation-runner.js"), "--out", outDir];

  const includeAdvanced = await yesNo("Incluir diagnostico fuera de alcance proctoring? No afecta a OK VM Proctoring", false);
  if (includeAdvanced) args.push("--advanced");

  if (await yesNo("Incluir prueba de hooks de teclado/raton?", false)) {
    const selected = await chooseHookProvider();
    if (selected.provider !== "auto" && !(await ensurePackage(selected.packageName, selected.spec))) return;
    args.push("--run-input-hooks", "--hook-provider", selected.provider);
    args.push("--hook-duration", await ask("Duracion de hooks en segundos", "15"));
    if (await yesNo("Ya tienes consentimiento para ejecutar la prueba?", true)) args.push("--yes");
  }

  const bannedPrograms = await ask("Ruta bannedPrograms opcional");
  if (bannedPrograms) {
    args.push("--banned-programs", bannedPrograms);
    args.push("--banned-platform", await ask("Plataforma del catalogo bannedPrograms", "auto"));
    if (await yesNo("Incluir watch de procesos para abrir software durante el informe?", false)) {
      args.push("--run-process-watch");
      args.push("--process-watch-duration", await ask("Duracion process-watch en segundos", "60"));
      args.push("--process-watch-interval", await ask("Intervalo process-watch en segundos", "2"));
    }
  }

  const clientCommand = await ask("Comando del detector del cliente (opcional)");
  if (clientCommand) args.push("--client-command", clientCommand);

  run(nodeBin, args);
}

function showDocs() {
  console.log("");
  console.log("Documentacion principal:");
  console.log(`- ${rel("README.md")}`);
  console.log(`- ${rel("OK_VM_PROCTORING.md")}`);
  console.log(`- ${rel("BANNED_PROGRAMS.md")}`);
  console.log(`- ${rel("SECURITY.md")}`);
  console.log(`- ${rel("INSTRUCCIONES-LINUX.txt")}`);
  console.log(`- ${rel("INSTRUCCIONES-MACOS.txt")}`);
  console.log(`- ${rel("INSTRUCCIONES-WINDOWS.txt")}`);
}

function findVBoxManage() {
  const candidates = [
    "VBoxManage",
    "/Applications/VirtualBox.app/Contents/MacOS/VBoxManage",
    "C:\\Program Files\\Oracle\\VirtualBox\\VBoxManage.exe",
  ];
  for (const candidate of candidates) {
    if (candidate === "VBoxManage" && commandExists(candidate)) return candidate;
    if (candidate !== "VBoxManage" && fs.existsSync(candidate)) return candidate;
  }
  return "";
}

function listVirtualBoxVms(vbox) {
  const result = childProcess.spawnSync(vbox, ["list", "vms"], {
    cwd: repoDir,
    encoding: "utf8",
  });
  if (result.status !== 0) return [];
  return (result.stdout || "")
    .split(/\r?\n/)
    .map((line) => {
      const match = line.match(/^"(.+)"\s+\{([^}]+)\}/);
      return match ? { name: match[1], uuid: match[2] } : null;
    })
    .filter(Boolean);
}

function vmState(vbox, vmName) {
  const result = childProcess.spawnSync(vbox, ["showvminfo", vmName, "--machinereadable"], {
    cwd: repoDir,
    encoding: "utf8",
  });
  const match = (result.stdout || "").match(/^VMState="([^"]+)"/m);
  return match ? match[1] : "unknown";
}

function listWebcams(vbox) {
  const result = childProcess.spawnSync(vbox, ["list", "webcams"], {
    cwd: repoDir,
    encoding: "utf8",
  });
  if (result.status !== 0) return [];

  return (result.stdout || "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .map((line) => {
      const match = line.match(/^(\.\d+)\s+(.+)$/);
      if (!match) return null;
      return {
        alias: match[1],
        label: match[2].replace(/^"|"$/g, ""),
      };
    })
    .filter(Boolean);
}

async function attachWebcam() {
  console.log("");
  console.log("Conectar webcam de VirtualBox:");
  console.log("- Usa el passthrough de webcam de VirtualBox, no filtros USB genericos.");
  console.log("- La VM debe estar arrancada en modo escritorio.");
  console.log("- Puede requerir Extension Pack y permisos de camara del host.");
  if (!(await yesNo("Continuar?", true))) return;

  const vbox = findVBoxManage();
  if (!vbox) {
    console.log("No encuentro VBoxManage en este sistema.");
    return;
  }

  const running = listVirtualBoxVms(vbox).filter((vm) => vmState(vbox, vm.name) === "running");
  if (running.length === 0) {
    console.log("No hay VMs arrancadas. Abre la VM en modo escritorio y vuelve a intentarlo.");
    return;
  }

  const webcams = listWebcams(vbox);
  if (webcams.length === 0) {
    console.log("VirtualBox no lista webcams disponibles en el host.");
    console.log("Revisa permisos del host y Extension Pack si tu instalacion lo requiere.");
    return;
  }

  console.log("");
  running.forEach((vm, index) => console.log(`  [${index + 1}] ${vm.name}`));
  const vmChoice = Number(await ask("Elige la VM arrancada", "1")) - 1;
  if (vmChoice < 0 || vmChoice >= running.length) {
    console.log("Opcion no valida.");
    return;
  }

  console.log("");
  webcams.forEach((webcam, index) => console.log(`  [${index + 1}] ${webcam.alias} ${webcam.label}`));
  const webcamChoice = Number(await ask("Elige la webcam", "1")) - 1;
  if (webcamChoice < 0 || webcamChoice >= webcams.length) {
    console.log("Opcion no valida.");
    return;
  }

  const selectedVm = running[vmChoice].name;
  const selectedWebcam = webcams[webcamChoice].alias;
  run(vbox, ["controlvm", selectedVm, "webcam", "attach", selectedWebcam, "MaxFramerate=30"]);
}

async function applyStrictHeadlessMode() {
  console.log("");
  console.log("Modo estricto/headless:");
  console.log("- Quita el controlador grafico virtual para eliminar el PCI VMware 0x15ad.");
  console.log("- La VM queda pensada para headless/SSH/RDP/agentes, no para escritorio local de VirtualBox.");
  console.log("- No elimina el dispositivo VMMDev 0x80ee ni ACPI VBOXBIOS.");
  if (!(await yesNo("Continuar?", false))) return;

  const vbox = findVBoxManage();
  if (!vbox) {
    console.log("No encuentro VBoxManage en este sistema.");
    return;
  }

  const vms = listVirtualBoxVms(vbox);
  if (vms.length === 0) {
    console.log("No hay VMs registradas en VirtualBox.");
    return;
  }

  console.log("");
  vms.forEach((vm, index) => console.log(`  [${index + 1}] ${vm.name}`));
  const choice = Number(await ask("Elige la VM", "1")) - 1;
  if (choice < 0 || choice >= vms.length) {
    console.log("Opcion no valida.");
    return;
  }

  const selected = vms[choice];
  const state = vmState(vbox, selected.name);
  if (state !== "poweroff") {
    console.log(`La VM esta en estado '${state}'. Apagala antes de aplicar modo estricto/headless.`);
    return;
  }

  run(vbox, ["modifyvm", selected.name, "--graphicscontroller", "none", "--accelerate-3d", "off"]);
  console.log("");
  console.log("[OK] Modo estricto/headless aplicado.");
}

async function runLinuxGuestCleanup() {
  if (process.platform !== "linux") {
    console.log("La limpieza guest automatica esta implementada para Linux.");
    return;
  }
  console.log("");
  console.log("Limpieza estricta del invitado Linux:");
  console.log("- Desactiva/purga Guest Additions, SPICE, QEMU guest agent y VMware tools si existen.");
  console.log("- Bloquea modulos guest y limpia logs historicos si eliges modo estricto.");
  console.log("- Ejecutala dentro de la VM Linux, no en el host, salvo que el host sea el sistema a auditar.");
  if (!(await yesNo("Continuar?", false))) return;

  const strict = await yesNo("Usar modo estricto?", true);
  const args = ["bash", rel("guest-cleanup-linux.sh")];
  if (strict) args.push("--strict");
  else args.push("--clean-logs");
  const [command, commandArgs] = typeof process.getuid === "function" && process.getuid() === 0
    ? ["bash", [rel("guest-cleanup-linux.sh"), ...args.slice(2)]]
    : ["sudo", args];
  run(command, commandArgs);
}

async function advancedTools() {
  console.log("");
  console.log("Fuera de alcance proctoring:");
  console.log("  [1] Aplicar modo estricto/headless a una VM");
  console.log("  [2] Limpieza estricta de invitado Linux");
  console.log("  [0] Volver");
  const choice = await ask("Elige una opcion", "0");
  if (choice === "1") await applyStrictHeadlessMode();
  else if (choice === "2") await runLinuxGuestCleanup();
}

async function mainMenu() {
  while (true) {
    printHeader();
    console.log("Que quieres hacer?");
    console.log("");
    console.log("  [1] Elegir sistema aparente y preparar VM");
    console.log("  [2] Verificar systeminformation de esta VM");
    console.log("  [3] Validar software abierto contra bannedPrograms");
    console.log("  [4] Validar hooks de teclado/raton");
    console.log("  [5] Generar informe OK VM Proctoring");
    console.log("  [6] Conectar webcam a una VM arrancada");
    console.log("  [7] Fuera de alcance proctoring: diagnostico avanzado");
    console.log("  [8] Fuera de alcance proctoring: herramientas estrictas");
    console.log("  [9] Ver rutas de documentacion");
    console.log("  [0] Salir");
    console.log("");

    const choice = await ask("Elige una opcion", "1");
    if (choice === "0") return;
    if (choice === "1") await runHostSpoofer();
    else if (choice === "2") await runCheck(false);
    else if (choice === "3") await runProcessWatch();
    else if (choice === "4") await runInputHooks();
    else if (choice === "5") await generateBundle();
    else if (choice === "6") await attachWebcam();
    else if (choice === "7") await runCheck(true);
    else if (choice === "8") await advancedTools();
    else if (choice === "9") showDocs();
    else console.log("Opcion no valida.");
    await pause();
  }
}

if (!fs.existsSync(rel("hardware-db.json"))) {
  console.error("No se encuentra hardware-db.json. Ejecuta el launcher desde la carpeta del proyecto.");
  process.exit(1);
}

mainMenu().catch((error) => {
  console.error(error && error.stack ? error.stack : error);
  process.exit(1);
});
