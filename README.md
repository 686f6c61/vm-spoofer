# VM Spoofer

Sistema para camuflar máquinas virtuales de VirtualBox en modo escritorio. Modifica identificadores de hardware para que el perfil `OK VM Proctoring` pase las llamadas observadas de `systeminformation` (`system`, `diskLayout`, `processes`, `osInfo`, `mem`, `cpu`) y las validaciones de `uiohook-napi` / `keyspy@1.1.1` sin romper Guest Additions ni la experiencia de usuario.

Funciona en **Windows** (PowerShell), **Linux** (Bash + whiptail) y **macOS** (Bash + dialog). En macOS detecta automáticamente si el Mac es **Intel** o **Apple Silicon**.

Versión actual: `v1.1.2`.

> Uso previsto: laboratorios, QA, validación e integración en entornos propios o con autorización explícita. Antes de usarlo en un entorno de cliente, revisa `SECURITY.md`, crea snapshot/exportación de la VM y conserva la carpeta `backups/`.

---

## El problema

Cuando ejecutas una máquina virtual en VirtualBox, el sistema operativo invitado sabe que está dentro de una VM. Herramientas como `systeminformation` (Node.js), `dmidecode` (Linux) o WMI (Windows) leen los identificadores del hardware y encuentran valores como "VirtualBox", "Oracle", "VBOX HARDDISK" o prefijos MAC `08:00:27` que delatan inmediatamente que el sistema no es físico.

Esto es un problema en muchos contextos: software que rechaza ejecutarse en VMs, plataformas que detectan y bloquean entornos virtualizados, pruebas de seguridad donde necesitas que el sistema parezca real, o simplemente privacidad.

VM Spoofer resuelve `OK VM Proctoring` reemplazando esos identificadores por los de equipos reales del mercado. Una VM camuflada como un Lenovo ThinkPad X1 Carbon, un Dell XPS 15 o un Apple MacBook Pro debe verse coherente para el perfil de consultas de `systeminformation` que validamos; no se promete invisibilidad universal contra cualquier detector.

---

## Cómo funciona

VirtualBox almacena la configuración de cada VM en un archivo `.vbox` y permite modificar los identificadores de hardware mediante el comando `VBoxManage setextradata`. VM Spoofer automatiza este proceso: lee una base de datos con perfiles de hardware real (`hardware-db.json`), presenta un asistente interactivo donde eliges qué equipo quieres simular, y aplica todos los cambios de una sola vez.

Los cambios se aplican a nivel de VirtualBox, no dentro de la VM. Eso significa que no necesitas instalar nada en el sistema invitado para que el camuflaje funcione. El SO invitado simplemente lee los nuevos identificadores como si fueran hardware real.

En VMs Linux hay un paso adicional opcional de `OK VM Proctoring` que camufla los nombres de los dispositivos PCI visibles por `lspci` sin desinstalar ni bloquear Guest Additions. La limpieza estricta queda separada como fuera de alcance proctoring.

---

## Qué cambia exactamente

El camuflaje abarca todas las capas que las herramientas de detección consultan:

**DMI/SMBIOS** es la primera línea de detección. Contiene el fabricante del sistema, modelo, número de serie, UUID, versión de BIOS, fabricante de la placa base y tipo de chasis. VirtualBox por defecto pone "Oracle" y "VirtualBox" en estos campos. VM Spoofer los reemplaza por los valores exactos de un equipo real (por ejemplo, "LENOVO" con modelo "20Y7CTO1WW" y BIOS "N3HET91W" para un ThinkPad X1 Carbon).

**ACPI** es la tabla de configuración de energía del sistema. Incluye un OEM ID y un Creator ID que VirtualBox rellena con "VBOX". VM Spoofer los cambia al fabricante correspondiente (LENOVO, DELL, HP, APPLE, ALASKA para ASUS/MSI, etc.).

**Disco duro** es un indicador de fiabilidad media. VirtualBox por defecto llama al disco "VBOX HARDDISK" con vendor "VirtualBox". VM Spoofer lo cambia a un disco real (Samsung SSD 990 PRO, WD Black SN850X, etc.) con número de serie generado aleatoriamente usando el prefijo real del fabricante y una versión de firmware auténtica.

**Dirección MAC** es otro indicador habitual. VirtualBox asigna MACs con el prefijo `08:00:27` que está registrado a nombre de Oracle/VirtualBox. VM Spoofer genera una MAC con el prefijo del fabricante de red que elijas (Intel, Realtek, Broadcom, Killer, Apple, etc.) y un sufijo aleatorio.

**Paravirtualización** es un mecanismo que VirtualBox usa para comunicarse con el SO invitado de forma eficiente. Pero su presencia delata que hay un hipervisor. VM Spoofer la desactiva.

**VMMDev** es el dispositivo de comunicación entre VirtualBox y las Guest Additions. En OK VM Proctoring se mantiene porque Guest Additions deben funcionar; solo se desactiva la sincronización de hora expuesta por VMMDev.

**Dispositivos PCI** (solo Linux): `lspci` muestra los dispositivos de hardware emulados por VirtualBox con nombres como "VMware SVGA II Adapter" o "InnoTek VirtualBox Guest Service". El script de post-instalación para Linux crea un wrapper que reemplaza estos nombres por los del chipset real elegido, manteniendo Guest Additions.

**Periféricos de escritorio**: audio y micrófono se activan con audio-in/audio-out de VirtualBox. Para cámara se prioriza el passthrough de webcam de VirtualBox desde el launcher cuando está disponible. Los filtros USB quedan como opción manual para dispositivos externos concretos; no se seleccionan automáticamente para evitar capturas inesperadas.

---

## Qué hace el script paso a paso

| Paso | Qué hace | Por qué |
|---|---|---|
| Detectar VMs | Lista todas las VMs de VirtualBox con su SO, RAM, CPUs y estado | Para que elijas cuál camuflar sin tener que recordar nombres |
| Preparar VM | Si la VM está encendida, guardada, pausada o bloqueada, la pone en estado "apagada" automáticamente | VirtualBox no permite cambiar configuración con la VM en uso |
| Fabricante | Aplica un perfil DMI/SMBIOS completo (sistema, BIOS, placa base, chasis, ACPI) | Es la capa más importante de detección |
| CPU | Cambia el nombre del procesador que reporta el sistema | Coherencia con el perfil elegido |
| RAM/CPUs | Ajusta la RAM y cores de la VM | Permite simular un equipo con más recursos |
| Disco | Cambia modelo, serial y firmware del disco virtual | Evita "VBOX HARDDISK" |
| GPU | Cambia el nombre de la tarjeta gráfica (en Linux vía post-install) | Evita "VMware SVGA II Adapter" |
| Red | Genera una MAC con prefijo del fabricante real | Evita el prefijo 08:00:27 de VirtualBox |
| Chipset | Plantilla que cambia todos los dispositivos PCI (en Linux vía post-install) | Evita nombres de chipset virtual en lspci |
| Periféricos | Activa audio/micro y permite webcam passthrough o USB externo opcional | Mantiene la VM como escritorio usable |

---

## Archivos

| Archivo | Descripción |
|---|---|
| `start.sh` | Launcher recomendado para Linux |
| `start.command` | Launcher recomendado para macOS |
| `start.ps1` | Launcher recomendado para Windows |
| `launcher.js` | Menu guiado comun para preparar, verificar y generar informes |
| `guest-cleanup-linux.sh` | Limpieza estricta de artefactos guest en Linux |
| `vm-spoofer.ps1` | Script principal para Windows (PowerShell) |
| `vm-spoofer.sh` | Script principal para Linux (Bash + whiptail) |
| `vm-spoofer-mac.sh` | Script principal para macOS Intel/Apple Silicon (Bash + dialog) |
| `hardware-db.json` | Base de datos con perfiles de hardware reales (43 fabricantes, 38 CPUs, 24 discos, 36 GPUs, 22 NICs, 9 chipsets) |
| `banned-programs.json` | Catálogo local de programas bloqueados por plataforma para validación con `systeminformation.processes()` |
| `app-policy.json` | Política de decisión: denylist, permitido por defecto y reglas fuera de alcance |
| `check.js` | Script de verificación con systeminformation (Node.js) |
| `process-watch.js` | Verificador dinamico de `systeminformation.processes()` contra `bannedPrograms` mientras abres software dentro de la VM |
| `input-hook-check.js` | Verificador consentido de hooks globales con `uiohook-napi` o `keyspy` |
| `validation-runner.js` | Generador de bundle de validación por VM/SO |
| `OK_VM_PROCTORING.md` | Alcance exacto de OK VM Proctoring: Guest Additions, systeminformation y hooks |
| `BANNED_PROGRAMS.md` | Alcance de detección nominal por `systeminformation.processes()` |
| `SECURITY.md` | Política de uso autorizado y seguridad operativa |
| `INSTRUCCIONES-WINDOWS.txt` | Guía paso a paso para Windows |
| `INSTRUCCIONES-LINUX.txt` | Guía paso a paso para Linux |
| `INSTRUCCIONES-MACOS.txt` | Guía paso a paso para macOS (Intel y Apple Silicon) |
| `img/` | Capturas de pantalla del asistente en Windows |

---

## Requisitos

### Windows
- VirtualBox (https://www.virtualbox.org)
- PowerShell (incluido en Windows 10/11)
- Node.js (https://nodejs.org) para el launcher y verificadores

### Linux
- VirtualBox (`sudo apt install virtualbox`)
- jq (`sudo apt install jq`)
- whiptail (`sudo apt install whiptail`)
- Node.js y npm (`sudo apt install nodejs npm`)

### macOS (Intel y Apple Silicon)
- VirtualBox (https://www.virtualbox.org)
- Homebrew (https://brew.sh)
- dialog (`brew install dialog`)
- jq (`brew install jq`)
- Node.js (`brew install node`)

Los cambios DMI/SMBIOS, disco, red y firmware se aplican desde el host. En Linux, el post-install opcional completa la parte visible por `lspci` sin desactivar Guest Additions. Para la verificación posterior se puede usar Node.js con `systeminformation`.

---

## Uso rápido

### Windows

```powershell
cd ruta\a\vm-spoofer
powershell -ExecutionPolicy Bypass -File start.ps1
```

### Linux

```bash
cd ruta/a/vm-spoofer
./start.sh
```

### macOS

```bash
cd ruta/a/vm-spoofer
./start.command
```

El launcher muestra un menu simple:

1. Elegir sistema aparente y preparar VM.
2. Verificar `systeminformation`.
3. Validar software abierto contra `bannedPrograms`.
4. Validar hooks de teclado/raton.
5. Generar informe `OK VM Proctoring`.
6. Conectar webcam a una VM arrancada.
7. Fuera de alcance proctoring: diagnostico avanzado.
8. Fuera de alcance proctoring: herramientas estrictas.
9. Ver rutas de documentacion.

No necesitas recordar comandos. Las herramientas tecnicas siguen disponibles debajo (`vm-spoofer.sh`, `vm-spoofer-mac.sh`, `vm-spoofer.ps1`, `check.js`, `validation-runner.js`), pero el flujo recomendado es usar el launcher.

El script de macOS detecta automáticamente si el Mac es Intel o Apple Silicon y lo muestra en cada pantalla del asistente.

El asistente guía en 8 pasos:

1. **Seleccionar VM** - detecta automáticamente las VMs instaladas
2. **Fabricante** - elige el equipo a simular
3. **Procesador** - CPU que aparecerá en el sistema
4. **RAM y CPUs** - recursos simulados (pueden ser mayores que los reales)
5. **Disco, GPU y Red** - periféricos con generador de MAC (auto/manual/regenerar)
6. **Chipset PCI** - plantilla de dispositivos PCI
7. **Periféricos** - audio/micro por VirtualBox y USB externo solo si lo eliges
8. **Confirmar y aplicar** - muestra resumen y aplica los cambios

No necesitas saber nada de VirtualBox ni de línea de comandos. El script hace todo el trabajo: detecta las VMs, gestiona su estado, aplica los cambios y genera los scripts de post-instalación si son necesarios.

La eleccion de fabricante/modelo/CPU/disco/GPU/NIC es el "maquillaje" del sistema. Para Windows y Linux usa perfiles PC coherentes; para macOS usa perfiles Apple solo si el guest realmente es macOS.

### Capturas de pantalla

#### Linux (Bash + whiptail)

| | |
|---|---|
| ![Bienvenida](img/linux-01-bienvenida.png) | ![Menú principal](img/linux-02-menu-principal.png) |
| Bienvenida | Menú principal |
| ![Seleccionar VM](img/linux-03-seleccionar-vm.png) | ![Fabricante](img/linux-04-fabricante.png) |
| Seleccionar VM | Fabricante |
| ![Procesador](img/linux-05-procesador.png) | ![RAM](img/linux-06-ram.png) |
| Procesador | RAM |
| ![Cores](img/linux-07-cores.png) | ![Disco](img/linux-08-disco.png) |
| Cores | Disco |
| ![GPU](img/linux-09-gpu.png) | ![Tarjeta de red](img/linux-10-red.png) |
| GPU | Tarjeta de red |
| ![Generador de MAC](img/linux-11-mac-generador.png) | ![Chipset PCI](img/linux-12-chipset.png) |
| Generador de MAC | Chipset PCI |
| ![Dispositivos USB](img/linux-13-usb.png) | ![Modo de red](img/linux-14-red-modo.png) |
| Dispositivos USB | Modo de red |
| ![Interfaz de red](img/linux-15-red-interfaz.png) | ![Resumen](img/linux-16-resumen.png) |
| Interfaz de red | Resumen |
| ![Resultado aplicado](img/linux-17-resultado.png) | |
| Resultado aplicado | |

#### Windows (PowerShell)

| | |
|---|---|
| ![Menú principal](img/win-01-menu-principal.png) | ![Seleccionar VM](img/win-02-seleccionar-vm.png) |
| Menú principal | Seleccionar VM |
| ![Fabricante](img/win-03-fabricante.png) | ![Procesador](img/win-04-procesador.png) |
| Fabricante | Procesador |
| ![RAM y CPUs](img/win-05-ram-cpus.png) | ![Disco](img/win-06-disco.png) |
| RAM y CPUs | Disco |
| ![GPU](img/win-07-gpu.png) | ![Red y MAC](img/win-08-red-mac.png) |
| GPU | Red y MAC |
| ![Chipset](img/win-09-chipset.png) | ![Resultado: Apple en Surface](img/win-10-resultado-apple-surface.png) |
| Chipset | Resultado: Apple en Surface |

---

## Verificación

Una vez aplicado el camuflaje y arrancada la VM, la forma más fiable de verificar que funciona es usar la librería `systeminformation` de Node.js con el verificador incluido.

### Con Node.js (recomendado)

Dentro de la VM, instalar Node.js (https://nodejs.org) y ejecutar:

```bash
mkdir vm-verify && cd vm-verify
npm install systeminformation@5.31.6
```

Copiar `check.js` a la carpeta y ejecutar:

```bash
node check.js        # Windows
sudo node check.js   # Linux (necesita sudo para acceder a DMI)
```

Fuera de alcance proctoring, para diagnóstico más estricto por sistema operativo:

```bash
node check.js --advanced        # Windows/macOS
sudo node check.js --advanced   # Linux
```

El modo avanzado añade checks específicos por SO: WMI/CIM y drivers en Windows, sysfs/ACPI/módulos en Linux, e `ioreg`/`system_profiler`/kexts en macOS. No forma parte de `OK VM Proctoring` salvo que el cliente active esas señales.

El verificador ejecuta también `systeminformation.processes()` porque el bundle observado compara procesos contra `bannedPrograms`. Cuando tengas esa lista, pásala así:

```bash
node check.js --banned-programs banned-programs.txt
```

Si usas el catálogo local estructurado por categorías/plataformas:

```bash
node check.js --banned-programs banned-programs.json --banned-platform auto
```

Para validar lo que ocurre al abrir software de analisis dentro de la VM, usa el watch dinamico. Durante la ventana de prueba abre la aplicacion que quieras comprobar:

```bash
node process-watch.js --banned-programs banned-programs.txt --duration 60 --interval 2
```

Si la lista incluye procesos de Guest Additions como `VBoxService` o `VBoxClient`, OK VM Proctoring fallará por requisito funcional del detector. En ese caso hay que decidir si se cambia la lista o se abre una línea avanzada separada.

Para ampliar fuera del bundle observado:

```bash
node check.js --broad-hardware
node check.js --include-services
```

Si el cliente usa librerías de hook global como `uiohook-napi` o `keyspy@1.1.1`, valida esa superficie por separado:

```bash
npm install uiohook-napi@1.5.5
node input-hook-check.js --provider uiohook-napi --duration 15

npm install keyspy@1.1.1
node input-hook-check.js --provider keyspy --duration 15
```

Ese verificador no registra teclas ni texto: solo comprueba que el hook recibe eventos reales de teclado/ratón.

Para empaquetar la evidencia de entrega:

```bash
node validation-runner.js --out validation-runs/linux-a515 \
  --banned-programs banned-programs.txt \
  --run-process-watch --process-watch-duration 60 \
  --run-input-hooks --hook-provider keyspy --hook-duration 15 --yes
```

El runner genera `metadata.json`, `steps.json`, salidas completas de cada verificador y un `summary.md` con el estado de aceptación.

El script analiza todos los indicadores de hardware y muestra un informe completo:

```
[SYSTEM]
manufacturer       Micro-Star International Co., Ltd.
model              Raider GE78 HX 13VH

[BIOS]
vendor             American Megatrends International, LLC.
version            E17RCIMS.10A

[DISKS]
- Samsung Samsung SSD 990 PRO 1TB serial=S6Z2NF037820

[GRAPHICS]
- Intel Corporation UHD Graphics 770

[FINDINGS]
No common VM indicators detected by this verifier.

Score: 0/100
```

Si el verificador muestra findings de VirtualBox, Oracle, VMware, QEMU, KVM o prefijos MAC virtuales, significa que algún indicador no se camufló correctamente. Revisa que la VM estaba apagada cuando aplicaste los cambios y, en Linux, que ejecutaste el script de post-instalación.

### Sin Node.js

Si no quieres instalar Node.js, puedes hacer una verificación rápida con las herramientas del sistema:

**Windows** (PowerShell):
```powershell
Get-CimInstance Win32_ComputerSystem | Format-List Manufacturer, Model
Get-CimInstance Win32_BIOS | Format-List Manufacturer, SMBIOSBIOSVersion
Get-CimInstance Win32_DiskDrive | Format-List Model, SerialNumber
```

**Linux** (terminal):
```bash
sudo dmidecode -s system-manufacturer
sudo dmidecode -s system-product-name
sudo dmidecode -s bios-vendor
lspci
```

En todos los casos, los valores deben mostrar el hardware que elegiste durante el asistente, nunca "VirtualBox", "Oracle", "VMware", "VBOX HARDDISK" ni el prefijo MAC `08:00:27`.

---

## Indicadores de detección

Estas son las fuentes de información que consultan las herramientas de detección de VMs y si VM Spoofer las cubre:

| Indicador | Qué consulta | Fiabilidad | Cubierto |
|---|---|---|---|
| `system.virtual` | DMI: fabricante y modelo del sistema | Alta | Sí |
| `system.virtualVendor` | DMI: vendor de virtualización | Alta | Sí |
| `system.virtualHost` | DMI: nombre del host virtual | Alta | Sí |
| `diskLayout.name` | Modelo del disco duro | Media | Sí |
| `diskLayout.vendor` | Fabricante del disco | Media | Sí |
| `graphics.vendor` | GPU (lspci en Linux, DMI en Windows) | Media | Sí |
| `networkInterfaces.mac` | Prefijo MAC de la tarjeta de red | Media | Sí |
| `chassis.type` | Tipo de chasis (notebook, desktop, tablet) | Baja | Sí |
| Módulos del kernel | vboxguest, vboxsf, vboxvideo | Media | No en OK VM Proctoring: Guest Additions deben funcionar |
| Dispositivos PCI | lspci: VMware SVGA, InnoTek Guest Service | Media | Sí, nombres visibles por wrapper Linux opcional |
| Combinación de todos | Correlación de múltiples fuentes | Muy alta | Sí |

La detección más robusta combina varios indicadores. Un disco "Samsung" con fabricante "VirtualBox" sería sospechoso. VM Spoofer cambia todas las capas para que sean coherentes entre sí.

---

## Base de datos de hardware

El archivo `hardware-db.json` contiene perfiles de hardware real extraídos de equipos del mercado actual. Cada perfil incluye todos los campos DMI/SMBIOS necesarios para una suplantación completa.

### Fabricantes (43 perfiles)

La base de datos cubre los fabricantes más comunes del mercado de portátiles, sobremesa y estaciones de trabajo. Cada fabricante tiene varios modelos representando diferentes gamas (básica, profesional, gaming, creativa).

| Marca | Modelos | Segmento |
|---|---|---|
| **Lenovo** | ThinkPad X1 Carbon Gen 10, ThinkPad T14 Gen 4, ThinkPad X1 Nano Gen 3, IdeaPad 5 Pro 16, Yoga 9i Gen 8 | Profesional, consumo, convertible |
| **Dell** | XPS 15 9530, XPS 13 9340, Latitude 5540, Inspiron 16 5630, Precision 5680 | Premium, profesional, consumo, workstation |
| **HP** | EliteBook 840 G10, Spectre x360 16, Pavilion 15, ProBook 450 G10, OMEN 16 | Profesional, premium, consumo, gaming |
| **ASUS** | ZenBook 14, VivoBook 15, ROG Strix G16, ROG Zephyrus G14, TUF Gaming F15 | Premium, consumo, gaming |
| **Apple** | MacBook Pro 16 (Intel 2019), MacBook Pro 14 (M1 Pro), MacBook Pro 16 (M3 Pro), MacBook Air 15 (M3), MacBook Air 13 (M2), iMac 24 (M3), Mac Mini (M2), Mac Studio (M2 Ultra) | Portátil, sobremesa, workstation |
| **Acer** | Aspire 5, Nitro 5, Swift Go 14 | Consumo, gaming, ultrabook |
| **Microsoft** | Surface Pro 9, Surface Laptop 5, Surface Laptop Studio 2 | Tablet, portátil, convertible |
| **MSI** | GS66 Stealth, Raider GE78 HX, Prestige 14 Evo | Gaming, creativo |
| **Samsung** | Galaxy Book3 Pro 360 | Premium convertible |
| **Huawei** | MateBook X Pro 2024 | Premium |
| **Razer** | Blade 16 | Gaming premium |
| **Framework** | Laptop 16 | Modular, reparable |
| **Genérico** | PC Sobremesa Intel (ASRock B660M), PC Sobremesa AMD (Gigabyte B650) | Sobremesa montado |

### Procesadores (38)

Todos los procesadores actuales del mercado están representados, incluyendo las últimas generaciones de Intel (Arrow Lake), AMD (Zen 5) y Apple (M4).

| Familia | Modelos |
|---|---|
| **Intel Core (12th-14th Gen)** | i3-13100, i3-1215U, i5-1235U/1335U/1345U/13600K/14600K, i7-1255U/1355U/1365U/13700K/14700K, i9-13900K/13900H/14900K |
| **Intel Core Ultra (Meteor/Arrow Lake)** | Ultra 5 125H, Ultra 7 155H/265K, Ultra 9 185H/285K |
| **AMD Ryzen (Zen 4/5)** | R5-7600X/7640HS/8645HS, R7-7800X3D/7840HS/8845HS, R9-7950X/7945HX/9950X, AI 9 HX 370 |
| **Apple Silicon** | M1, M2, M2 Pro, M3, M3 Pro, M3 Max, M4, M4 Pro |

### Discos (24)

Discos SSD NVMe, SATA y HDD de todos los fabricantes principales. Cada uno incluye modelo exacto, prefijo de serial real y versión de firmware auténtica.

| Fabricante | Modelos |
|---|---|
| **Samsung** | 860 EVO, 870 EVO, 970 EVO Plus, 980 Pro, 990 Pro 1TB/2TB, 990 EVO |
| **Western Digital** | Blue SN580, Blue SN770, Black SN850X, Black SN7100 |
| **Kingston** | A400, NV2, FURY Renegade |
| **Crucial** | MX500, P5 Plus, T700 (Gen5) |
| **Seagate** | Barracuda HDD, FireCuda 530 |
| **Otros** | SK Hynix P41 Platinum, Intel 670p, Toshiba MQ04, Apple AP0512Q/AP1024Z |

### Tarjetas gráficas (36)

Desde gráficas integradas hasta las tarjetas dedicadas más potentes del mercado, incluyendo la generación RTX 5000 de NVIDIA y las RX 9000 de AMD.

| Fabricante | Modelos |
|---|---|
| **Intel** | UHD 620/730/770, Iris Xe/Xe MAX/Plus 655, Arc A580/A750/A770/B580 (Battlemage) |
| **NVIDIA** | GTX 1660 SUPER, RTX 3060/3070/3080, RTX 4060/4070/4070Ti SUPER/4080 SUPER/4090, RTX 5070/5070Ti/5080/5090 |
| **AMD** | Vega 8, Radeon 680M/780M/890M (Strix Point), RX 7600/7800XT/7900XTX, RX 9070 XT |
| **Apple** | M1/M2/M3/M3 Pro/M4 GPU |

### Tarjetas de red (22)

Incluye adaptadores Wi-Fi 6, Wi-Fi 6E y Wi-Fi 7, además de Ethernet. Cada uno tiene su prefijo MAC OUI real registrado en el IEEE.

| Fabricante | Modelos |
|---|---|
| **Intel** | AX200/AX201/AX211 (Wi-Fi 6/6E), BE200 (Wi-Fi 7), I219-V/I225-V/I226-V Ethernet, 82574L servidor |
| **Realtek** | RTL8111 Gigabit, RTL8125BG 2.5G, RTL8852CE (Wi-Fi 6E), RTL8922AE (Wi-Fi 7) |
| **Broadcom** | BCM4360 (Mac Intel), BCM4387 (Mac M2+) |
| **Qualcomm** | QCNFA765 Wi-Fi 6E, FastConnect 7800 Wi-Fi 7 |
| **MediaTek** | MT7921 (Wi-Fi 6, económico), MT7925 (Wi-Fi 7) |
| **Killer** | AX1690 (Wi-Fi 6E gaming), BE1750x (Wi-Fi 7 gaming) |
| **Apple** | Wi-Fi Adapter (macOS), Thunderbolt Ethernet |

### Chipsets PCI (9 plantillas)

Cada plantilla cambia los nombres de todos los dispositivos PCI de la VM (host bridge, ISA bridge, controlador IDE, audio, Thunderbolt, etc.) para que sean coherentes con la plataforma elegida.

| Plantilla | Plataforma | Uso típico |
|---|---|---|
| Intel 12th Gen | Alder Lake (2022-2023) | Portátiles y sobremesas 2022 |
| Intel 13th Gen | Raptor Lake (2023-2024) | Portátiles y sobremesas 2023 |
| Intel 14th Gen | Raptor Lake-S (2024) | Sobremesas gaming 2024 |
| Intel Meteor Lake | Core Ultra 1ra gen (2024) | Portátiles ultrabook 2024 |
| Intel Arrow Lake | Core Ultra 2da gen (2024-2025) | Sobremesas y portátiles 2025 |
| AMD Zen 4 | Raphael / Phoenix (2023-2024) | Ryzen 7000, AM5 |
| AMD Zen 5 | Granite Ridge (2024-2025) | Ryzen 9000, AM5 |
| Apple Intel | Coffee Lake (2019-2020) | MacBook Pro Intel |
| Apple Silicon | M1/M2/M3/M4 (2020+) | MacBook, iMac, Mac Mini, Mac Studio |

---

## Diferencias entre plataformas

| Aspecto | Windows | Linux | macOS |
|---|---|---|---|
| Script | vm-spoofer.ps1 | vm-spoofer.sh | vm-spoofer-mac.sh |
| Interfaz | Menús en terminal | whiptail (gráfico) | dialog (gráfico) |
| Dependencias | Solo VirtualBox | VirtualBox + jq + whiptail | VirtualBox + jq + dialog (brew) |
| Detección arch | - | - | Intel / Apple Silicon |
| Post-instalación | No necesaria | Opcional/recomendada (lspci + módulos) | No necesaria |
| Verificación | PowerShell o Node.js | dmidecode, lspci o Node.js | Node.js |
| Detección firmware | EFI/BIOS auto | EFI/BIOS auto | EFI/BIOS auto |
| Gestión estados VM | Sí | Sí | Sí |
| Generador MAC | Auto, manual, random | Auto, manual, random | Auto, manual, random |
| Periféricos | Audio/micro + USB externo opcional | Audio/micro + USB externo opcional | Audio/micro + USB externo opcional |
| VRDE/RDP VirtualBox | No se activa automáticamente | Desactivado por defecto, local-only si se habilita | Desactivado por defecto, local-only si se habilita |

---

## Preguntas frecuentes

**La VM tiene que estar apagada para aplicar el camuflaje?**
No. El script detecta el estado de la VM y la prepara automáticamente. Si está encendida la apaga, si está guardada descarta el estado, si está bloqueada fuerza el apagado. No tienes que hacer nada manualmente.

**Pierdo datos si aplico el camuflaje?**
No. El script solo modifica metadatos de VirtualBox (el archivo .vbox de la VM). No toca los archivos dentro del disco virtual ni modifica el sistema operativo invitado.

**Puedo revertir los cambios?**
Sí. El script guarda un backup automático antes de aplicar los cambios, incluyendo extradata, recursos básicos, red, gráficos, paravirtualización, VRDE y una copia del `.vbox` cuando está disponible. Puedes restaurar la configuración original ejecutando el script de nuevo y eligiendo la opción "Restaurar".

**El acceso remoto queda abierto?**
No por defecto. En Linux y macOS, VRDE/RDP de VirtualBox queda desactivado salvo que lo habilites explícitamente. Si lo activas desde el asistente, se limita a `127.0.0.1` y al puerto local elegido.

**Funciona con VMware, Hyper-V o KVM?**
No. VM Spoofer es exclusivo para VirtualBox. Cada hipervisor tiene su propia forma de almacenar los identificadores de hardware y necesitaría un script diferente.

**La VM funciona más lento después del camuflaje?**
No. Los cambios son solo cosméticos (nombres e identificadores). El rendimiento de la VM no se ve afectado en absoluto.

**Por qué en Linux hay un paso de post-instalación y en Windows no?**
Porque `lspci` en Linux lee los identificadores directamente del bus PCI emulado, no del DMI. Windows no tiene un equivalente que haga eso; `systeminformation` en Windows lee del DMI que ya está cambiado desde fuera. En OK VM Proctoring, el post-install crea un wrapper para `lspci` pero no bloquea `vboxguest`, `vboxsf` ni `vboxvideo`, porque Guest Additions deben seguir funcionando.

**Puedo simular un Apple MacBook en una VM Windows?**
Técnicamente sí, porque el configurador permite elegir cualquier perfil. Para entrega de OK VM Proctoring conviene mantener coherencia: Windows/Linux con perfiles PC normales y macOS con perfiles Apple cuando el guest realmente sea macOS. Si se fuerza un perfil Apple sobre Windows/Linux, debe quedar marcado como caso de prueba específico.

**El generador de MAC es seguro?**
Los prefijos MAC usados son OUI reales registrados en el IEEE por cada fabricante. Los últimos 3 octetos se generan aleatoriamente. Una MAC generada es indistinguible de la de un dispositivo real del mismo fabricante.

**Qué pasa con cámara, micro y altavoces?**
Audio y micrófono se activan con audio-in/audio-out de VirtualBox. Para cámara, el launcher incluye una opción de webcam passthrough sobre una VM arrancada. Los filtros USB siguen existiendo, pero son manuales y opcionales para dispositivos externos concretos.

---

## Librería de verificación

La herramienta de referencia para la detección de VMs es **systeminformation**:

- **Repositorio**: https://github.com/sebhildebrandt/systeminformation
- **npm**: https://www.npmjs.com/package/systeminformation
- **Tipo**: librería open source de Node.js
- **Plataformas de la librería**: Windows, Linux, macOS (VM Spoofer cubre las tres)
- **Uso**: `const si = require("systeminformation")` en Node.js
- **Campos clave para detección de VM**: `system().virtual`, `system().virtualVendor`, `system().virtualHost`, `diskLayout().name`, `diskLayout().vendor`, `graphics().controllers[].vendor`, `networkInterfaces().mac`

Esta librería consulta múltiples fuentes de información del hardware (DMI/SMBIOS, disco, GPU, red, chasis) y cruza los datos para determinar si el sistema es virtual. Un camuflaje efectivo necesita cubrir todas estas fuentes de forma coherente, que es exactamente lo que hace VM Spoofer.
