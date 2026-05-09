# Changelog

Registro de cambios de VM Spoofer. Cada versión incluye las funcionalidades añadidas, correcciones y mejoras realizadas.

## v1.1.2 (10 de mayo de 2026)

### Seguridad operativa

- VRDE/RDP de VirtualBox queda desactivado por defecto en Linux y macOS.
- Si se habilita VRDE desde el asistente, solo escucha en `127.0.0.1` y en el puerto elegido.
- El post-install de Linux ya no instala ni activa SSH automáticamente.
- El post-install de `OK VM Proctoring` ya no bloquea módulos de Guest Additions.
- Los USB externos no se preseleccionan automáticamente; audio y micrófono usan audio-in/audio-out.
- Los filtros USB creados por la herramienta quedan prefijados para poder limpiarlos durante restauración.

### Robustez

- Linux detecta correctamente firmware EFI/BIOS antes de escribir DMI/SMBIOS.
- Backups con JSON generado mediante APIs estructuradas (`jq`/`ConvertTo-Json`) y copia `.vbox` cuando está disponible.
- Restauración ampliada para recursos, red, gráficos, paravirtualización, VRDE y extradata.
- Backup/restauración cubre audio, entrada/salida de audio, portapapeles, drag-and-drop y USB xHCI.
- Validación de MAC manual con o sin separadores.
- Errores críticos de `VBoxManage` dejan de ocultarse durante aplicación de cambios.
- Reemplazos `sed` del post-install Linux escapan `/`, `\` y `&`.

### Verificación y mantenimiento

- Añadido `launcher.js` con menu guiado para preparar/restaurar VMs, verificar, auditar, validar hooks y generar informes.
- El launcher prioriza el perfil `OK VM Proctoring` y separa las herramientas fuera de alcance proctoring para no mezclar aceptación con diagnóstico avanzado.
- Añadida opción de launcher para conectar webcam por passthrough de VirtualBox en una VM arrancada.
- Añadidos launchers `start.sh`, `start.command` y `start.ps1` para reducir el uso manual de comandos.
- Añadido `guest-cleanup-linux.sh` para limpieza estricta de artefactos guest en Linux.
- Añadida opción de launcher para modo estricto/headless (`graphicscontroller none`) en cualquier VM apagada.
- Añadido `check.js` para verificación con `systeminformation` y modo avanzado por SO (`--advanced`).
- `check.js` replica por defecto las llamadas observadas del cliente: `system`, `diskLayout`, `processes`, `osInfo`, `mem` y `cpu`.
- `check.js` permite validar la lista exacta `bannedPrograms` con `--banned-programs <file>`.
- `check.js` acepta catálogos locales estructurados por plataforma con `--banned-platform`.
- Añadido `banned-programs.json` con el catálogo estructurado de programas bloqueados por plataforma.
- Añadido `app-policy.json` para declarar el modelo denylist: lo listado bloquea, lo no listado queda permitido salvo regla externa.
- Añadido `process-watch.js` para validar dinámicamente `systeminformation.processes()` mientras se abre software dentro de la VM.
- Añadido `BANNED_PROGRAMS.md` con alcance de la detección nominal por procesos.
- Añadido `input-hook-check.js` para validar de forma consentida `uiohook-napi` y `keyspy@1.1.1`.
- Añadido `validation-runner.js` para generar bundles de validación por VM/SO.
- `validation-runner.js` y `process-watch.js` ocultan rutas locales y hostname por defecto; `--include-local-details` conserva esos datos solo si se piden expresamente.
- Añadido `OK_VM_PROCTORING.md` con alcance exacto de `OK VM Proctoring`.
- Añadido workflow CI para sintaxis Bash, JSON, Node y PowerShell.
- Añadidos `SECURITY.md` y licencia propietaria.
- `.gitignore` ampliado para excluir logs, backups, bundles de validación, imágenes/discos de VM, exports y secretos locales.

---

## v0.2.0 (28 de marzo de 2026)

### Soporte para macOS

- Nuevo script `vm-spoofer-mac.sh` para macOS con soporte para Intel y Apple Silicon
- Detección automática de arquitectura del Mac (x86_64 / arm64) mostrada en cada pantalla
- Interfaz con `dialog` (instalable vía Homebrew) en lugar de `whiptail`
- Activación automática de micrófono y altavoces integrados del Mac (audio-in/audio-out de VirtualBox)
- Nota sobre la cámara FaceTime: no es USB, VirtualBox no puede redirigirla. Software como OBS Virtual Camera puede ser detectado por herramientas de análisis. Se recomienda usar una webcam USB externa si se necesita cámara en la VM
- Adaptación de comandos del sistema: `sysctl` en lugar de `free`/`nproc`, `ifconfig` en lugar de `ip`, `uuidgen` en lugar de `/proc/sys/kernel/random/uuid`
- Búsqueda de VBoxManage en múltiples rutas de macOS (`/opt/homebrew`, `/usr/local`, `/Applications`)
- Oferta de instalación automática de dependencias con Homebrew si faltan
- Nuevas instrucciones: `INSTRUCCIONES-MACOS.txt` con sección específica sobre Apple Silicon y cámara

### Mejoras generales

- Explicación detallada de cada dependencia en las tres instrucciones (Windows, Linux, macOS) para usuarios sin experiencia técnica
- Paso de permisos de ejecución (`chmod +x`) añadido en instrucciones de Linux y macOS
- Tabla de diferencias entre plataformas actualizada a 3 columnas (Windows, Linux, macOS)
- README actualizado: macOS como plataforma soportada, nota sobre cámara FaceTime y webcam USB

---

## v0.1 (27 de marzo de 2026)

Primera versión pública del sistema de camuflaje de máquinas virtuales. VM Spoofer permite modificar los identificadores de hardware de una VM de VirtualBox para que herramientas de detección como `systeminformation` no la identifiquen como virtual. Incluye asistentes interactivos para Windows y Linux, una base de datos con hardware real del mercado actual y un verificador para comprobar el resultado.

### Funcionalidades principales

- Asistente interactivo paso a paso para Windows (PowerShell) y Linux (Bash + whiptail)
- Detección automática de todas las VMs de VirtualBox instaladas
- Gestión automática del estado de la VM: si está encendida, guardada, pausada o bloqueada, el script la prepara sin intervención del usuario

### Base de datos de hardware

- 43 perfiles de fabricante: Lenovo (ThinkPad, IdeaPad, Yoga), Dell (XPS, Latitude, Inspiron, Precision), HP (EliteBook, Spectre, Pavilion, ProBook, OMEN), ASUS (ZenBook, VivoBook, ROG, TUF), Apple (MacBook Pro/Air, iMac, Mac Mini, Mac Studio), Acer (Aspire, Nitro, Swift), Microsoft Surface, MSI (Stealth, Raider, Prestige), Samsung, Huawei, Razer, Framework, PC sobremesa genérico
- 38 procesadores: Intel Core i3-i9 (12th-14th Gen), Intel Core Ultra 5/7/9 (Meteor Lake, Arrow Lake), AMD Ryzen 5-9 (Zen4, Zen5), AMD Ryzen AI, Apple M1 a M4 Pro
- 24 discos: Samsung (860-990 EVO/Pro), WD (SN580-SN7100), Kingston (A400, NV2, FURY), Crucial (MX500, P5, T700 Gen5), Seagate, SK Hynix, Intel, Toshiba, Apple SSD
- 36 tarjetas gráficas: Intel UHD/Iris/Arc (A580-B580), NVIDIA GTX 1660 a RTX 5090, AMD Radeon Vega/680M-890M y RX 7600 a 9070XT, Apple M1-M4 GPU
- 22 tarjetas de red con prefijos MAC OUI reales: Intel Wi-Fi 6/6E/7, Realtek, Broadcom, Qualcomm, MediaTek, Killer, Apple
- 9 plantillas de chipset PCI: Intel 12th-14th Gen, Meteor Lake, Arrow Lake, AMD Zen4/Zen5, Apple Intel, Apple Silicon

### Camuflaje

- Cambio completo de DMI/SMBIOS: fabricante, modelo, versión, serial, UUID, BIOS, placa base, chasis
- Modificación de tablas ACPI (OEM ID, Creator ID) según fabricante
- Suplantación de disco: modelo, número de serie (generado con prefijo real), firmware
- Generador de MAC address con tres modos: automático, manual y regenerar
- Desactivación de paravirtualización y ocultación de VMMDev
- Script de post-instalación para Linux: camufla lspci y bloquea módulos del kernel (vboxguest, vboxsf, vboxvideo)

### Periféricos

- Detección automática de cámaras, micrófonos y altavoces USB conectados al host
- Conexión automática de dispositivos USB seleccionados cada vez que arranca la VM
- Posibilidad de simular más RAM y CPUs de los que tiene asignados la VM

### Backup y restauración

- Backup automático de la configuración original antes de aplicar el camuflaje
- Solo se guarda el primer backup (configuración original real, no sobreescribe)
- Opción de restaurar cualquier VM a su estado original desde el menú principal

### Verificación

- Script check.js para verificar el camuflaje con systeminformation (Node.js)
- Instrucciones de verificación con PowerShell (Windows) y dmidecode/lspci (Linux)
- Tabla de indicadores de detección con nivel de fiabilidad

### Documentación

- README completo con explicación del problema, funcionamiento, capturas de pantalla y FAQ
- Instrucciones separadas para Windows y Linux
- 27 capturas de pantalla (10 Windows, 17 Linux)
