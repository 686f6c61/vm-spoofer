# =============================================================================
# VM Spoofer para Windows - Camufla una maquina virtual existente
#
# Detecta las VMs de VirtualBox instaladas, te deja elegir una,
# y le aplica un perfil de hardware real para que no sea detectada
# como maquina virtual por herramientas como systeminformation.
#
# Uso: powershell -ExecutionPolicy Bypass -File vm-spoofer.ps1
#
# Requisitos: VirtualBox instalado
# =============================================================================

$ErrorActionPreference = "Stop"
$VBox = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$DBFile = Join-Path $ScriptDir "hardware-db.json"
$BackupDir = Join-Path $ScriptDir "backups"

# --- Verificar dependencias ---
if (-not (Test-Path $VBox)) {
    Write-Host "[!] VirtualBox no encontrado en: $VBox" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $DBFile)) {
    Write-Host "[!] hardware-db.json no encontrado en: $DBFile" -ForegroundColor Red
    exit 1
}

$DB = Get-Content $DBFile -Raw | ConvertFrom-Json

# --- Funciones auxiliares ---
function Show-Banner {
    Clear-Host
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "  VM Spoofer - Camufla tu maquina virtual" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Detecta tus VMs de VirtualBox y les aplica"
    Write-Host "  un perfil de hardware real para que no sean"
    Write-Host "  detectadas como maquina virtual."
    Write-Host ""
}

function Show-Menu {
    param(
        [string]$Title,
        [string]$Prompt,
        [array]$Options  # Array de @{Key; Label}
    )
    Write-Host ""
    Write-Host "--- $Title ---" -ForegroundColor Yellow
    Write-Host $Prompt
    Write-Host ""
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host "  [$($i+1)] $($Options[$i].Label)"
    }
    Write-Host ""
    do {
        $choice = Read-Host "Elige una opcion (1-$($Options.Count))"
        $idx = [int]$choice - 1
    } while ($idx -lt 0 -or $idx -ge $Options.Count)
    return $Options[$idx]
}

function Gen-Serial {
    param([string]$Prefix, [int]$Len = 6)
    $chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    $result = $Prefix
    for ($i = 0; $i -lt $Len; $i++) {
        $result += $chars[(Get-Random -Maximum $chars.Length)]
    }
    return $result
}

function Gen-MAC {
    param([string]$Prefix)
    $suffix = "{0:X2}{1:X2}{2:X2}" -f (Get-Random -Max 256), (Get-Random -Max 256), (Get-Random -Max 256)
    $mac = ($Prefix -replace ":", "") + $suffix
    return $mac
}

function VBoxCmd {
    param([string[]]$CmdArgs)
    $output = & $VBox @CmdArgs 2>&1
    return $output
}

# =============================================================================
# PASO 1: Detectar VMs
# =============================================================================
function Step-DetectVMs {
    Write-Host ""
    Write-Host "--- Paso 1/8 - Selecciona una VM ---" -ForegroundColor Yellow
    Write-Host "Buscando maquinas virtuales..." -ForegroundColor Gray
    Write-Host ""

    $vms = @()
    $vmList = VBoxCmd @("list", "vms")
    foreach ($line in $vmList) {
        if ($line -match '"(.+)"\s+\{(.+)\}') {
            $name = $Matches[1]
            $info = VBoxCmd @("showvminfo", $name, "--machinereadable") | Out-String
            $os = if ($info -match 'ostype="(.+?)"') { $Matches[1] } else { "Desconocido" }
            $ram = if ($info -match 'memory=(\d+)') { $Matches[1] } else { "?" }
            $cpus = if ($info -match 'cpus=(\d+)') { $Matches[1] } else { "?" }
            $state = if ($info -match 'VMState="(.+?)"') { $Matches[1] } else { "?" }

            $icon = switch -Wildcard ($os) {
                "*Windows*" { "[WIN]" }
                "*Ubuntu*"  { "[LNX]" }
                "*Linux*"   { "[LNX]" }
                "*Debian*"  { "[LNX]" }
                default     { "[---]" }
            }

            $stateLabel = switch ($state) {
                "running"  { "ENCENDIDA" }
                "poweroff" { "apagada" }
                "saved"    { "guardada" }
                default    { $state }
            }

            $vms += @{
                Key = $name
                Label = "$icon $name | $os | ${ram}MB RAM | $cpus CPUs | $stateLabel"
                Name = $name
                RAM = $ram
                CPUs = $cpus
                OS = $os
                State = $state
            }
        }
    }

    if ($vms.Count -eq 0) {
        Write-Host "[!] No se encontraron VMs. Crea una primero." -ForegroundColor Red
        exit 0
    }

    $selected = Show-Menu -Title "VMs encontradas" -Prompt "Elige la VM a camuflar:" -Options $vms

    # Preparar la VM: ponerla en estado poweroff sea cual sea su estado actual
    $st = $selected.State
    if ($st -ne "poweroff") {
        Write-Host ""
        switch ($st) {
            "running" {
                Write-Host "[*] La VM esta encendida. Apagandola..." -ForegroundColor Yellow
                VBoxCmd @("controlvm", $selected.Name, "poweroff") | Out-Null
                Start-Sleep 3
            }
            "saved" {
                Write-Host "[*] La VM esta guardada. Descartando estado..." -ForegroundColor Yellow
                VBoxCmd @("discardstate", $selected.Name) | Out-Null
                Start-Sleep 2
            }
            "aborted" {
                Write-Host "[*] La VM estaba abortada. Lista para configurar." -ForegroundColor Yellow
            }
            "stuck" {
                Write-Host "[*] La VM esta bloqueada. Forzando apagado..." -ForegroundColor Yellow
                VBoxCmd @("controlvm", $selected.Name, "poweroff") | Out-Null
                Start-Sleep 3
            }
            "paused" {
                Write-Host "[*] La VM esta pausada. Apagandola..." -ForegroundColor Yellow
                VBoxCmd @("controlvm", $selected.Name, "poweroff") | Out-Null
                Start-Sleep 3
            }
            default {
                Write-Host "[*] Estado: $st. Intentando preparar la VM..." -ForegroundColor Yellow
                VBoxCmd @("controlvm", $selected.Name, "poweroff") 2>$null | Out-Null
                VBoxCmd @("discardstate", $selected.Name) 2>$null | Out-Null
                Start-Sleep 2
            }
        }
        # Verificar que quedó en poweroff
        $checkInfo = VBoxCmd @("showvminfo", $selected.Name, "--machinereadable") | Out-String
        $newState = if ($checkInfo -match 'VMState="(.+?)"') { $Matches[1] } else { "?" }
        if ($newState -ne "poweroff") {
            Write-Host "[!] No se pudo preparar la VM (estado: $newState)." -ForegroundColor Red
            Write-Host "    Cierra VirtualBox y la VM manualmente, luego ejecuta de nuevo." -ForegroundColor Red
            exit 1
        }
        Write-Host "[OK] VM lista para configurar." -ForegroundColor Green
    }

    return $selected
}

# =============================================================================
# PASO 2: Fabricante
# =============================================================================
function Step-Manufacturer {
    $options = @()
    foreach ($key in ($DB.manufacturers.PSObject.Properties.Name)) {
        $mfg = $DB.manufacturers.$key
        $options += @{ Key = $key; Label = $mfg.label }
    }
    $selected = Show-Menu -Title "Paso 2/8 - Perfil de hardware" -Prompt "Elige el equipo a simular:" -Options $options
    return $selected.Key
}

# =============================================================================
# PASO 3: CPU
# =============================================================================
function Step-CPU {
    $options = @()
    foreach ($key in ($DB.cpus.PSObject.Properties.Name)) {
        $cpu = $DB.cpus.$key
        $options += @{ Key = $key; Label = $cpu.label }
    }
    $selected = Show-Menu -Title "Paso 3/8 - Procesador" -Prompt "CPU que aparecera en el sistema:" -Options $options
    return $selected.Key
}

# =============================================================================
# PASO 4: RAM y Cores simulados
# =============================================================================
function Step-Resources {
    param([string]$CurrentRAM, [string]$CurrentCPUs)

    $ramOptions = @()
    foreach ($r in $DB.ram_options) {
        $tag = if ($r.value -eq [int]$CurrentRAM) { " (actual)" } else { "" }
        $ramOptions += @{ Key = $r.value; Label = "$($r.label)$tag" }
    }
    $ram = Show-Menu -Title "Paso 4a/8 - RAM simulada" -Prompt "RAM actual: ${CurrentRAM}MB. Puedes asignar mas de la que tiene:" -Options $ramOptions

    $coreOptions = @()
    foreach ($c in $DB.cpu_cores_vm) {
        $tag = if ($c.value -eq [int]$CurrentCPUs) { " (actual)" } else { "" }
        $coreOptions += @{ Key = $c.value; Label = "$($c.label)$tag" }
    }
    $cores = Show-Menu -Title "Paso 4b/8 - Cores simulados" -Prompt "Cores actuales: $CurrentCPUs" -Options $coreOptions

    return @{ RAM = $ram.Key; CPUs = $cores.Key }
}

# =============================================================================
# PASO 5: Disco, GPU, Red
# =============================================================================
function Step-Disk {
    $options = @()
    foreach ($key in ($DB.disks.PSObject.Properties.Name)) {
        $d = $DB.disks.$key
        $options += @{ Key = $key; Label = $d.label }
    }
    return (Show-Menu -Title "Paso 5a/8 - Disco duro" -Prompt "Disco que aparecera en el sistema:" -Options $options).Key
}

function Step-GPU {
    $options = @()
    foreach ($key in ($DB.gpus.PSObject.Properties.Name)) {
        $g = $DB.gpus.$key
        $options += @{ Key = $key; Label = $g.label }
    }
    return (Show-Menu -Title "Paso 5b/8 - Tarjeta grafica" -Prompt "GPU que aparecera en lspci/systeminformation:" -Options $options).Key
}

function Step-NIC {
    $options = @()
    foreach ($key in ($DB.nics.PSObject.Properties.Name)) {
        $n = $DB.nics.$key
        $options += @{ Key = $key; Label = $n.label }
    }
    $selected = (Show-Menu -Title "Paso 5c/8 - Tarjeta de red" -Prompt "Adaptador de red y prefijo MAC:" -Options $options).Key

    $prefix = $DB.nics.$selected.mac_prefix
    $autoMac = Gen-MAC -Prefix $prefix
    $prefixClean = $prefix -replace ":", ""

    Write-Host ""
    Write-Host "  Prefijo del fabricante: $prefix" -ForegroundColor Gray
    Write-Host ""

    $macOptions = @(
        @{ Key = "auto";   Label = "Usar MAC generada automaticamente ($($prefixClean.Substring(0,2)):$($prefixClean.Substring(2,2)):$($prefixClean.Substring(4,2)):$($autoMac.Substring(6,2)):$($autoMac.Substring(8,2)):$($autoMac.Substring(10,2)))" }
        @{ Key = "manual"; Label = "Escribir una MAC personalizada" }
        @{ Key = "random"; Label = "Generar otra MAC aleatoria con el mismo prefijo" }
    )
    $macChoice = (Show-Menu -Title "Generador de MAC" -Prompt "Direccion MAC para la tarjeta de red:" -Options $macOptions).Key

    $mac = $autoMac
    switch ($macChoice) {
        "auto" { $mac = $autoMac }
        "manual" {
            $customMac = Read-Host "Escribe la MAC completa (12 caracteres hex, sin separadores)"
            if ($customMac.Length -ge 12) { $mac = $customMac.Substring(0,12).ToUpper() }
        }
        "random" {
            do {
                $mac = Gen-MAC -Prefix $prefix
                $formatted = "$($mac.Substring(0,2)):$($mac.Substring(2,2)):$($mac.Substring(4,2)):$($mac.Substring(6,2)):$($mac.Substring(8,2)):$($mac.Substring(10,2))"
                Write-Host "  MAC: $formatted" -ForegroundColor Cyan
                $ok = Read-Host "  Usar esta? (s/n)"
            } while ($ok -ne "s")
        }
    }

    $formatted = "$($mac.Substring(0,2)):$($mac.Substring(2,2)):$($mac.Substring(4,2)):$($mac.Substring(6,2)):$($mac.Substring(8,2)):$($mac.Substring(10,2))"
    Write-Host "  MAC seleccionada: $formatted" -ForegroundColor Green
    return @{ Key = $selected; MAC = $mac }
}

# =============================================================================
# PASO 6: Chipset
# =============================================================================
function Step-Chipset {
    $options = @()
    foreach ($key in ($DB.lspci_templates.PSObject.Properties.Name)) {
        $desc = switch ($key) {
            "intel_12th_gen" { "Intel 12th Gen (Alder Lake) - 2022-2023" }
            "intel_13th_gen" { "Intel 13th Gen (Raptor Lake) - 2023-2024" }
            "intel_14th_gen" { "Intel 14th Gen (Raptor Lake-S) - 2024" }
            "amd_zen4"       { "AMD Zen 4 (Raphael/Phoenix) - 2023-2024" }
            "apple_intel"    { "Apple Intel (Coffee Lake) - MacBook 2019" }
            default          { $key }
        }
        $options += @{ Key = $key; Label = $desc }
    }
    return (Show-Menu -Title "Paso 6/8 - Chipset PCI" -Prompt "Plantilla de chipset:" -Options $options).Key
}

# =============================================================================
# PASO 7: USB
# =============================================================================
function Step-USB {
    param([string]$VMName)
    Write-Host ""
    Write-Host "--- Paso 7/8 - Dispositivos USB ---" -ForegroundColor Yellow
    Write-Host "Buscando camaras, microfonos y altavoces..." -ForegroundColor Gray

    $usbList = VBoxCmd @("list", "usbhost") | Out-String
    $devices = @()
    $currentVid = ""; $currentPid = ""; $currentProd = ""; $currentMfg = ""

    foreach ($line in ($usbList -split "`n")) {
        if ($line -match "VendorId:\s+0x(\w+)") { $currentVid = $Matches[1] }
        if ($line -match "ProductId:\s+0x(\w+)") { $currentPid = $Matches[1] }
        if ($line -match "Manufacturer:\s+(.+)") { $currentMfg = $Matches[1].Trim() }
        if ($line -match "Product:\s+(.+)") { $currentProd = $Matches[1].Trim() }
        if ($line.Trim() -eq "" -and $currentProd -ne "") {
            $lower = "$currentProd $currentMfg".ToLower()
            $category = "otro"
            if ($lower -match "cam|video|webcam|insta360|brio") { $category = "camara" }
            elseif ($lower -match "mic|yeti|scarlett|focusrite|rode|shure|blue|elgato|hyperx|samson") { $category = "micro" }
            elseif ($lower -match "speaker|audio|headset|jabra|sonos|bose|jbl|dac|interface") { $category = "audio" }
            elseif ($lower -match "hub|root|bluetooth|receiver|keyboard|mouse") {
                $currentVid = ""; $currentPid = ""; $currentProd = ""; $currentMfg = ""
                continue
            }

            if ($category -ne "otro") {
                $icon = switch ($category) { "camara" { "[CAM]" }; "micro" { "[MIC]" }; "audio" { "[AUD]" } }
                $devices += @{ Vid = $currentVid; Pid = $currentPid; Name = "$icon $currentMfg $currentProd" }
                Write-Host "  $icon $currentMfg $currentProd" -ForegroundColor Green
            }
            $currentVid = ""; $currentPid = ""; $currentProd = ""; $currentMfg = ""
        }
    }

    if ($devices.Count -eq 0) {
        Write-Host "  No se detectaron dispositivos de audio/video." -ForegroundColor Yellow
    } else {
        Write-Host ""
        $answer = Read-Host "Conectar estos $($devices.Count) dispositivos a la VM? (s/n)"
        if ($answer -ne "s") { $devices = @() }
    }

    return $devices
}

# =============================================================================
# PASO 8: Confirmar y aplicar
# =============================================================================
function Apply-Spoof {
    param(
        [string]$VMName,
        [string]$MfgKey,
        [string]$CpuKey,
        [hashtable]$Resources,
        [string]$DiskKey,
        [string]$GpuKey,
        [hashtable]$NicInfo,
        [string]$ChipsetKey,
        [array]$USBDevices
    )

    $mfg = $DB.manufacturers.$MfgKey
    $disk = $DB.disks.$DiskKey
    $gpu = $DB.gpus.$GpuKey
    $nic = $DB.nics.($NicInfo.Key)

    # Resumen
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "  RESUMEN DE CAMBIOS" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "  VM:          $VMName"
    Write-Host "  Equipo:      $($mfg.label)"
    Write-Host "  CPU:         $($DB.cpus.$CpuKey.label)"
    Write-Host "  RAM:         $($Resources.RAM)MB ($([math]::Round($Resources.RAM/1024))GB)"
    Write-Host "  CPUs:        $($Resources.CPUs)"
    Write-Host "  Disco:       $($disk.model)"
    Write-Host "  GPU:         $($gpu.label)"
    Write-Host "  MAC:         $($NicInfo.MAC)"
    Write-Host "  Chipset:     $ChipsetKey"
    Write-Host "  USB:         $($USBDevices.Count) dispositivos"
    Write-Host ""

    $confirm = Read-Host "Aplicar estos cambios? (s/n)"
    if ($confirm -ne "s") { Write-Host "Cancelado."; exit 0 }

    Write-Host ""
    Write-Host "[  5%] Ajustando RAM y CPUs..." -ForegroundColor Yellow
    VBoxCmd @("modifyvm", $VMName, "--memory", $Resources.RAM, "--cpus", $Resources.CPUs, "--vram", "128", "--graphicscontroller", "vmsvga", "--accelerate3d", "on", "--paravirt-provider", "none", "--cpuid-portability-level", "0") | Out-Null

    Write-Host "[ 10%] Configurando red..." -ForegroundColor Yellow
    VBoxCmd @("modifyvm", $VMName, "--macaddress1", $NicInfo.MAC) | Out-Null

    Write-Host "[ 15%] Ocultando VirtualBox..." -ForegroundColor Yellow
    VBoxCmd @("setextradata", $VMName, "VBoxInternal/Devices/VMMDev/0/Config/GetHostTimeDisabled", "1") | Out-Null

    # Detectar firmware
    $fwInfo = (VBoxCmd @("showvminfo", $VMName, "--machinereadable")) | Out-String
    $fwPath = if ($fwInfo -match 'firmware="EFI"') { "efi" } else { "pcbios" }
    $P = "VBoxInternal/Devices/$fwPath/0/Config"

    Write-Host "[ 30%] DMI: Sistema ($($mfg.system.vendor))..." -ForegroundColor Yellow
    VBoxCmd @("setextradata", $VMName, "$P/DmiSystemVendor", $mfg.system.vendor) | Out-Null
    VBoxCmd @("setextradata", $VMName, "$P/DmiSystemProduct", $mfg.system.product) | Out-Null
    VBoxCmd @("setextradata", $VMName, "$P/DmiSystemVersion", $mfg.system.version) | Out-Null
    VBoxCmd @("setextradata", $VMName, "$P/DmiSystemSKU", $mfg.system.sku) | Out-Null
    VBoxCmd @("setextradata", $VMName, "$P/DmiSystemFamily", $mfg.system.family) | Out-Null
    VBoxCmd @("setextradata", $VMName, "$P/DmiSystemSerial", (Gen-Serial "PF" 6)) | Out-Null
    VBoxCmd @("setextradata", $VMName, "$P/DmiSystemUuid", [guid]::NewGuid().ToString()) | Out-Null

    Write-Host "[ 40%] DMI: BIOS..." -ForegroundColor Yellow
    VBoxCmd @("setextradata", $VMName, "$P/DmiBIOSVendor", $mfg.bios.vendor) | Out-Null
    VBoxCmd @("setextradata", $VMName, "$P/DmiBIOSVersion", $mfg.bios.version) | Out-Null
    VBoxCmd @("setextradata", $VMName, "$P/DmiBIOSReleaseDate", $mfg.bios.date) | Out-Null
    VBoxCmd @("setextradata", $VMName, "$P/DmiBIOSReleaseMajor", $mfg.bios.major) | Out-Null
    VBoxCmd @("setextradata", $VMName, "$P/DmiBIOSReleaseMinor", $mfg.bios.minor) | Out-Null
    VBoxCmd @("setextradata", $VMName, "$P/DmiBIOSFirmwareMajor", $mfg.bios.firmware_major) | Out-Null
    VBoxCmd @("setextradata", $VMName, "$P/DmiBIOSFirmwareMinor", $mfg.bios.firmware_minor) | Out-Null

    Write-Host "[ 50%] DMI: Placa base..." -ForegroundColor Yellow
    VBoxCmd @("setextradata", $VMName, "$P/DmiBoardVendor", $mfg.board.vendor) | Out-Null
    VBoxCmd @("setextradata", $VMName, "$P/DmiBoardProduct", $mfg.board.product) | Out-Null
    VBoxCmd @("setextradata", $VMName, "$P/DmiBoardVersion", $mfg.board.version) | Out-Null
    VBoxCmd @("setextradata", $VMName, "$P/DmiBoardSerial", (Gen-Serial "BSS" 8)) | Out-Null
    VBoxCmd @("setextradata", $VMName, "$P/DmiBoardAssetTag", "Not Available") | Out-Null

    Write-Host "[ 55%] DMI: Chasis..." -ForegroundColor Yellow
    VBoxCmd @("setextradata", $VMName, "$P/DmiChassisVendor", $mfg.chassis.vendor) | Out-Null
    VBoxCmd @("setextradata", $VMName, "$P/DmiChassisVersion", $mfg.chassis.version) | Out-Null
    VBoxCmd @("setextradata", $VMName, "$P/DmiChassisType", $mfg.chassis.type) | Out-Null
    VBoxCmd @("setextradata", $VMName, "$P/DmiChassisSerial", (Gen-Serial "PF" 6)) | Out-Null
    VBoxCmd @("setextradata", $VMName, "$P/DmiChassisAssetTag", "No Asset Information") | Out-Null

    Write-Host "[ 60%] ACPI..." -ForegroundColor Yellow
    VBoxCmd @("setextradata", $VMName, "VBoxInternal/Devices/acpi/0/Config/AcpiOemId", $mfg.acpi.oem_id) | Out-Null
    VBoxCmd @("setextradata", $VMName, "VBoxInternal/Devices/acpi/0/Config/AcpiCreatorId", $mfg.acpi.creator_id) | Out-Null
    VBoxCmd @("setextradata", $VMName, "VBoxInternal/Devices/acpi/0/Config/AcpiCreatorRev", $mfg.acpi.creator_rev) | Out-Null

    Write-Host "[ 70%] Disco: $($disk.model)..." -ForegroundColor Yellow
    $diskSerial = Gen-Serial $disk.serial_prefix 6
    VBoxCmd @("setextradata", $VMName, "VBoxInternal/Devices/ahci/0/Config/Port0/SerialNumber", $diskSerial) | Out-Null
    VBoxCmd @("setextradata", $VMName, "VBoxInternal/Devices/ahci/0/Config/Port0/FirmwareRevision", $disk.firmware) | Out-Null
    VBoxCmd @("setextradata", $VMName, "VBoxInternal/Devices/ahci/0/Config/Port0/ModelNumber", $disk.model) | Out-Null

    VBoxCmd @("setextradata", $VMName, "VBoxInternal/Devices/ahci/0/Config/Port1/ModelNumber", "HL-DT-ST DVDRAM GU90N") | Out-Null
    VBoxCmd @("setextradata", $VMName, "VBoxInternal/Devices/ahci/0/Config/Port1/SerialNumber", (Gen-Serial "K8OD" 6)) | Out-Null

    Write-Host "[ 80%] USB: $($USBDevices.Count) dispositivos..." -ForegroundColor Yellow
    VBoxCmd @("modifyvm", $VMName, "--usb-xhci", "on") 2>$null | Out-Null
    for ($i = 0; $i -lt $USBDevices.Count; $i++) {
        $dev = $USBDevices[$i]
        VBoxCmd @("usbfilter", "add", "$i", "--target", $VMName, "--name", $dev.Name, "--vendorid", $dev.Vid, "--productid", $dev.Pid) 2>$null | Out-Null
        Write-Host "    [+] $($dev.Name)" -ForegroundColor Green
    }

    Write-Host "[100%] Completado" -ForegroundColor Green
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "  Camuflaje aplicado a '$VMName'" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Equipo:  $($mfg.label)"
    Write-Host "  BIOS:    $($mfg.bios.vendor) $($mfg.bios.version)"
    Write-Host "  Disco:   $($disk.model) (S/N: $diskSerial)"
    Write-Host "  GPU:     $($gpu.label)"
    Write-Host "  MAC:     $($NicInfo.MAC)"
    Write-Host ""
    Write-Host "  Arranca la VM y verifica con:" -ForegroundColor Cyan
    Write-Host "    node check.js" -ForegroundColor Cyan
    Write-Host ""

    $start = Read-Host "Arrancar la VM ahora? (s/n)"
    if ($start -eq "s") {
        Write-Host "Arrancando..." -ForegroundColor Yellow
        VBoxCmd @("startvm", $VMName, "--type", "gui") | Out-Null
        Write-Host "VM arrancada." -ForegroundColor Green
    }
}

# =============================================================================
# BACKUP: Guardar configuracion original antes de camuflar
# =============================================================================
function Backup-VM {
    param([string]$VMName)

    if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }

    $backupFile = Join-Path $BackupDir "$VMName.backup.json"

    # Solo guardar si NO existe un backup previo (el primero siempre es el original)
    if (Test-Path $backupFile) {
        Write-Host "[*] Backup de '$VMName' ya existe (configuracion original conservada)." -ForegroundColor Gray
        return
    }

    Write-Host "[*] Guardando backup original de '$VMName'..." -ForegroundColor Yellow

    # Leer configuracion actual
    $info = VBoxCmd @("showvminfo", $VMName, "--machinereadable") | Out-String
    $memory = if ($info -match 'memory=(\d+)') { $Matches[1] } else { "4096" }
    $cpus = if ($info -match 'cpus=(\d+)') { $Matches[1] } else { "2" }
    $mac = if ($info -match 'macaddress1="(.+?)"') { $Matches[1] } else { "" }
    $nic = if ($info -match 'nic1="(.+?)"') { $Matches[1] } else { "nat" }
    $vram = if ($info -match 'vram=(\d+)') { $Matches[1] } else { "128" }

    # Leer extradata actual
    $extradata = @{}
    $extLines = VBoxCmd @("getextradata", $VMName, "enumerate")
    foreach ($line in $extLines) {
        if ($line -match 'Key:\s+(.+?),\s+Value:\s+(.*)') {
            $extradata[$Matches[1]] = $Matches[2]
        }
    }

    # Crear objeto de backup
    $backup = @{
        vm_name = $VMName
        date = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        config = @{
            memory = $memory
            cpus = $cpus
            macaddress1 = $mac
            nic1 = $nic
            vram = $vram
        }
        extradata = $extradata
    }

    $backup | ConvertTo-Json -Depth 5 | Set-Content -Path $backupFile -Encoding UTF8
    Write-Host "[OK] Backup guardado en: $backupFile" -ForegroundColor Green
}

# =============================================================================
# RESTORE: Restaurar configuracion original desde backup
# =============================================================================
function Restore-VM {
    if (-not (Test-Path $BackupDir)) {
        Write-Host "[!] No hay backups disponibles." -ForegroundColor Red
        Write-Host "    La carpeta backups/ no existe." -ForegroundColor Red
        Read-Host "Pulsa Enter para volver"
        return
    }

    $backups = Get-ChildItem -Path $BackupDir -Filter "*.backup.json" -File
    if ($backups.Count -eq 0) {
        Write-Host "[!] No hay backups disponibles." -ForegroundColor Red
        Read-Host "Pulsa Enter para volver"
        return
    }

    # Listar backups
    $options = @()
    foreach ($file in $backups) {
        $data = Get-Content $file.FullName -Raw | ConvertFrom-Json
        $options += @{
            Key = $file.FullName
            Label = "$($data.vm_name) - Backup del $($data.date) - RAM: $($data.config.memory)MB, CPUs: $($data.config.cpus)"
        }
    }

    $selected = Show-Menu -Title "Restaurar VM" -Prompt "Backups disponibles:" -Options $options
    $backupFile = $selected.Key
    $data = Get-Content $backupFile -Raw | ConvertFrom-Json
    $VMName = $data.vm_name

    # Verificar que la VM existe
    $vmExists = VBoxCmd @("list", "vms") | Out-String
    if ($vmExists -notmatch [regex]::Escape($VMName)) {
        Write-Host "[!] La VM '$VMName' ya no existe en VirtualBox." -ForegroundColor Red
        Read-Host "Pulsa Enter para volver"
        return
    }

    # Preparar VM (apagar si hace falta)
    $vmInfo = VBoxCmd @("showvminfo", $VMName, "--machinereadable") | Out-String
    $state = if ($vmInfo -match 'VMState="(.+?)"') { $Matches[1] } else { "?" }
    if ($state -ne "poweroff") {
        Write-Host "[*] Apagando VM..." -ForegroundColor Yellow
        VBoxCmd @("controlvm", $VMName, "poweroff") 2>$null | Out-Null
        VBoxCmd @("discardstate", $VMName) 2>$null | Out-Null
        Start-Sleep 3
    }

    Write-Host ""
    Write-Host "Restaurando '$VMName' al estado del $($data.date)..." -ForegroundColor Yellow
    Write-Host ""

    # Restaurar configuracion basica
    Write-Host "[ 20%] Restaurando RAM, CPUs, MAC..." -ForegroundColor Yellow
    VBoxCmd @("modifyvm", $VMName, "--memory", $data.config.memory, "--cpus", $data.config.cpus, "--vram", $data.config.vram) | Out-Null
    if ($data.config.macaddress1) {
        VBoxCmd @("modifyvm", $VMName, "--macaddress1", $data.config.macaddress1) | Out-Null
    }

    # Borrar todos los extradata actuales de camuflaje
    Write-Host "[ 50%] Limpiando camuflaje actual..." -ForegroundColor Yellow
    $currentExtra = VBoxCmd @("getextradata", $VMName, "enumerate")
    foreach ($line in $currentExtra) {
        if ($line -match 'Key:\s+(VBoxInternal/.+?),') {
            VBoxCmd @("setextradata", $VMName, $Matches[1]) | Out-Null
        }
    }

    # Restaurar extradata original
    Write-Host "[ 80%] Restaurando configuracion original..." -ForegroundColor Yellow
    foreach ($key in $data.extradata.PSObject.Properties.Name) {
        $value = $data.extradata.$key
        if ($value) {
            VBoxCmd @("setextradata", $VMName, $key, $value) | Out-Null
        }
    }

    Write-Host "[100%] Completado" -ForegroundColor Green
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "  '$VMName' restaurada al estado original" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "  Fecha del backup: $($data.date)" -ForegroundColor Gray
    Write-Host "  RAM: $($data.config.memory)MB | CPUs: $($data.config.cpus)" -ForegroundColor Gray
    Write-Host ""
    Read-Host "Pulsa Enter para continuar"
}

# =============================================================================
# MAIN
# =============================================================================
Show-Banner

# Menu principal
$mainOptions = @(
    @{ Key = "spoof";   Label = "Camuflar una VM (aplicar perfil de hardware)" }
    @{ Key = "restore"; Label = "Restaurar una VM (volver a la configuracion original)" }
    @{ Key = "exit";    Label = "Salir" }
)
$action = (Show-Menu -Title "Menu principal" -Prompt "Que quieres hacer?" -Options $mainOptions).Key

switch ($action) {
    "restore" {
        Restore-VM
        exit 0
    }
    "exit" { exit 0 }
}

# Flujo de camuflaje
$vm = Step-DetectVMs
Backup-VM -VMName $vm.Name
$mfgKey = Step-Manufacturer
$cpuKey = Step-CPU
$resources = Step-Resources -CurrentRAM $vm.RAM -CurrentCPUs $vm.CPUs
$diskKey = Step-Disk
$gpuKey = Step-GPU
$nicInfo = Step-NIC
$chipsetKey = Step-Chipset
$usbDevices = Step-USB -VMName $vm.Name

Apply-Spoof -VMName $vm.Name -MfgKey $mfgKey -CpuKey $cpuKey -Resources $resources -DiskKey $diskKey -GpuKey $gpuKey -NicInfo $nicInfo -ChipsetKey $chipsetKey -USBDevices $usbDevices
