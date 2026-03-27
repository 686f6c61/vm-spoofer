# VM Spoofer

Sistema para camuflar máquinas virtuales de VirtualBox. Modifica los identificadores de hardware (fabricante, BIOS, placa base, disco, GPU, MAC, chipset) para que herramientas de detección como `systeminformation` no identifiquen el sistema como una máquina virtual.

Funciona en **Windows** (PowerShell), **Linux** (Bash + whiptail) y **macOS** (Bash + dialog). En macOS detecta automáticamente si el Mac es **Intel** o **Apple Silicon**.

---

## El problema

Cuando ejecutas una máquina virtual en VirtualBox, el sistema operativo invitado sabe que está dentro de una VM. Herramientas como `systeminformation` (Node.js), `dmidecode` (Linux) o WMI (Windows) leen los identificadores del hardware y encuentran valores como "VirtualBox", "Oracle", "VBOX HARDDISK" o prefijos MAC `08:00:27` que delatan inmediatamente que el sistema no es físico.

Esto es un problema en muchos contextos: software que rechaza ejecutarse en VMs, plataformas que detectan y bloquean entornos virtualizados, pruebas de seguridad donde necesitas que el sistema parezca real, o simplemente privacidad.

VM Spoofer resuelve esto reemplazando todos esos identificadores por los de equipos reales del mercado. Una VM camuflada como un Lenovo ThinkPad X1 Carbon, un Dell XPS 15 o un Apple MacBook Pro es indistinguible de la máquina real para cualquier software que consulte el hardware.

---

## Cómo funciona

VirtualBox almacena la configuración de cada VM en un archivo `.vbox` y permite modificar los identificadores de hardware mediante el comando `VBoxManage setextradata`. VM Spoofer automatiza este proceso: lee una base de datos con perfiles de hardware real (`hardware-db.json`), presenta un asistente interactivo donde eliges qué equipo quieres simular, y aplica todos los cambios de una sola vez.

Los cambios se aplican a nivel de VirtualBox, no dentro de la VM. Eso significa que no necesitas instalar nada en el sistema invitado para que el camuflaje funcione. El SO invitado simplemente lee los nuevos identificadores como si fueran hardware real.

En VMs Linux hay un paso adicional opcional: un script de post-instalación que camufla los nombres de los dispositivos PCI (que `lspci` lee directamente del hardware emulado) y bloquea los módulos del kernel de VirtualBox que también pueden delatar la VM.

---

## Qué cambia exactamente

El camuflaje abarca todas las capas que las herramientas de detección consultan:

**DMI/SMBIOS** es la primera línea de detección. Contiene el fabricante del sistema, modelo, número de serie, UUID, versión de BIOS, fabricante de la placa base y tipo de chasis. VirtualBox por defecto pone "Oracle" y "VirtualBox" en estos campos. VM Spoofer los reemplaza por los valores exactos de un equipo real (por ejemplo, "LENOVO" con modelo "20Y7CTO1WW" y BIOS "N3HET91W" para un ThinkPad X1 Carbon).

**ACPI** es la tabla de configuración de energía del sistema. Incluye un OEM ID y un Creator ID que VirtualBox rellena con "VBOX". VM Spoofer los cambia al fabricante correspondiente (LENOVO, DELL, HP, APPLE, ALASKA para ASUS/MSI, etc.).

**Disco duro** es un indicador de fiabilidad media. VirtualBox por defecto llama al disco "VBOX HARDDISK" con vendor "VirtualBox". VM Spoofer lo cambia a un disco real (Samsung SSD 990 PRO, WD Black SN850X, etc.) con número de serie generado aleatoriamente usando el prefijo real del fabricante y una versión de firmware auténtica.

**Dirección MAC** es otro indicador habitual. VirtualBox asigna MACs con el prefijo `08:00:27` que está registrado a nombre de Oracle/VirtualBox. VM Spoofer genera una MAC con el prefijo del fabricante de red que elijas (Intel, Realtek, Broadcom, Killer, Apple, etc.) y un sufijo aleatorio.

**Paravirtualización** es un mecanismo que VirtualBox usa para comunicarse con el SO invitado de forma eficiente. Pero su presencia delata que hay un hipervisor. VM Spoofer la desactiva.

**VMMDev** es el dispositivo de comunicación entre VirtualBox y las Guest Additions. VM Spoofer desactiva la sincronización de hora que puede usarse para detectar la VM.

**Dispositivos PCI** (solo Linux): `lspci` muestra los dispositivos de hardware emulados por VirtualBox con nombres como "VMware SVGA II Adapter" o "InnoTek VirtualBox Guest Service". El script de post-instalación para Linux crea un wrapper que reemplaza estos nombres por los del chipset real elegido.

**USB y periféricos**: En Windows y Linux, VM Spoofer detecta cámaras, micrófonos y altavoces USB conectados al host y crea filtros para que se conecten automáticamente a la VM cada vez que arranca. En macOS, el micrófono y los altavoces integrados se pasan a la VM mediante audio-in/audio-out de VirtualBox (no son USB, el script lo gestiona automáticamente). La cámara FaceTime de los Mac es un dispositivo interno, no USB, y VirtualBox no puede redirigirla. Soluciones de software como OBS Virtual Camera pueden ser detectadas por herramientas de análisis, lo que comprometería el camuflaje. Si necesitas usar cámara en una VM desde un Mac, conecta una **webcam USB externa** (Logitech, Insta360, etc.) que el script detectará y configurará automáticamente como en Windows y Linux.

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
| USB | Detecta periféricos de audio/video y crea filtros automáticos | Cámara, micro y altavoces funcionan en la VM |

---

## Archivos

| Archivo | Descripción |
|---|---|
| `vm-spoofer.ps1` | Script principal para Windows (PowerShell) |
| `vm-spoofer.sh` | Script principal para Linux (Bash + whiptail) |
| `vm-spoofer-mac.sh` | Script principal para macOS Intel/Apple Silicon (Bash + dialog) |
| `hardware-db.json` | Base de datos con perfiles de hardware reales (43 fabricantes, 38 CPUs, 24 discos, 36 GPUs, 22 NICs, 9 chipsets) |
| `check.js` | Script de verificación con systeminformation (Node.js) |
| `INSTRUCCIONES-WINDOWS.txt` | Guía paso a paso para Windows |
| `INSTRUCCIONES-LINUX.txt` | Guía paso a paso para Linux |
| `INSTRUCCIONES-MACOS.txt` | Guía paso a paso para macOS (Intel y Apple Silicon) |
| `img/` | Capturas de pantalla del asistente en Windows |

---

## Requisitos

### Windows
- VirtualBox (https://www.virtualbox.org)
- PowerShell (incluido en Windows 10/11)

### Linux
- VirtualBox (`sudo apt install virtualbox`)
- jq (`sudo apt install jq`)
- whiptail (`sudo apt install whiptail`)

### macOS (Intel y Apple Silicon)
- VirtualBox (https://www.virtualbox.org)
- Homebrew (https://brew.sh)
- dialog (`brew install dialog`)
- jq (`brew install jq`)

No se necesita instalar nada dentro de la VM para que el camuflaje funcione. Solo para la verificación posterior (opcional) se usa Node.js con `systeminformation`.

---

## Uso rápido

### Windows

```powershell
cd ruta\a\vm-creator
powershell -ExecutionPolicy Bypass -File vm-spoofer.ps1
```

### Linux

```bash
cd ruta/a/vm-creator
bash vm-spoofer.sh
```

### macOS

```bash
cd ruta/a/vm-creator
bash vm-spoofer-mac.sh
```

El script detecta automáticamente si el Mac es Intel o Apple Silicon y lo muestra en cada pantalla del asistente.

El asistente guía en 8 pasos:

1. **Seleccionar VM** - detecta automáticamente las VMs instaladas
2. **Fabricante** - elige el equipo a simular
3. **Procesador** - CPU que aparecerá en el sistema
4. **RAM y CPUs** - recursos simulados (pueden ser mayores que los reales)
5. **Disco, GPU y Red** - periféricos con generador de MAC (auto/manual/regenerar)
6. **Chipset PCI** - plantilla de dispositivos PCI
7. **Dispositivos USB** - detecta cámaras, micrófonos y altavoces automáticamente
8. **Confirmar y aplicar** - muestra resumen y aplica los cambios

No necesitas saber nada de VirtualBox ni de línea de comandos. El script hace todo el trabajo: detecta las VMs, gestiona su estado, aplica los cambios y genera los scripts de post-instalación si son necesarios.

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

Una vez aplicado el camuflaje y arrancada la VM, la forma más fiable de verificar que funciona es usar la librería `systeminformation` de Node.js. Esta librería es la referencia del sector: tiene más de 4 millones de descargas semanales en npm y es la que usan la mayoría de aplicaciones y plataformas para detectar máquinas virtuales.

### Con Node.js (recomendado)

Dentro de la VM, instalar Node.js (https://nodejs.org) y ejecutar:

```bash
mkdir vm-verify && cd vm-verify
npm install systeminformation
```

Copiar `check.js` a la carpeta y ejecutar:

```bash
node check.js        # Windows
sudo node check.js   # Linux (necesita sudo para acceder a DMI)
```

El script analiza todos los indicadores de hardware y muestra un informe completo:

```
=== Verificación de hardware (systeminformation) ===

[SISTEMA]
  Fabricante:      Dell Inc.
  Modelo:          XPS 15 9530
  Virtual:         false
  VirtualHost:     undefined

[BIOS]
  Vendor:          Dell Inc.
  Version:         1.23.0

[DISCOS]
  Disco 0:
    Nombre:        Samsung SSD 990 PRO 1TB
    Vendor:        Samsung

[RED]
  enp0s3:
    MAC:           b4:2e:99:3f:a8:21
    Virtual:       false

=== RESULTADO CLAVE ===
  system.virtual:      NO detectada (bien)
  system.virtualHost:  (vacío - bien)
  Fabricante:          Dell Inc.
  Modelo:              XPS 15 9530

  [OK] El sistema aparenta ser hardware físico.
```

Si `system.virtual` sale `true`, significa que algún indicador no se camufló correctamente. Revisa que la VM estaba apagada cuando aplicaste los cambios y, en Linux, que ejecutaste el script de post-instalación.

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
| Módulos del kernel | vboxguest, vboxsf, vboxvideo | Media | Sí (Linux post-install) |
| Dispositivos PCI | lspci: VMware SVGA, InnoTek Guest Service | Media | Sí (Linux post-install) |
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
| Post-instalación | No necesaria | Necesaria (lspci + módulos) | Necesaria (lspci + módulos) |
| Verificación | PowerShell o Node.js | dmidecode, lspci o Node.js | Node.js |
| Detección firmware | EFI/BIOS auto | EFI/BIOS auto | EFI/BIOS auto |
| Gestión estados VM | Sí | Sí | Sí |
| Generador MAC | Auto, manual, random | Auto, manual, random | Auto, manual, random |
| Detección USB | Sí | Sí | Sí |

---

## Preguntas frecuentes

**La VM tiene que estar apagada para aplicar el camuflaje?**
No. El script detecta el estado de la VM y la prepara automáticamente. Si está encendida la apaga, si está guardada descarta el estado, si está bloqueada fuerza el apagado. No tienes que hacer nada manualmente.

**Pierdo datos si aplico el camuflaje?**
No. El script solo modifica metadatos de VirtualBox (el archivo .vbox de la VM). No toca los archivos dentro del disco virtual ni modifica el sistema operativo invitado.

**Puedo revertir los cambios?**
Sí. El script guarda un backup automático antes de aplicar los cambios. Puedes restaurar la configuración original ejecutando el script de nuevo y eligiendo la opción "Restaurar".

**Funciona con VMware, Hyper-V o KVM?**
No. VM Spoofer es exclusivo para VirtualBox. Cada hipervisor tiene su propia forma de almacenar los identificadores de hardware y necesitaría un script diferente.

**La VM funciona más lento después del camuflaje?**
No. Los cambios son solo cosméticos (nombres e identificadores). El rendimiento de la VM no se ve afectado en absoluto.

**Por qué en Linux hay un paso de post-instalación y en Windows no?**
Porque `lspci` en Linux lee los identificadores directamente del bus PCI emulado, no del DMI. Windows no tiene un equivalente que haga eso; `systeminformation` en Windows lee del DMI que ya está cambiado desde fuera. En Linux, el post-install crea un wrapper para `lspci` y bloquea módulos del kernel como `vboxguest` que también delatan la VM.

**Puedo simular un Apple MacBook en una VM Windows?**
Sí. Puedes elegir cualquier perfil independientemente del SO de la VM. Un Windows 11 camuflado como MacBook Pro aparecerá con fabricante "Apple Inc." y modelo "MacBookPro18,3" en `systeminformation`. Los perfiles Apple están pensados para esto: simular hardware Apple desde una VM Windows o Linux. No es necesario tener un Mac ni ejecutar macOS.

**El generador de MAC es seguro?**
Los prefijos MAC usados son OUI reales registrados en el IEEE por cada fabricante. Los últimos 3 octetos se generan aleatoriamente. Una MAC generada es indistinguible de la de un dispositivo real del mismo fabricante.

**Qué pasa con los dispositivos USB (cámara, micro)?**
El script detecta automáticamente las cámaras, micrófonos y altavoces conectados al host. Los que selecciones se conectarán a la VM cada vez que arranque mediante filtros USB de VirtualBox. Puedes usar la webcam y el micro dentro de la VM como si fueran locales.

---

## Librería de verificación

La herramienta de referencia para la detección de VMs es **systeminformation**:

- **Repositorio**: https://github.com/sebhildebrandt/systeminformation
- **npm**: https://www.npmjs.com/package/systeminformation
- **Tipo**: librería open source de Node.js
- **Plataformas de la librería**: Windows, Linux, macOS (VM Spoofer funciona en Windows y Linux)
- **Uso**: `const si = require("systeminformation")` en Node.js
- **Campos clave para detección de VM**: `system().virtual`, `system().virtualVendor`, `system().virtualHost`, `diskLayout().name`, `diskLayout().vendor`, `graphics().controllers[].vendor`, `networkInterfaces().mac`

Esta librería consulta múltiples fuentes de información del hardware (DMI/SMBIOS, disco, GPU, red, chasis) y cruza los datos para determinar si el sistema es virtual. Un camuflaje efectivo necesita cubrir todas estas fuentes de forma coherente, que es exactamente lo que hace VM Spoofer.
