# Banned Programs Scope

## Observed Client Behavior

The target client obtains banned programs with this priority:

1. `course.bannedPrograms`
2. `entity.bannedPrograms`
3. bundled local `banned-programs.json` fallback

Remote course/entity values are decrypted/decoded by the client and normalized into a flat, comma-separated, lowercase list. The bundled fallback catalog is structured by category, program and platform.

The observed client-side detection is nominal:

- process inventory comes from `systeminformation.processes()`,
- matching is based on process names or, on macOS, names derived from application paths,
- no hash, code-signing identity, Team ID, bundle identifier, notarization check or binary reputation was observed in the local client logic.

Backend-side controls may still exist, but they are not verifiable from the analyzed client artifact.

## Local Catalog Metrics

The repository includes the structured fixture as `banned-programs.json`. It is the operative denylist used by:

```bash
node check.js --banned-programs banned-programs.json --banned-platform auto
node process-watch.js --banned-programs banned-programs.json --banned-platform auto --duration 60 --interval 2
```

The decision model is explicit in `app-policy.json`: this is denylist-based validation. A matching process is blocked; a non-matching process is allowed unless a separate customer rule is provided.

Observed fallback catalog metrics:

| Metric | Value |
| --- | ---: |
| Categories | 17 |
| Programs | 165 |
| Platform aliases | 332 |
| Windows entries | 160 |
| macOS entries | 116 |
| Linux entries | 56 |

Observed categories:

- Procesadores de texto
- Lectores de PDF
- Hojas de cálculo
- Clientes de correo
- Navegadores web
- Herramientas de conversación
- Cámaras virtuales
- Exploradores de archivos
- Reproductores multimedia
- Diapositivas
- Screenshots / Screen Recorder
- Control remoto
- Pentesting
- Editores de código
- Máquinas virtuales
- Clientes de bases de datos
- Ofimática Open Source

## Validation

Flat remote-style list:

```bash
node check.js --banned-programs banned-programs.txt
```

Structured local fallback catalog:

```bash
node check.js --banned-programs banned-programs.json --banned-platform auto
```

Force a platform slice:

```bash
node check.js --banned-programs banned-programs.json --banned-platform windows
node check.js --banned-programs banned-programs.json --banned-platform macos
node check.js --banned-programs banned-programs.json --banned-platform linux
```

Use `--banned-platform all` only for catalog QA. Delivery validation should use the platform actually running inside the VM.

Dynamic validation while opening software inside the VM:

```bash
node process-watch.js --banned-programs banned-programs.txt --duration 60 --interval 2
node process-watch.js --banned-programs banned-programs.json --banned-platform auto --duration 60 --interval 2
```

`process-watch.js` keeps polling `systeminformation.processes()` during the test window and fails if the opened software, helper process or path-derived app name matches the active `bannedPrograms` list.

## OK VM Proctoring Impact

Guest Additions remain enabled in OK VM Proctoring. Therefore:

- if `bannedPrograms` contains the VirtualBox GUI/manager process names running on the host, that is only relevant if those processes are visible inside the guest process list;
- if `bannedPrograms` contains Guest Additions process names visible inside the guest, such as `VBoxService` or `VBoxClient`, OK VM Proctoring will fail unless the list is adjusted or a separate advanced track is approved.
