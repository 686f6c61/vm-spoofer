#!/bin/bash
# =============================================================================
# VM Spoofer - Camufla una maquina virtual existente
#
# Detecta las VMs de VirtualBox ya instaladas, te deja elegir una,
# y le aplica un perfil de hardware real para que no sea detectada
# como maquina virtual por herramientas como systeminformation.
#
# Uso:  bash vm-spoofer.sh
#
# Requisitos: VirtualBox, jq, whiptail
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DB="$SCRIPT_DIR/hardware-db.json"
BACKUP_DIR="$SCRIPT_DIR/backups"
BACKTITLE="VM Spoofer - Camufla tu maquina virtual"

# --- Colores ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# =============================================================================
# DEPENDENCIAS
# =============================================================================
check_deps() {
  local missing=()
  command -v VBoxManage >/dev/null 2>&1 || missing+=("virtualbox")
  command -v jq >/dev/null 2>&1         || missing+=("jq")
  command -v whiptail >/dev/null 2>&1   || missing+=("whiptail")

  if [ ${#missing[@]} -gt 0 ]; then
    echo -e "${RED}[!] Faltan dependencias: ${missing[*]}${NC}"
    echo "    sudo apt install -y ${missing[*]}"
    exit 1
  fi
  if [ ! -f "$DB" ]; then
    echo -e "${RED}[!] No se encuentra hardware-db.json en $SCRIPT_DIR${NC}"
    exit 1
  fi
}

# =============================================================================
# FUNCIONES WHIPTAIL
# =============================================================================
wt_menu() {
  local title="$1"; shift; local text="$1"; shift
  local count=$(( $# / 2 ))
  local h=$(( count + 8 )); [ $h -gt 40 ] && h=40
  local w=85
  local lh=$count; [ $lh -gt 30 ] && lh=30
  local result=""
  result=$(whiptail --backtitle "$BACKTITLE" --title "$title" --notags --menu "$text" $h $w $lh "$@" 3>&1 1>&2 2>&3) || {
    echo ""; exit 0
  }
  echo "$result"
}

wt_checklist() {
  local title="$1"; shift; local text="$1"; shift
  local count=$(( $# / 3 ))
  local h=$(( count + 8 )); [ $h -gt 40 ] && h=40
  local lh=$count; [ $lh -gt 30 ] && lh=30
  whiptail --backtitle "$BACKTITLE" --title "$title" --notags --checklist "$text" $h 85 $lh "$@" 3>&1 1>&2 2>&3
}

wt_input() {
  whiptail --backtitle "$BACKTITLE" --title "$1" --inputbox "$2" 10 60 "$3" 3>&1 1>&2 2>&3
}

wt_yesno() {
  whiptail --backtitle "$BACKTITLE" --title "$1" --yesno "$2" 12 70 3>&1 1>&2 2>&3
}

wt_msg() {
  whiptail --backtitle "$BACKTITLE" --title "$1" --msgbox "$2" 22 75
}

gen_serial() {
  local prefix="$1" len="${2:-6}"
  local chars="0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ" result="$prefix"
  for i in $(seq 1 $len); do result+="${chars:RANDOM%${#chars}:1}"; done
  echo "$result"
}

gen_mac_suffix() { printf '%02X:%02X:%02X' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)); }

gen_uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())"; }

# =============================================================================
# PASO 1: Detectar VMs existentes
# =============================================================================
step_detect_vms() {
  echo -e "${YELLOW}[*] Buscando maquinas virtuales...${NC}"

  local items=()
  local vm_count=0

  while IFS= read -r line; do
    local name=$(echo "$line" | sed 's/"\(.*\)".*/\1/')
    local uuid=$(echo "$line" | grep -oP '\{.*\}')

    # Obtener info de la VM
    local info=$(VBoxManage showvminfo "$name" --machinereadable 2>/dev/null)
    local os=$(echo "$info" | grep "^ostype=" | cut -d'"' -f2)
    local ram=$(echo "$info" | grep "^memory=" | cut -d'=' -f2)
    local cpus=$(echo "$info" | grep "^cpus=" | cut -d'=' -f2)
    local state=$(echo "$info" | grep "^VMState=" | cut -d'"' -f2)

    # Icono segun SO
    local os_label=""
    case "$os" in
      *Windows*)  os_label="[WIN]" ;;
      *Ubuntu*|*Debian*|*Linux*|*Fedora*) os_label="[LNX]" ;;
      *MacOS*)    os_label="[MAC]" ;;
      *)          os_label="[---]" ;;
    esac

    local state_label=""
    case "$state" in
      running)    state_label="ENCENDIDA" ;;
      poweroff)   state_label="apagada" ;;
      saved)      state_label="guardada" ;;
      aborted)    state_label="abortada" ;;
      *)          state_label="$state" ;;
    esac

    items+=("$name" "$os_label $os | ${ram}MB RAM | ${cpus} CPUs | $state_label")
    vm_count=$((vm_count + 1))
  done < <(VBoxManage list vms 2>/dev/null)

  if [ $vm_count -eq 0 ]; then
    wt_msg "Sin VMs" "No se han encontrado maquinas virtuales en VirtualBox.\n\nCrea una VM primero con VirtualBox y vuelve a ejecutar este script."
    exit 0
  fi

  VM_NAME=$(wt_menu "Paso 1/8 - Selecciona una VM" \
    "Se han encontrado $vm_count maquinas virtuales.\nElige la que quieras camuflar:" \
    "${items[@]}")

  # Guardar info actual
  VM_INFO=$(VBoxManage showvminfo "$VM_NAME" --machinereadable 2>/dev/null)
  VM_CURRENT_RAM=$(echo "$VM_INFO" | grep "^memory=" | cut -d'=' -f2)
  VM_CURRENT_CPUS=$(echo "$VM_INFO" | grep "^cpus=" | cut -d'=' -f2)
  VM_CURRENT_OS=$(echo "$VM_INFO" | grep "^ostype=" | cut -d'"' -f2)
  VM_CURRENT_STATE=$(echo "$VM_INFO" | grep "^VMState=" | cut -d'"' -f2)

  # Verificar que esté apagada
  if [ "$VM_CURRENT_STATE" = "running" ]; then
    if wt_yesno "VM encendida" "La VM '$VM_NAME' esta encendida.\n\nHay que apagarla para aplicar los cambios.\n\nApagarla ahora?"; then
      VBoxManage controlvm "$VM_NAME" poweroff 2>/dev/null || true
      sleep 3
    else
      wt_msg "Cancelado" "Apaga la VM manualmente y vuelve a ejecutar el script."
      exit 0
    fi
  fi
}

# =============================================================================
# PASO 2: Perfil de hardware (fabricante)
# =============================================================================
step_manufacturer() {
  local items=()
  for key in $(jq -r '.manufacturers | keys[]' "$DB"); do
    local label=$(jq -r ".manufacturers[\"$key\"].label" "$DB")
    items+=("$key" "$label")
  done

  MFG_CHOICE=$(wt_menu "Paso 2/8 - Perfil de hardware" \
    "VM actual: $VM_NAME ($VM_CURRENT_OS)\nRAM actual: ${VM_CURRENT_RAM}MB | CPUs: $VM_CURRENT_CPUS\n\nElige el equipo que quieres simular:" \
    "${items[@]}")

  MFG_LABEL=$(jq -r ".manufacturers[\"$MFG_CHOICE\"].label" "$DB")
}

# =============================================================================
# PASO 3: CPU
# =============================================================================
step_cpu() {
  local items=()
  for key in $(jq -r '.cpus | keys[]' "$DB"); do
    local label=$(jq -r ".cpus[\"$key\"].label" "$DB")
    items+=("$key" "$label")
  done

  CPU_CHOICE=$(wt_menu "Paso 3/8 - Procesador" \
    "CPU que aparecera en systeminformation y /proc/cpuinfo.\nEl real no cambia, solo lo que el SO reporta." \
    "${items[@]}")

  CPU_LABEL=$(jq -r ".cpus[\"$CPU_CHOICE\"].label" "$DB")
  CPU_BRAND=$(jq -r ".cpus[\"$CPU_CHOICE\"].brand" "$DB")
}

# =============================================================================
# PASO 4: Recursos simulados (RAM y cores aparentes)
# =============================================================================
step_resources() {
  # RAM simulada
  local ram_items=()
  local host_ram=$(free -m | awk '/Mem:/{print $2}')

  for i in $(jq -r '.ram_options[] | .value' "$DB"); do
    local label=$(jq -r ".ram_options[] | select(.value==$i) | .label" "$DB")
    local current=""
    [ "$i" = "$VM_CURRENT_RAM" ] && current=" (actual)"
    ram_items+=("$i" "${label}${current}")
  done

  VM_RAM=$(wt_menu "Paso 4a/8 - RAM simulada" \
    "RAM actual de la VM: ${VM_CURRENT_RAM}MB\nRAM del host: ${host_ram}MB\n\nPuedes asignar mas RAM de la que tiene ahora.\nEl SO invitado vera esta cantidad como RAM fisica." \
    "${ram_items[@]}")

  # Cores simulados
  local core_items=()
  local host_cores=$(nproc)

  for i in $(jq -r '.cpu_cores_vm[] | .value' "$DB"); do
    local label=$(jq -r ".cpu_cores_vm[] | select(.value==$i) | .label" "$DB")
    local current=""
    [ "$i" = "$VM_CURRENT_CPUS" ] && current=" (actual)"
    core_items+=("$i" "${label}${current}")
  done

  VM_CPUS=$(wt_menu "Paso 4b/8 - Cores simulados" \
    "Cores actuales de la VM: $VM_CURRENT_CPUS\nCores del host: $host_cores\n\nEl SO invitado vera estos cores." \
    "${core_items[@]}")
}

# =============================================================================
# PASO 5: Disco, GPU, Red
# =============================================================================
step_peripherals() {
  # --- DISCO ---
  local disk_items=()
  for key in $(jq -r '.disks | keys[]' "$DB"); do
    local label=$(jq -r ".disks[\"$key\"].label" "$DB")
    disk_items+=("$key" "$label")
  done

  DISK_CHOICE=$(wt_menu "Paso 5a/8 - Disco duro" \
    "Nombre y serial del disco que aparecera en el sistema.\nEl disco real de la VM no cambia, solo la identidad." \
    "${disk_items[@]}")

  DISK_MODEL=$(jq -r ".disks[\"$DISK_CHOICE\"].model" "$DB")
  DISK_FW=$(jq -r ".disks[\"$DISK_CHOICE\"].firmware" "$DB")
  DISK_SERIAL=$(gen_serial "$(jq -r ".disks[\"$DISK_CHOICE\"].serial_prefix" "$DB")" 6)

  # --- GPU ---
  local gpu_items=()
  for key in $(jq -r '.gpus | keys[]' "$DB"); do
    local label=$(jq -r ".gpus[\"$key\"].label" "$DB")
    gpu_items+=("$key" "$label")
  done

  GPU_CHOICE=$(wt_menu "Paso 5b/8 - Tarjeta grafica" \
    "GPU que aparecera en lspci y systeminformation.\nEl adaptador real de VirtualBox (VMSVGA) se oculta." \
    "${gpu_items[@]}")

  GPU_PCI_NAME=$(jq -r ".gpus[\"$GPU_CHOICE\"].pci_name" "$DB")
  GPU_LABEL=$(jq -r ".gpus[\"$GPU_CHOICE\"].label" "$DB")

  # --- RED ---
  local nic_items=()
  for key in $(jq -r '.nics | keys[]' "$DB"); do
    local label=$(jq -r ".nics[\"$key\"].label" "$DB")
    nic_items+=("$key" "$label")
  done

  NIC_CHOICE=$(wt_menu "Paso 5c/8 - Tarjeta de red" \
    "Adaptador de red que aparecera en el sistema.\nSe cambiara el prefijo MAC al del fabricante real." \
    "${nic_items[@]}")

  NIC_MAC_PREFIX=$(jq -r ".nics[\"$NIC_CHOICE\"].mac_prefix" "$DB")
  NIC_PCI_NAME=$(jq -r ".nics[\"$NIC_CHOICE\"].pci_name" "$DB")

  # Generador de MAC: auto o manual
  local mac_suffix=$(gen_mac_suffix)
  local auto_mac="${NIC_MAC_PREFIX}:${mac_suffix}"

  local mac_choice=$(wt_menu "Generador de MAC" \
    "Direccion MAC para la tarjeta de red.\nEl prefijo ${NIC_MAC_PREFIX} corresponde al fabricante elegido.\n\nMAC generada: $auto_mac" \
    "auto"   "Usar MAC generada automaticamente ($auto_mac)" \
    "manual"  "Escribir una MAC personalizada" \
    "random"  "Generar otra MAC aleatoria con el mismo prefijo")

  case "$mac_choice" in
    auto)
      NIC_MAC="$auto_mac"
      ;;
    manual)
      NIC_MAC=$(wt_input "MAC personalizada" \
        "Escribe la MAC completa (formato XX:XX:XX:XX:XX:XX):" \
        "$auto_mac")
      ;;
    random)
      NIC_MAC="${NIC_MAC_PREFIX}:$(gen_mac_suffix)"
      # Mostrar y permitir regenerar
      while true; do
        if wt_yesno "MAC generada" "MAC: $NIC_MAC\n\nUsar esta MAC?"; then
          break
        fi
        NIC_MAC="${NIC_MAC_PREFIX}:$(gen_mac_suffix)"
      done
      ;;
  esac

  NIC_MAC_NOCOLON=$(echo "$NIC_MAC" | tr -d ':')
}

# =============================================================================
# PASO 5d: Dispositivos USB (camaras, micros, altavoces)
# =============================================================================
step_usb_devices() {
  # Detectar todos los dispositivos USB del host
  local usb_list=$(VBoxManage list usbhost 2>/dev/null)

  if [ -z "$usb_list" ]; then
    wt_msg "USB" "No se han detectado dispositivos USB conectados.\nPuedes conectarlos mas tarde desde VirtualBox."
    USB_FILTERS=()
    return
  fi

  # Parsear dispositivos USB en arrays
  local usb_items=()
  local usb_data=()
  local idx=0

  local current_vid="" current_pid="" current_mfg="" current_prod="" current_serial=""

  while IFS= read -r line; do
    case "$line" in
      VendorId:*)   current_vid=$(echo "$line" | grep -oP '0x\K[0-9a-fA-F]+') ;;
      ProductId:*)  current_pid=$(echo "$line" | grep -oP '0x\K[0-9a-fA-F]+') ;;
      Manufacturer:*) current_mfg=$(echo "$line" | sed 's/.*Manufacturer:\s*//') ;;
      Product:*)    current_prod=$(echo "$line" | sed 's/.*Product:\s*//') ;;
      SerialNumber:*) current_serial=$(echo "$line" | sed 's/.*SerialNumber:\s*//') ;;
      "")
        if [ -n "$current_prod" ] && [ -n "$current_vid" ]; then
          # Clasificar el dispositivo
          local category="otro"
          local prod_lower=$(echo "$current_prod $current_mfg" | tr '[:upper:]' '[:lower:]')

          if echo "$prod_lower" | grep -qE "cam|video|webcam|insta360|facetime|logitech c[0-9]|brio"; then
            category="camara"
          elif echo "$prod_lower" | grep -qE "mic|yeti|scarlett|focusrite|rode|audio.tech|shure|blue|elgato|hyperx|samson|at2020|snowball|wav"; then
            category="micro"
          elif echo "$prod_lower" | grep -qE "speaker|altavoz|audio|headset|headphone|jabra|sonos|bose|jbl|creative|dac|amp|interface"; then
            category="audio"
          elif echo "$prod_lower" | grep -qE "hub|root|bluetooth|receiver|keyboard|mouse|mystic|flipper"; then
            # Saltar dispositivos que no interesan
            current_vid="" current_pid="" current_mfg="" current_prod="" current_serial=""
            continue
          fi

          local icon=""
          case "$category" in
            camara) icon="[CAM]" ;;
            micro)  icon="[MIC]" ;;
            audio)  icon="[AUD]" ;;
            otro)   icon="[USB]" ;;
          esac

          local default="OFF"
          # Preseleccionar camaras, micros y audio
          [[ "$category" == "camara" || "$category" == "micro" || "$category" == "audio" ]] && default="ON"

          usb_items+=("$idx" "$icon $current_mfg $current_prod" "$default")
          usb_data+=("$current_vid|$current_pid|$current_mfg|$current_prod")
          idx=$((idx + 1))
        fi
        current_vid="" current_pid="" current_mfg="" current_prod="" current_serial=""
        ;;
    esac
  done <<< "$usb_list"

  if [ $idx -eq 0 ]; then
    wt_msg "USB" "No se han detectado dispositivos USB de interes\n(camaras, microfonos, altavoces).\n\nPuedes conectarlos mas tarde."
    USB_FILTERS=()
    return
  fi

  # Mostrar checklist
  local selected=$(wt_checklist "Dispositivos USB" \
    "Se han detectado $idx dispositivos USB.\nSelecciona los que quieres pasar a la VM.\n\nLos dispositivos marcados se conectaran\nautomaticamente cada vez que arranques la VM." \
    "${usb_items[@]}")

  USB_FILTERS=()
  for sel in $selected; do
    sel=$(echo "$sel" | tr -d '"')
    USB_FILTERS+=("${usb_data[$sel]}")
  done
}

# =============================================================================
# PASO 6: Chipset
# =============================================================================
step_chipset() {
  local items=()
  for key in $(jq -r '.lspci_templates | keys[]' "$DB"); do
    local desc=""
    case "$key" in
      intel_12th_gen) desc="Intel 12th Gen (Alder Lake) - Portatiles 2022-2023" ;;
      intel_13th_gen) desc="Intel 13th Gen (Raptor Lake) - Portatiles 2023-2024" ;;
      intel_14th_gen) desc="Intel 14th Gen (Raptor Lake-S) - Sobremesa 2024" ;;
      amd_zen4)       desc="AMD Zen 4 (Raphael/Phoenix) - 2023-2024" ;;
      apple_intel)    desc="Apple Intel (Coffee Lake) - MacBook 2019-2020" ;;
    esac
    items+=("$key" "$desc")
  done

  CHIPSET_CHOICE=$(wt_menu "Paso 6/8 - Chipset (dispositivos PCI)" \
    "Plantilla de chipset para lspci.\nCambia los nombres de TODOS los dispositivos PCI\npara que parezcan un chipset real." \
    "${items[@]}")
}

# =============================================================================
# PASO 7: Red de la VM
# =============================================================================
step_network_mode() {
  # Detectar interfaz activa del host
  local active_iface=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'dev \K\S+')

  local items=(
    "bridged"  "Puente - IP en tu red local (recomendado para acceso remoto)"
    "nat"      "NAT - IP privada, solo sale a internet"
    "keep"     "No cambiar - Mantener la configuracion actual de red"
  )

  NET_MODE=$(wt_menu "Paso 8/8 - Modo de red" \
    "Como quieres conectar la VM a la red?\n\nSi alguien de tu red necesita conectarse a la VM\n(escritorio remoto, SSH), elige 'Puente'." \
    "${items[@]}")

  if [ "$NET_MODE" = "bridged" ]; then
    local ifaces=()
    while IFS= read -r line; do
      local iface=$(echo "$line" | awk '{print $1}')
      local state=$(echo "$line" | awk '{print $2}')
      local ip=$(echo "$line" | awk '{print $3}')
      [[ "$iface" == lo || "$iface" == veth* || "$iface" == br-* || "$iface" == docker* ]] && continue
      ifaces+=("$iface" "$state $ip")
    done < <(ip -br addr show)

    BRIDGE_IFACE=$(wt_menu "Interfaz de red" \
      "Interfaz del host para el puente:" "${ifaces[@]}")
  fi
}

# =============================================================================
# RESUMEN
# =============================================================================
show_summary() {
  local usb_count=${#USB_FILTERS[@]}
  local usb_summary=""
  if [ $usb_count -gt 0 ]; then
    usb_summary="  USB:  $usb_count dispositivos (camaras/micros/altavoces)"
  else
    usb_summary="  USB:  ninguno seleccionado"
  fi

  local summary="VM SELECCIONADA
  Nombre:        $VM_NAME
  SO actual:     $VM_CURRENT_OS

CAMBIOS DE RECURSOS
  RAM:           ${VM_CURRENT_RAM}MB --> $((VM_RAM))MB ($((VM_RAM/1024))GB)
  CPUs:          $VM_CURRENT_CPUS --> $VM_CPUS

HARDWARE SIMULADO
  Equipo:        $MFG_LABEL
  CPU:           $CPU_LABEL
  Disco:         $DISK_MODEL
  GPU:           $GPU_LABEL
  MAC:           $NIC_MAC
  Red:           $NIC_PCI_NAME
  Chipset:       $CHIPSET_CHOICE
  Red VM:        $NET_MODE
$usb_summary"

  wt_yesno "Resumen - Aplicar cambios?" "$summary" || exit 0
}

# =============================================================================
# APLICAR CAMBIOS
# =============================================================================
apply_changes() {
  echo ""
  echo -e "${BOLD}============================================${NC}"
  echo -e "${BOLD}  Aplicando camuflaje a '$VM_NAME'${NC}"
  echo -e "${BOLD}============================================${NC}"
  echo ""

  # --- Recursos ---
  echo -e "${YELLOW}[  5%] Ajustando RAM y CPUs...${NC}"
  VBoxManage modifyvm "$VM_NAME" \
    --memory "$VM_RAM" \
    --cpus "$VM_CPUS" \
    --vram 128 \
    --graphicscontroller vmsvga \
    --accelerate3d on \
    --paravirt-provider none \
    --cpuid-portability-level 0 >/dev/null 2>&1

  # --- Red ---
  echo -e "${YELLOW}[ 10%] Configurando red...${NC}"
  if [ "$NET_MODE" = "bridged" ]; then
    VBoxManage modifyvm "$VM_NAME" --nic1 bridged --bridgeadapter1 "$BRIDGE_IFACE" >/dev/null 2>&1
  elif [ "$NET_MODE" = "nat" ]; then
    VBoxManage modifyvm "$VM_NAME" --nic1 nat >/dev/null 2>&1
  fi
  if [ "$NET_MODE" != "keep" ]; then
    VBoxManage modifyvm "$VM_NAME" --macaddress1 "$NIC_MAC_NOCOLON" >/dev/null 2>&1
  fi

  # --- VRDE ---
  echo -e "${YELLOW}[ 15%] Configurando escritorio remoto...${NC}"
  VBoxManage modifyvm "$VM_NAME" --vrde on --vrde-port 3389 --vrde-auth-type null >/dev/null 2>&1
  VBoxManage modifyvm "$VM_NAME" --vrde-property "Security/Method=Negotiate" >/dev/null 2>&1

  # --- Ocultar VM ---
  echo -e "${YELLOW}[ 20%] Ocultando identificadores de VirtualBox...${NC}"
  VBoxManage setextradata "$VM_NAME" "VBoxInternal/Devices/VMMDev/0/Config/GetHostTimeDisabled" "1"

  # --- DMI: Sistema ---
  echo -e "${YELLOW}[ 30%] Aplicando perfil DMI: Sistema...${NC}"
  local P="VBoxInternal/Devices/pcbios/0/Config"
  local mfg=".manufacturers[\"$MFG_CHOICE\"]"
  local sys_serial=$(gen_serial "PF" 6)

  # Guardar valores para uso posterior (post-install, resumen)
  SYS_VENDOR=$(jq -r "$mfg.system.vendor" "$DB")
  SYS_PRODUCT=$(jq -r "$mfg.system.product" "$DB")

  VBoxManage setextradata "$VM_NAME" "$P/DmiSystemVendor"  "$SYS_VENDOR"
  VBoxManage setextradata "$VM_NAME" "$P/DmiSystemProduct" "$SYS_PRODUCT"
  VBoxManage setextradata "$VM_NAME" "$P/DmiSystemVersion" "$(jq -r "$mfg.system.version" "$DB")"
  VBoxManage setextradata "$VM_NAME" "$P/DmiSystemSKU"     "$(jq -r "$mfg.system.sku" "$DB")"
  VBoxManage setextradata "$VM_NAME" "$P/DmiSystemFamily"  "$(jq -r "$mfg.system.family" "$DB")"
  VBoxManage setextradata "$VM_NAME" "$P/DmiSystemSerial"  "$sys_serial"
  VBoxManage setextradata "$VM_NAME" "$P/DmiSystemUuid"    "$(gen_uuid)"

  # --- DMI: BIOS ---
  echo -e "${YELLOW}[ 40%] Aplicando perfil DMI: BIOS...${NC}"
  VBoxManage setextradata "$VM_NAME" "$P/DmiBIOSVendor"        "$(jq -r "$mfg.bios.vendor" "$DB")"
  VBoxManage setextradata "$VM_NAME" "$P/DmiBIOSVersion"       "$(jq -r "$mfg.bios.version" "$DB")"
  VBoxManage setextradata "$VM_NAME" "$P/DmiBIOSReleaseDate"   "$(jq -r "$mfg.bios.date" "$DB")"
  VBoxManage setextradata "$VM_NAME" "$P/DmiBIOSReleaseMajor"  "$(jq -r "$mfg.bios.major" "$DB")"
  VBoxManage setextradata "$VM_NAME" "$P/DmiBIOSReleaseMinor"  "$(jq -r "$mfg.bios.minor" "$DB")"
  VBoxManage setextradata "$VM_NAME" "$P/DmiBIOSFirmwareMajor" "$(jq -r "$mfg.bios.firmware_major" "$DB")"
  VBoxManage setextradata "$VM_NAME" "$P/DmiBIOSFirmwareMinor" "$(jq -r "$mfg.bios.firmware_minor" "$DB")"

  # --- DMI: Placa base ---
  echo -e "${YELLOW}[ 50%] Aplicando perfil DMI: Placa base...${NC}"
  VBoxManage setextradata "$VM_NAME" "$P/DmiBoardVendor"     "$(jq -r "$mfg.board.vendor" "$DB")"
  VBoxManage setextradata "$VM_NAME" "$P/DmiBoardProduct"    "$(jq -r "$mfg.board.product" "$DB")"
  VBoxManage setextradata "$VM_NAME" "$P/DmiBoardVersion"    "$(jq -r "$mfg.board.version" "$DB")"
  VBoxManage setextradata "$VM_NAME" "$P/DmiBoardSerial"     "$(gen_serial 'L1HF' 7)"
  VBoxManage setextradata "$VM_NAME" "$P/DmiBoardAssetTag"   "Not Available"
  VBoxManage setextradata "$VM_NAME" "$P/DmiBoardLocInChass" "Not Available"

  # --- DMI: Chasis ---
  echo -e "${YELLOW}[ 55%] Aplicando perfil DMI: Chasis...${NC}"
  VBoxManage setextradata "$VM_NAME" "$P/DmiChassisVendor"   "$(jq -r "$mfg.chassis.vendor" "$DB")"
  VBoxManage setextradata "$VM_NAME" "$P/DmiChassisVersion"  "$(jq -r "$mfg.chassis.version" "$DB")"
  VBoxManage setextradata "$VM_NAME" "$P/DmiChassisSerial"   "$sys_serial"
  VBoxManage setextradata "$VM_NAME" "$P/DmiChassisAssetTag" "No Asset Information"
  VBoxManage setextradata "$VM_NAME" "$P/DmiChassisType"     "$(jq -r "$mfg.chassis.type" "$DB")"

  # --- ACPI ---
  echo -e "${YELLOW}[ 60%] Aplicando ACPI...${NC}"
  VBoxManage setextradata "$VM_NAME" "VBoxInternal/Devices/acpi/0/Config/AcpiOemId"     "$(jq -r "$mfg.acpi.oem_id" "$DB")"
  VBoxManage setextradata "$VM_NAME" "VBoxInternal/Devices/acpi/0/Config/AcpiCreatorId"  "$(jq -r "$mfg.acpi.creator_id" "$DB")"
  VBoxManage setextradata "$VM_NAME" "VBoxInternal/Devices/acpi/0/Config/AcpiCreatorRev" "$(jq -r "$mfg.acpi.creator_rev" "$DB")"

  # --- Disco ---
  echo -e "${YELLOW}[ 70%] Aplicando identidad del disco...${NC}"
  VBoxManage setextradata "$VM_NAME" "VBoxInternal/Devices/ahci/0/Config/Port0/SerialNumber"     "$DISK_SERIAL"
  VBoxManage setextradata "$VM_NAME" "VBoxInternal/Devices/ahci/0/Config/Port0/FirmwareRevision"  "$DISK_FW"
  VBoxManage setextradata "$VM_NAME" "VBoxInternal/Devices/ahci/0/Config/Port0/ModelNumber"       "$DISK_MODEL"

  VBoxManage setextradata "$VM_NAME" "VBoxInternal/Devices/ahci/0/Config/Port1/ModelNumber"       "HL-DT-ST DVDRAM GU90N"
  VBoxManage setextradata "$VM_NAME" "VBoxInternal/Devices/ahci/0/Config/Port1/SerialNumber"      "$(gen_serial 'K8OD' 6)"
  VBoxManage setextradata "$VM_NAME" "VBoxInternal/Devices/ahci/0/Config/Port1/FirmwareRevision"  "A101"

  # --- USB: Activar USB 3.0 y crear filtros ---
  echo -e "${YELLOW}[ 75%] Configurando dispositivos USB...${NC}"
  VBoxManage modifyvm "$VM_NAME" --usb-xhci on >/dev/null 2>&1 || true

  if [ ${#USB_FILTERS[@]} -gt 0 ]; then
    local filter_idx=0
    for usb_entry in "${USB_FILTERS[@]}"; do
      local vid=$(echo "$usb_entry" | cut -d'|' -f1)
      local pid=$(echo "$usb_entry" | cut -d'|' -f2)
      local mfg=$(echo "$usb_entry" | cut -d'|' -f3)
      local prod=$(echo "$usb_entry" | cut -d'|' -f4)

      VBoxManage usbfilter add "$filter_idx" --target "$VM_NAME" \
        --name "$mfg $prod" \
        --vendorid "$vid" \
        --productid "$pid" >/dev/null 2>&1 || true

      echo -e "    ${GREEN}[+] $prod ($mfg)${NC}"
      filter_idx=$((filter_idx + 1))
    done
    echo -e "    ${GREEN}[OK] $filter_idx dispositivos USB configurados${NC}"
  else
    echo -e "    ${YELLOW}[!] Sin dispositivos USB seleccionados${NC}"
  fi

  # --- Generar script de post-instalacion ---
  echo -e "${YELLOW}[ 80%] Generando scripts de verificacion...${NC}"

  local LSPCI_TPL=".lspci_templates[\"$CHIPSET_CHOICE\"]"
  local HOST_BRIDGE=$(jq -r "$LSPCI_TPL.host_bridge" "$DB")
  local ISA_BRIDGE=$(jq -r "$LSPCI_TPL.isa_bridge" "$DB")
  local IDE_CTRL=$(jq -r "$LSPCI_TPL.ide" "$DB")
  local GUEST_SVC=$(jq -r "$LSPCI_TPL.guest_service" "$DB")
  local ACPI_BRIDGE=$(jq -r "$LSPCI_TPL.acpi_bridge" "$DB")
  local AUDIO_CTRL=$(jq -r "$LSPCI_TPL.audio" "$DB")

  # Script para ejecutar DENTRO de la VM (Linux)
  cat > "$SCRIPT_DIR/post-install-linux.sh" << POSTEOF
#!/bin/bash
# =============================================================================
# Post-instalacion para VM Linux
# Ejecuta este script DENTRO de la maquina virtual para completar el camuflaje.
# Necesita permisos de administrador (sudo).
# =============================================================================
set -e

echo ""
echo "============================================"
echo "  Completando camuflaje de la VM (Linux)"
echo "============================================"
echo ""

# 1. Camuflar lspci
echo "[1/4] Camuflando dispositivos PCI (lspci)..."
if [ ! -f /usr/bin/lspci.real ] && command -v lspci >/dev/null 2>&1; then
  sudo cp /usr/bin/lspci /usr/bin/lspci.real
fi

sudo tee /usr/local/bin/lspci > /dev/null << 'LSPCI_SCRIPT'
#!/bin/bash
/usr/bin/lspci.real "\$@" | sed \\
  -e "s/VMware SVGA II Adapter/$GPU_PCI_NAME/g" \\
  -e "s/InnoTek Systemberatung GmbH VirtualBox Guest Service/$GUEST_SVC/g" \\
  -e "s/Intel Corporation 440FX - 82441FX PMC \[Natoma\]/$HOST_BRIDGE/g" \\
  -e "s/82371SB PIIX3 ISA \[Natoma\/Triton II\]/$ISA_BRIDGE/g" \\
  -e "s/82371AB\/EB\/MB PIIX4 IDE/$IDE_CTRL/g" \\
  -e "s/82371AB\/EB\/MB PIIX4 ACPI/$ACPI_BRIDGE/g" \\
  -e "s/82801AA AC.97 Audio Controller/$AUDIO_CTRL/g" \\
  -e "s/Intel Corporation 82540EM Gigabit Ethernet Controller/$NIC_PCI_NAME/g"
LSPCI_SCRIPT
sudo chmod +x /usr/local/bin/lspci
sudo ln -sf /usr/local/bin/lspci /usr/bin/lspci
echo "    [OK] lspci camuflado"

# 2. Bloquear modulos de VM
echo "[2/4] Bloqueando modulos que delatan la VM..."
sudo tee /etc/modprobe.d/blacklist-vm.conf > /dev/null << 'EOF'
blacklist vboxguest
blacklist vboxsf
blacklist vboxvideo
blacklist vmw_vmci
blacklist vmw_vsock_vmci_transport
blacklist vmwgfx
EOF
echo "    [OK] Modulos bloqueados"

# 3. Hostname
echo "[3/4] Configurando hostname..."
sudo hostnamectl set-hostname \$(cat /sys/class/dmi/id/product_family 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | head -c 30) 2>/dev/null || true
echo "    [OK] Hostname actualizado"

# 4. Instalar herramientas utiles
echo "[4/4] Instalando herramientas..."
sudo apt install -y openssh-server pciutils 2>/dev/null || true
sudo systemctl enable ssh 2>/dev/null || true
sudo systemctl start ssh 2>/dev/null || true
echo "    [OK] SSH instalado"

echo ""
echo "============================================"
echo "  Camuflaje completado"
echo "============================================"
echo ""
echo "  Reinicia la VM para aplicar todos los cambios:"
echo "    sudo reboot"
echo ""
echo "  Despues del reinicio, ejecuta verify-vm.sh"
echo "  para comprobar la puntuacion."
echo ""
POSTEOF
  chmod +x "$SCRIPT_DIR/post-install-linux.sh"

  # Instrucciones para Windows
  cat > "$SCRIPT_DIR/post-install-windows.txt" << WINEOF
============================================
 Post-instalacion para VM Windows
============================================

El camuflaje de hardware (BIOS, DMI, disco, MAC)
ya esta aplicado desde fuera de la VM.

Para completar la verificacion en Windows:

1. Abre PowerShell como Administrador
2. Ejecuta estos comandos para comprobar:

   # Ver fabricante del sistema
   Get-WmiObject Win32_ComputerSystem | Select Manufacturer, Model

   # Ver BIOS
   Get-WmiObject Win32_BIOS | Select Manufacturer, SMBIOSBIOSVersion

   # Ver disco
   Get-WmiObject Win32_DiskDrive | Select Model, SerialNumber

   # Ver tarjeta de red
   Get-WmiObject Win32_NetworkAdapter | Where {\$_.MACAddress} | Select Name, MACAddress

3. Para verificar con systeminformation (Node.js):
   - Descarga Node.js desde https://nodejs.org
   - Abre un terminal y ejecuta:
     npm install -g systeminformation
     npx systeminformation

Los valores deberian mostrar:
  Fabricante: $SYS_VENDOR
  Modelo:     $SYS_PRODUCT
  Disco:      $DISK_MODEL
  MAC:        $NIC_MAC
WINEOF

  # Copiar verify-vm.sh si existe
  if [ -f "$SCRIPT_DIR/verify-vm.sh" ]; then
    echo -e "${YELLOW}[ 90%] Script de verificacion listo${NC}"
  fi

  echo -e "${YELLOW}[100%] Completado${NC}"
  echo ""
  echo -e "${GREEN}============================================${NC}"
  echo -e "${GREEN}  Camuflaje aplicado a '$VM_NAME'${NC}"
  echo -e "${GREEN}============================================${NC}"
  echo ""
  echo -e "  ${BOLD}Resumen de cambios:${NC}"
  echo -e "  Equipo:      $MFG_LABEL"
  echo -e "  CPU:         $CPU_LABEL"
  echo -e "  RAM:         ${VM_CURRENT_RAM}MB --> ${VM_RAM}MB (${BOLD}$((VM_RAM/1024))GB${NC})"
  echo -e "  CPUs:        $VM_CURRENT_CPUS --> $VM_CPUS"
  echo -e "  Disco:       $DISK_MODEL"
  echo -e "  GPU:         $GPU_LABEL"
  echo -e "  MAC:         $NIC_MAC"
  echo -e "  Chipset:     $CHIPSET_CHOICE"
  echo ""

  # Detectar si es Windows o Linux
  local is_windows=false
  echo "$VM_CURRENT_OS" | grep -qi "windows" && is_windows=true

  echo -e "  ${BOLD}Siguientes pasos:${NC}"
  echo ""
  echo -e "  ${CYAN}1. Arrancar la VM:${NC}"
  echo -e "     VBoxManage startvm \"$VM_NAME\" --type headless"
  echo ""

  if [ "$is_windows" = true ]; then
    echo -e "  ${CYAN}2. Conectarse por escritorio remoto (RDP):${NC}"
    echo -e "     xfreerdp3 /v:127.0.0.1:3389 /sec:rdp /cert:ignore /u:\"\" /p:\"\" +clipboard"
    echo ""
    echo -e "  ${CYAN}3. Verificar dentro de Windows:${NC}"
    echo -e "     Abrir PowerShell y ejecutar:"
    echo -e "     ${YELLOW}Get-WmiObject Win32_ComputerSystem | Select Manufacturer, Model${NC}"
    echo ""
    echo -e "     O instalar Node.js + systeminformation (ver post-install-windows.txt)"
  else
    echo -e "  ${CYAN}2. Copiar y ejecutar el script de post-instalacion:${NC}"
    echo -e "     (sustituye USUARIO e IP por los de tu VM)"
    echo -e "     ${YELLOW}scp post-install-linux.sh USUARIO@IP:/tmp/${NC}"
    echo -e "     ${YELLOW}ssh USUARIO@IP 'bash /tmp/post-install-linux.sh'${NC}"
    echo ""
    echo -e "  ${CYAN}3. Reiniciar la VM y verificar:${NC}"
    echo -e "     ${YELLOW}scp verify-vm.sh USUARIO@IP:/tmp/${NC}"
    echo -e "     ${YELLOW}ssh USUARIO@IP 'bash /tmp/verify-vm.sh'${NC}"
  fi

  echo ""
  echo -e "  ${CYAN}Conexion desde Mac (Microsoft Remote Desktop):${NC}"
  echo -e "     Servidor: IP_DE_LA_VM:3389"
  echo -e "     Usuario:  (tu usuario de la VM)"
  echo ""

  # Preguntar si arrancar
  if wt_yesno "Arrancar VM" "Quieres arrancar la VM '$VM_NAME' ahora?"; then
    echo -e "${YELLOW}[*] Arrancando VM...${NC}"
    VBoxManage startvm "$VM_NAME" --type headless 2>&1
    echo -e "${GREEN}[OK] VM arrancada${NC}"

    # Esperar un poco y mostrar IP si es bridged
    if [ "$NET_MODE" = "bridged" ]; then
      echo -e "${YELLOW}[*] Esperando a que la VM obtenga IP...${NC}"
      sleep 20
      local vm_ip=$(ip neigh show | grep -i "${NIC_MAC_NOCOLON:0:2}:${NIC_MAC_NOCOLON:2:2}:${NIC_MAC_NOCOLON:4:2}" | awk '{print $1}' | head -1)
      if [ -z "$vm_ip" ]; then
        # Buscar con formato correcto
        local mac_search=$(echo "$NIC_MAC" | tr '[:upper:]' '[:lower:]')
        vm_ip=$(ip neigh show | grep -i "$mac_search" | awk '{print $1}' | head -1)
      fi
      if [ -n "$vm_ip" ]; then
        echo -e "${GREEN}[OK] IP de la VM: $vm_ip${NC}"
        echo ""
        echo -e "  Para conectar:  ${YELLOW}ssh usuario@$vm_ip${NC}"
        echo -e "  Desde Mac RDP:  ${YELLOW}$vm_ip${NC}"
      else
        echo -e "${YELLOW}[!] Aun sin IP. Espera un momento y ejecuta:${NC}"
        echo -e "    ip neigh show | grep -i '$(echo "$NIC_MAC_PREFIX" | tr '[:upper:]' '[:lower:]')'"
      fi
    fi
  fi

  echo ""
}

# =============================================================================
# MAIN
# =============================================================================
# =============================================================================
# BACKUP: Guardar configuracion original
# =============================================================================
backup_vm() {
  mkdir -p "$BACKUP_DIR"

  local backup_file="$BACKUP_DIR/${VM_NAME}.backup.json"

  # Solo guardar si NO existe un backup previo (el primero siempre es el original)
  if [ -f "$backup_file" ]; then
    echo -e "${CYAN}[*] Backup de '$VM_NAME' ya existe (configuracion original conservada).${NC}"
    return
  fi

  echo -e "${YELLOW}[*] Guardando backup original de '$VM_NAME'...${NC}"

  # Leer configuracion actual
  local info=$(VBoxManage showvminfo "$VM_NAME" --machinereadable 2>/dev/null)
  local memory=$(echo "$info" | grep "^memory=" | cut -d'=' -f2)
  local cpus=$(echo "$info" | grep "^cpus=" | cut -d'=' -f2)
  local mac=$(echo "$info" | grep "^macaddress1=" | cut -d'"' -f2)
  local nic=$(echo "$info" | grep "^nic1=" | cut -d'"' -f2)
  local vram=$(echo "$info" | grep "^vram=" | cut -d'=' -f2)

  # Leer extradata
  local extradata="{"
  local first=true
  while IFS= read -r line; do
    if [[ "$line" =~ ^Key:\ (.+),\ Value:\ (.*) ]]; then
      local key="${BASH_REMATCH[1]}"
      local val="${BASH_REMATCH[2]}"
      # Escapar comillas en el valor
      val=$(echo "$val" | sed 's/"/\\"/g')
      if [ "$first" = true ]; then
        first=false
      else
        extradata+=","
      fi
      extradata+="\"$key\":\"$val\""
    fi
  done < <(VBoxManage getextradata "$VM_NAME" enumerate 2>/dev/null)
  extradata+="}"

  # Escribir JSON
  cat > "$backup_file" << BKEOF
{
  "vm_name": "$VM_NAME",
  "date": "$(date '+%Y-%m-%d %H:%M:%S')",
  "config": {
    "memory": "$memory",
    "cpus": "$cpus",
    "macaddress1": "$mac",
    "nic1": "$nic",
    "vram": "$vram"
  },
  "extradata": $extradata
}
BKEOF

  echo -e "${GREEN}[OK] Backup guardado en: $backup_file${NC}"
}

# =============================================================================
# RESTORE: Restaurar configuracion original
# =============================================================================
restore_vm() {
  if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR"/*.backup.json 2>/dev/null)" ]; then
    wt_msg "Sin backups" "No hay backups disponibles.\n\nLa carpeta backups/ esta vacia o no existe.\nAplica un camuflaje primero para generar un backup."
    return
  fi

  # Listar backups
  local items=()
  for file in "$BACKUP_DIR"/*.backup.json; do
    local name=$(jq -r '.vm_name' "$file")
    local date=$(jq -r '.date' "$file")
    local ram=$(jq -r '.config.memory' "$file")
    local cpus=$(jq -r '.config.cpus' "$file")
    items+=("$file" "$name - Backup del $date - RAM: ${ram}MB, CPUs: $cpus")
  done

  local selected=$(wt_menu "Restaurar VM" \
    "Backups disponibles.\nElige el que quieras restaurar:" \
    "${items[@]}")
  [ -z "$selected" ] && return

  local vm_name=$(jq -r '.vm_name' "$selected")
  local backup_date=$(jq -r '.date' "$selected")

  # Verificar que la VM existe
  if ! VBoxManage showvminfo "$vm_name" &>/dev/null; then
    wt_msg "Error" "La VM '$vm_name' ya no existe en VirtualBox."
    return
  fi

  # Preparar VM
  local state=$(VBoxManage showvminfo "$vm_name" --machinereadable 2>/dev/null | grep "^VMState=" | cut -d'"' -f2)
  if [ "$state" != "poweroff" ]; then
    echo -e "${YELLOW}[*] Preparando VM...${NC}"
    VBoxManage controlvm "$vm_name" poweroff 2>/dev/null || true
    VBoxManage discardstate "$vm_name" 2>/dev/null || true
    sleep 3
  fi

  echo ""
  echo -e "${YELLOW}Restaurando '$vm_name' al estado del $backup_date...${NC}"
  echo ""

  # Restaurar config basica
  echo -e "${YELLOW}[ 20%] Restaurando RAM, CPUs, MAC...${NC}"
  local mem=$(jq -r '.config.memory' "$selected")
  local cpu=$(jq -r '.config.cpus' "$selected")
  local vr=$(jq -r '.config.vram' "$selected")
  local ma=$(jq -r '.config.macaddress1' "$selected")
  VBoxManage modifyvm "$vm_name" --memory "$mem" --cpus "$cpu" --vram "$vr" 2>/dev/null || true
  [ -n "$ma" ] && [ "$ma" != "null" ] && VBoxManage modifyvm "$vm_name" --macaddress1 "$ma" 2>/dev/null || true

  # Borrar extradata de camuflaje
  echo -e "${YELLOW}[ 50%] Limpiando camuflaje actual...${NC}"
  while IFS= read -r line; do
    if [[ "$line" =~ ^Key:\ (VBoxInternal/.+), ]]; then
      VBoxManage setextradata "$vm_name" "${BASH_REMATCH[1]}" 2>/dev/null || true
    fi
  done < <(VBoxManage getextradata "$vm_name" enumerate 2>/dev/null)

  # Restaurar extradata original
  echo -e "${YELLOW}[ 80%] Restaurando configuracion original...${NC}"
  for key in $(jq -r '.extradata | keys[]' "$selected"); do
    local val=$(jq -r ".extradata[\"$key\"]" "$selected")
    [ -n "$val" ] && [ "$val" != "null" ] && VBoxManage setextradata "$vm_name" "$key" "$val" 2>/dev/null || true
  done

  echo -e "${GREEN}[100%] Completado${NC}"
  echo ""
  echo -e "${GREEN}============================================${NC}"
  echo -e "${GREEN}  '$vm_name' restaurada al estado original${NC}"
  echo -e "${GREEN}============================================${NC}"
  echo -e "  Fecha del backup: $backup_date"
  echo -e "  RAM: ${mem}MB | CPUs: $cpu"
  echo ""

  wt_msg "Restauracion completada" "'$vm_name' restaurada al estado del $backup_date.\n\nRAM: ${mem}MB | CPUs: $cpu\n\nLos identificadores de hardware han vuelto a su configuracion original."
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  check_deps

  wt_msg "VM Spoofer" \
"Bienvenido a VM Spoofer

Este asistente detecta tus maquinas virtuales
de VirtualBox y les aplica un perfil de hardware
real para que no sean detectadas como VM.

Que hace:
- Cambia el fabricante, BIOS, placa base, chasis
- Simula un disco duro real (WD, Samsung, etc.)
- Cambia la GPU y tarjeta de red
- Ajusta la RAM y CPUs simulados
- Genera scripts para completar el camuflaje
  dentro de la VM (Linux y Windows)
- Incluye un verificador con systeminformation
- Guarda backup automatico antes de aplicar

Pulsa OK para comenzar."

  # Menu principal
  local action=$(wt_menu "Menu principal" \
    "Que quieres hacer?" \
    "spoof"   "Camuflar una VM (aplicar perfil de hardware)" \
    "restore" "Restaurar una VM (volver a la configuracion original)" \
    "exit"    "Salir")

  case "$action" in
    restore) restore_vm; exit 0 ;;
    exit)    exit 0 ;;
  esac

  # Flujo de camuflaje
  step_detect_vms
  backup_vm
  step_manufacturer
  step_cpu
  step_resources
  step_peripherals
  step_chipset
  step_usb_devices
  step_network_mode
  show_summary
  apply_changes
}

main "$@"
