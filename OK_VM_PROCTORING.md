# OK VM Proctoring

## Goal

OK VM Proctoring keeps VirtualBox stock and preserves a normal desktop VM experience:

- Guest Additions stay installed and running.
- The VM starts in GUI mode.
- Screen resize, mouse integration, clipboard and drag-and-drop can keep working.
- Audio output and microphone input are enabled through VirtualBox audio.
- Webcam support uses VirtualBox webcam passthrough when available, not broad USB capture by default.

The acceptance target is limited to these libraries:

- `systeminformation`
- `uiohook-napi`
- `keyspy@1.1.1`

## What Must Pass

Required gates:

```bash
node check.js
node process-watch.js --banned-programs banned-programs.txt --duration 60
node input-hook-check.js --provider uiohook-napi --duration 15
node input-hook-check.js --provider keyspy --duration 15
```

The input-hook checks require an interactive desktop session and explicit consent. They only report counters; they do not store key names, typed text, clipboard data or mouse coordinates.

## `systeminformation` Scope

The default `check.js` scope matches the calls observed in the target bundle:

- `si.system()`
- `si.diskLayout()`
- `si.processes()`
- `si.osInfo()`
- `si.mem()`
- `si.cpu()`

It also explicitly fails when `si.system().virtual` is `true` or when `virtualHost` contains a known VM vendor.

`si.processes()` is run because the target app compares the process inventory with `bannedPrograms`. When that list is available, validate it with:

```bash
node check.js --banned-programs banned-programs.txt
```

The same flag also accepts the structured local fallback catalog:

```bash
node check.js --banned-programs banned-programs.json --banned-platform auto
```

To validate the dynamic case, run `process-watch.js` inside the VM and open the analysis software during the watch window:

```bash
node process-watch.js --banned-programs banned-programs.txt --duration 60 --interval 2
```

By default, VM-looking process names are reported as notes instead of blocking findings because Guest Additions are intentionally kept active. If the target `bannedPrograms` list includes `VBoxService`, `VBoxClient` or another VirtualBox process, OK VM Proctoring will fail unless that requirement is changed or a separate advanced strategy is approved.

Extra hardware fields not observed in the target bundle are available with:

```bash
node check.js --broad-hardware
```

Service inventory is available with:

```bash
node check.js --include-services
```

## Outside OK VM Proctoring Scope

OK VM Proctoring does not promise to hide:

- raw PCI IDs such as `0x80ee:0xcafe`,
- ACPI table strings such as `VBOXBIOS`,
- CPUID hypervisor signals,
- timing side channels,
- Guest Additions processes, services, drivers or packages,
- arbitrary detector-specific heuristics outside the three target libraries.

Those belong to out-of-scope proctoring diagnostics or to a VirtualBox patch/fork track.

## Peripheral Policy

Audio and microphone:

- enabled with `--audio-enabled on`,
- `--audio-in on`,
- `--audio-out on`,
- HDA controller.

Camera:

- prefer `VBoxManage controlvm <vm> webcam attach .0`,
- requires the VM to be running,
- may require VirtualBox Extension Pack and host camera permissions.

USB:

- not selected by default,
- only use for specific external devices when the user chooses them.
