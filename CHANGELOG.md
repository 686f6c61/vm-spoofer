# Changelog

Registro de cambios de VM Spoofer. Cada versión incluye las funcionalidades añadidas, correcciones y mejoras realizadas.

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
