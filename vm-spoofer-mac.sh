#!/bin/bash
# =============================================================================
# VM Spoofer para macOS - Camufla una máquina virtual existente
#
# Detecta las VMs de VirtualBox ya instaladas, te deja elegir una,
# y le aplica un perfil de hardware real para que no sea detectada
# como máquina virtual por herramientas como systeminformation.
#
# Detecta automáticamente si el Mac es Intel o Apple Silicon.
#
# Uso:  bash vm-spoofer-mac.sh
#
# Requisitos: VirtualBox, jq, dialog (brew install dialog jq)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DB="$SCRIPT_DIR/hardware-db.json"
BACKUP_DIR="$SCRIPT_DIR/backups"

# --- Colores ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Detectar arquitectura ---
MAC_ARCH=$(uname -m)
if [ "$MAC_ARCH" = "arm64" ]; then
  MAC_TYPE="Apple Silicon"
  BREW_PREFIX="/opt/homebrew"
else
  MAC_TYPE="Intel"
  BREW_PREFIX="/usr/local"
fi

# --- Buscar VBoxManage ---
VBOX=""
for path in "$BREW_PREFIX/bin/VBoxManage" "/usr/local/bin/VBoxManage" "/Applications/VirtualBox.app/Contents/MacOS/VBoxManage" "$(which VBoxManage 2>/dev/null)"; do
  if [ -x "$path" ]; then
    VBOX="$path"
    break
  fi
done

# =============================================================================
# DEPENDENCIAS
# =============================================================================
check_deps() {
  local missing=()

  if [ -z "$VBOX" ]; then
    echo -e "${RED}[!] VirtualBox no encontrado.${NC}"
    echo "    Descárgalo desde https://www.virtualbox.org"
    echo "    O instálalo con: brew install --cask virtualbox"
    exit 1
  fi

  command -v jq >/dev/null 2>&1 || missing+=("jq")
  command -v dialog >/dev/null 2>&1 || missing+=("dialog")

  if [ ${#missing[@]} -gt 0 ]; then
    echo -e "${RED}[!] Faltan dependencias: ${missing[*]}${NC}"
    echo ""
    if command -v brew >/dev/null 2>&1; then
      echo "    Instalar con: brew install ${missing[*]}"
      echo ""
      read -p "    ¿Instalar ahora? (s/n): " yn
      if [ "$yn" = "s" ] || [ "$yn" = "S" ]; then
        brew install "${missing[@]}"
      else
        exit 1
      fi
    else
      echo "    Primero instala Homebrew: https://brew.sh"
      echo "    Luego: brew install ${missing[*]}"
      exit 1
    fi
  fi

  if [ ! -f "$DB" ]; then
    echo -e "${RED}[!] No se encuentra hardware-db.json en $SCRIPT_DIR${NC}"
    exit 1
  fi
}

# =============================================================================
# FUNCIONES DE MENÚ (dialog para macOS)
# =============================================================================
dl_menu() {
  local title="$1"; shift; local text="$1"; shift
  local count=$(( $# / 2 ))
  local h=$(( count + 8 )); [ $h -gt 35 ] && h=35
  local lh=$count; [ $lh -gt 25 ] && lh=25
  local result=""
  result=$(dialog --backtitle "VM Spoofer - macOS $MAC_TYPE" --title "$title" \
    --no-tags --menu "$text" $h 80 $lh "$@" 2>&1 >/dev/tty)
  if [ $? -ne 0 ]; then
    clear
    echo "Cancelado."
    exit 0
  fi
  echo "$result"
}

dl_checklist() {
  local title="$1"; shift; local text="$1"; shift
  local count=$(( $# / 3 ))
  local h=$(( count + 8 )); [ $h -gt 35 ] && h=35
  local lh=$count; [ $lh -gt 25 ] && lh=25
  local result=""
  result=$(dialog --backtitle "VM Spoofer - macOS $MAC_TYPE" --title "$title" \
    --no-tags --checklist "$text" $h 80 $lh "$@" 2>&1 >/dev/tty)
  echo "$result"
}

dl_input() {
  local title="$1"
  local text="$2"
  local default="$3"
  local result=""
  result=$(dialog --backtitle "VM Spoofer - macOS $MAC_TYPE" --title "$title" \
    --inputbox "$text" 10 60 "$default" 2>&1 >/dev/tty)
  echo "$result"
}

dl_yesno() {
  local title="$1"
  local text="$2"
  dialog --backtitle "VM Spoofer - macOS $MAC_TYPE" --title "$title" \
    --yesno "$text" 10 60 2>&1 >/dev/tty
  return $?
}

dl_msg() {
  local title="$1"
  local text="$2"
  dialog --backtitle "VM Spoofer - macOS $MAC_TYPE" --title "$title" \
    --msgbox "$text" 20 70 2>&1 >/dev/tty
}

# --- Funciones auxiliares ---
gen_serial() {
  local prefix="$1" len="${2:-6}"
  local chars="0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ" result="$prefix"
  for i in $(seq 1 $len); do result+="${chars:RANDOM%${#chars}:1}"; done
  echo "$result"
}

gen_mac_suffix() { printf '%02X:%02X:%02X' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)); }

gen_uuid() {
  uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' || \
  python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null
}

get_host_ram_mb() {
  local bytes=$(sysctl -n hw.memsize 2>/dev/null)
  echo $(( bytes / 1048576 ))
}

get_host_cores() {
  sysctl -n hw.ncpu 2>/dev/null || echo "4"
}

# =============================================================================
# PASO 1: Detectar VMs existentes
# =============================================================================
step_detect_vms() {
  echo -e "${YELLOW}[*] Buscando máquinas virtuales (macOS $MAC_TYPE)...${NC}"

  local items=()
  local vm_count=0

  while IFS= read -r line; do
    local name=$(echo "$line" | sed 's/"\(.*\)".*/\1/')
    local uuid=$(echo "$line" | grep -oP '\{.*\}' 2>/dev/null || echo "$line" | sed 's/.*{\(.*\)}/{\1}/')

    local info=$("$VBOX" showvminfo "$name" --machinereadable 2>/dev/null)
    local os=$(echo "$info" | grep "^ostype=" | cut -d'"' -f2)
    local ram=$(echo "$info" | grep "^memory=" | cut -d'=' -f2)
    local cpus=$(echo "$info" | grep "^cpus=" | cut -d'=' -f2)
    local state=$(echo "$info" | grep "^VMState=" | cut -d'"' -f2)

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
  done < <("$VBOX" list vms 2>/dev/null)

  if [ $vm_count -eq 0 ]; then
    dl_msg "Sin VMs" "No se han encontrado máquinas virtuales en VirtualBox.\n\nCrea una VM primero con VirtualBox y vuelve a ejecutar este script."
    exit 0
  fi

  VM_NAME=$(dl_menu "Paso 1/8 - Selecciona una VM" \
    "Mac $MAC_TYPE detectado.\nSe han encontrado $vm_count máquinas virtuales.\nElige la que quieras camuflar:" \
    "${items[@]}")

  # Guardar info actual
  VM_INFO=$("$VBOX" showvminfo "$VM_NAME" --machinereadable 2>/dev/null)
  VM_CURRENT_RAM=$(echo "$VM_INFO" | grep "^memory=" | cut -d'=' -f2)
  VM_CURRENT_CPUS=$(echo "$VM_INFO" | grep "^cpus=" | cut -d'=' -f2)
  VM_CURRENT_OS=$(echo "$VM_INFO" | grep "^ostype=" | cut -d'"' -f2)
  VM_CURRENT_STATE=$(echo "$VM_INFO" | grep "^VMState=" | cut -d'"' -f2)

  # Preparar VM
  local st="$VM_CURRENT_STATE"
  if [ "$st" != "poweroff" ]; then
    clear
    case "$st" in
      running) echo -e "${YELLOW}[*] La VM está encendida. Apagándola...${NC}"
               "$VBOX" controlvm "$VM_NAME" poweroff 2>/dev/null; sleep 3 ;;
      saved)   echo -e "${YELLOW}[*] La VM está guardada. Descartando estado...${NC}"
               "$VBOX" discardstate "$VM_NAME" 2>/dev/null; sleep 2 ;;
      paused)  echo -e "${YELLOW}[*] La VM está pausada. Apagándola...${NC}"
               "$VBOX" controlvm "$VM_NAME" poweroff 2>/dev/null; sleep 3 ;;
      *)       echo -e "${YELLOW}[*] Estado: $st. Preparando VM...${NC}"
               "$VBOX" controlvm "$VM_NAME" poweroff 2>/dev/null || true
               "$VBOX" discardstate "$VM_NAME" 2>/dev/null || true; sleep 2 ;;
    esac
    echo -e "${GREEN}[OK] VM lista.${NC}"
  fi
}

# =============================================================================
# PASO 2: Fabricante
# =============================================================================
step_manufacturer() {
  local items=()
  for key in $(jq -r '.manufacturers | keys[]' "$DB"); do
    local label=$(jq -r ".manufacturers[\"$key\"].label" "$DB")
    items+=("$key" "$label")
  done

  MFG_CHOICE=$(dl_menu "Paso 2/8 - Perfil de hardware" \
    "VM: $VM_NAME ($VM_CURRENT_OS)\nRAM: ${VM_CURRENT_RAM}MB | CPUs: $VM_CURRENT_CPUS\nMac: $MAC_TYPE\n\nElige el equipo que quieres simular:" \
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

  CPU_CHOICE=$(dl_menu "Paso 3/8 - Procesador" \
    "CPU que aparecerá en el sistema.\nTu Mac es $MAC_TYPE." \
    "${items[@]}")

  CPU_LABEL=$(jq -r ".cpus[\"$CPU_CHOICE\"].label" "$DB")
  CPU_BRAND=$(jq -r ".cpus[\"$CPU_CHOICE\"].brand" "$DB")
}

# =============================================================================
# PASO 4: Recursos
# =============================================================================
step_resources() {
  local host_ram=$(get_host_ram_mb)
  local host_cores=$(get_host_cores)

  # RAM
  local ram_items=()
  for i in $(jq -r '.ram_options[] | .value' "$DB"); do
    local label=$(jq -r ".ram_options[] | select(.value==$i) | .label" "$DB")
    local current=""
    [ "$i" = "$VM_CURRENT_RAM" ] && current=" (actual)"
    ram_items+=("$i" "${label}${current}")
  done

  VM_RAM=$(dl_menu "Paso 4a/8 - RAM simulada" \
    "RAM actual de la VM: ${VM_CURRENT_RAM}MB\nRAM del Mac: ${host_ram}MB ($MAC_TYPE)" \
    "${ram_items[@]}")

  # Cores
  local core_items=()
  for i in $(jq -r '.cpu_cores_vm[] | .value' "$DB"); do
    local label=$(jq -r ".cpu_cores_vm[] | select(.value==$i) | .label" "$DB")
    local current=""
    [ "$i" = "$VM_CURRENT_CPUS" ] && current=" (actual)"
    core_items+=("$i" "${label}${current}")
  done

  VM_CPUS=$(dl_menu "Paso 4b/8 - Cores simulados" \
    "Cores actuales: $VM_CURRENT_CPUS\nCores del Mac: $host_cores ($MAC_TYPE)" \
    "${core_items[@]}")
}

# =============================================================================
# PASO 5: Disco, GPU, Red
# =============================================================================
step_peripherals() {
  # Disco
  local disk_items=()
  for key in $(jq -r '.disks | keys[]' "$DB"); do
    local label=$(jq -r ".disks[\"$key\"].label" "$DB")
    disk_items+=("$key" "$label")
  done

  DISK_CHOICE=$(dl_menu "Paso 5a/8 - Disco duro" \
    "Disco que aparecerá en el sistema:" \
    "${disk_items[@]}")

  DISK_MODEL=$(jq -r ".disks[\"$DISK_CHOICE\"].model" "$DB")
  DISK_FW=$(jq -r ".disks[\"$DISK_CHOICE\"].firmware" "$DB")
  DISK_SERIAL=$(gen_serial "$(jq -r ".disks[\"$DISK_CHOICE\"].serial_prefix" "$DB")" 6)

  # GPU
  local gpu_items=()
  for key in $(jq -r '.gpus | keys[]' "$DB"); do
    local label=$(jq -r ".gpus[\"$key\"].label" "$DB")
    gpu_items+=("$key" "$label")
  done

  GPU_CHOICE=$(dl_menu "Paso 5b/8 - Tarjeta gráfica" \
    "GPU que aparecerá en el sistema:" \
    "${gpu_items[@]}")

  GPU_PCI_NAME=$(jq -r ".gpus[\"$GPU_CHOICE\"].pci_name" "$DB")
  GPU_LABEL=$(jq -r ".gpus[\"$GPU_CHOICE\"].label" "$DB")

  # Red
  local nic_items=()
  for key in $(jq -r '.nics | keys[]' "$DB"); do
    local label=$(jq -r ".nics[\"$key\"].label" "$DB")
    nic_items+=("$key" "$label")
  done

  NIC_CHOICE=$(dl_menu "Paso 5c/8 - Tarjeta de red" \
    "Adaptador de red y prefijo MAC:" \
    "${nic_items[@]}")

  NIC_MAC_PREFIX=$(jq -r ".nics[\"$NIC_CHOICE\"].mac_prefix" "$DB")
  NIC_PCI_NAME=$(jq -r ".nics[\"$NIC_CHOICE\"].pci_name" "$DB")

  # Generador MAC
  local mac_suffix=$(gen_mac_suffix)
  local auto_mac="${NIC_MAC_PREFIX}:${mac_suffix}"

  local mac_choice=$(dl_menu "Generador de MAC" \
    "Prefijo: $NIC_MAC_PREFIX\nMAC generada: $auto_mac" \
    "auto"   "Usar MAC generada automáticamente ($auto_mac)" \
    "manual" "Escribir una MAC personalizada" \
    "random" "Generar otra MAC aleatoria con el mismo prefijo")

  case "$mac_choice" in
    auto)   NIC_MAC="$auto_mac" ;;
    manual) NIC_MAC=$(dl_input "MAC personalizada" "Escribe la MAC (formato XX:XX:XX:XX:XX:XX):" "$auto_mac") ;;
    random)
      while true; do
        NIC_MAC="${NIC_MAC_PREFIX}:$(gen_mac_suffix)"
        dl_yesno "MAC generada" "MAC: $NIC_MAC\n\n¿Usar esta MAC?" && break
      done
      ;;
  esac
  NIC_MAC_NOCOLON=$(echo "$NIC_MAC" | tr -d ':')
}

# =============================================================================
# PASO 6: Chipset
# =============================================================================
step_chipset() {
  local items=()
  for key in $(jq -r '.lspci_templates | keys[]' "$DB"); do
    local desc=""
    case "$key" in
      intel_12th_gen)   desc="Intel 12th Gen (Alder Lake) - 2022-2023" ;;
      intel_13th_gen)   desc="Intel 13th Gen (Raptor Lake) - 2023-2024" ;;
      intel_14th_gen)   desc="Intel 14th Gen (Raptor Lake-S) - 2024" ;;
      intel_meteor_lake) desc="Intel Meteor Lake (Core Ultra) - 2024" ;;
      intel_arrow_lake) desc="Intel Arrow Lake (Core Ultra 2) - 2025" ;;
      amd_zen4)         desc="AMD Zen 4 (Raphael/Phoenix) - 2023-2024" ;;
      amd_zen5)         desc="AMD Zen 5 (Granite Ridge) - 2024-2025" ;;
      apple_intel)      desc="Apple Intel (Coffee Lake) - MacBook 2019-2020" ;;
      apple_silicon)    desc="Apple Silicon (M1/M2/M3/M4) - 2020+" ;;
      *)                desc="$key" ;;
    esac
    items+=("$key" "$desc")
  done

  CHIPSET_CHOICE=$(dl_menu "Paso 6/8 - Chipset PCI" \
    "Plantilla de chipset.\nTu Mac es $MAC_TYPE." \
    "${items[@]}")
}

# =============================================================================
# PASO 7: USB
# =============================================================================
step_usb_devices() {
  clear
  echo -e "${YELLOW}--- Paso 7/8 - Periféricos (audio, vídeo, USB) ---${NC}"
  echo ""

  # En Mac, la cámara FaceTime y el micro son internos (no USB).
  # VirtualBox los pasa a la VM con audio-in/audio-out, no con filtros USB.
  echo -e "${CYAN}  Periféricos internos del Mac:${NC}"
  echo -e "  ${GREEN}[MIC] Micrófono integrado${NC} --> se activa con audio-in"
  echo -e "  ${GREEN}[SPK] Altavoces integrados${NC} --> se activa con audio-out"
  echo -e "  ${YELLOW}[CAM] Cámara FaceTime${NC}     --> no se puede pasar (no es USB)"
  echo ""
  echo -e "  La cámara interna del Mac no es USB, VirtualBox no puede"
  echo -e "  redirigirla. Software como OBS Virtual Camera puede ser"
  echo -e "  detectado por herramientas de análisis. Si necesitas cámara"
  echo -e "  en la VM, conecta una webcam USB externa (Logitech, etc.)."
  echo ""

  # Audio in/out se activa siempre
  ENABLE_AUDIO_IO=true

  # Buscar dispositivos USB externos (si hay conectados)
  echo -e "${CYAN}  Buscando dispositivos USB externos...${NC}"
  echo ""

  local usb_list=$("$VBOX" list usbhost 2>/dev/null)
  local devices=()
  local usb_items=()
  local idx=0
  local current_vid="" current_pid="" current_mfg="" current_prod=""

  while IFS= read -r line; do
    case "$line" in
      VendorId:*)   current_vid=$(echo "$line" | grep -oE '0x[0-9a-fA-F]+' | head -1 | sed 's/0x//') ;;
      ProductId:*)  current_pid=$(echo "$line" | grep -oE '0x[0-9a-fA-F]+' | head -1 | sed 's/0x//') ;;
      Manufacturer:*) current_mfg=$(echo "$line" | sed 's/.*Manufacturer:\s*//') ;;
      Product:*)    current_prod=$(echo "$line" | sed 's/.*Product:\s*//') ;;
      "")
        if [ -n "$current_prod" ] && [ -n "$current_vid" ]; then
          local prod_lower=$(echo "$current_prod $current_mfg" | tr '[:upper:]' '[:lower:]')
          local category="otro"

          if echo "$prod_lower" | grep -qE "cam|video|webcam|insta360|brio|facetime"; then
            category="camara"
          elif echo "$prod_lower" | grep -qE "mic|yeti|scarlett|focusrite|rode|shure|blue|elgato|hyperx|samson"; then
            category="micro"
          elif echo "$prod_lower" | grep -qE "speaker|audio|headset|jabra|sonos|bose|jbl|dac|interface"; then
            category="audio"
          elif echo "$prod_lower" | grep -qE "hub|root|bluetooth|receiver|keyboard|mouse|trackpad|apple internal"; then
            current_vid="" current_pid="" current_mfg="" current_prod=""
            continue
          fi

          if [ "$category" != "otro" ]; then
            local icon=""
            case "$category" in
              camara) icon="[CAM]" ;;
              micro)  icon="[MIC]" ;;
              audio)  icon="[AUD]" ;;
            esac

            usb_items+=("$idx" "$icon $current_mfg $current_prod" "on")
            devices+=("$current_vid|$current_pid|$current_mfg|$current_prod")
            echo -e "  ${GREEN}$icon $current_mfg $current_prod (USB externo)${NC}"
            idx=$((idx + 1))
          fi
        fi
        current_vid="" current_pid="" current_mfg="" current_prod=""
        ;;
    esac
  done <<< "$usb_list"

  USB_FILTERS=()

  if [ $idx -eq 0 ]; then
    echo -e "  ${YELLOW}No se detectaron dispositivos USB externos de audio/vídeo.${NC}"
    echo -e "  El micrófono y altavoces internos se activarán automáticamente."
    echo ""
    read -p "  Pulsa Enter para continuar..."
    return
  fi

  echo ""
  local selected=$(dl_checklist "Dispositivos USB externos" \
    "Dispositivos USB detectados.\nEl micro y altavoces internos se activan aparte.\nSelecciona los USB que quieres conectar:" \
    "${usb_items[@]}")

  for sel in $selected; do
    sel=$(echo "$sel" | tr -d '"')
    USB_FILTERS+=("${devices[$sel]}")
  done
}

# =============================================================================
# PASO 8: Red
# =============================================================================
step_network_mode() {
  local items=(
    "bridged"  "Puente - IP en tu red local (acceso remoto)"
    "nat"      "NAT - IP privada, solo sale a internet"
    "keep"     "No cambiar - Mantener configuración actual"
  )

  NET_MODE=$(dl_menu "Paso 8/8 - Modo de red" \
    "¿Cómo quieres conectar la VM a la red?" \
    "${items[@]}")

  if [ "$NET_MODE" = "bridged" ]; then
    # Listar interfaces de red del Mac
    local ifaces=()
    for iface in $(ifconfig -l 2>/dev/null); do
      case "$iface" in
        lo*|gif*|stf*|awdl*|llw*|utun*|bridge*) continue ;;
      esac
      local ip=$(ifconfig "$iface" 2>/dev/null | grep "inet " | awk '{print $2}' | head -1)
      local status="sin IP"
      [ -n "$ip" ] && status="$ip"
      ifaces+=("$iface" "$status")
    done

    BRIDGE_IFACE=$(dl_menu "Interfaz de red" \
      "Interfaz del Mac para el puente:" "${ifaces[@]}")
  fi
}

# =============================================================================
# RESUMEN
# =============================================================================
show_summary() {
  local usb_count=${#USB_FILTERS[@]}

  local summary="VM: $VM_NAME
SO: $VM_CURRENT_OS
Mac: $MAC_TYPE

Equipo simulado: $MFG_LABEL
CPU: $CPU_LABEL
RAM: ${VM_CURRENT_RAM}MB --> ${VM_RAM}MB ($((VM_RAM/1024))GB)
CPUs: $VM_CURRENT_CPUS --> $VM_CPUS
Disco: $DISK_MODEL
GPU: $GPU_LABEL
MAC: $NIC_MAC
Chipset: $CHIPSET_CHOICE
Red: $NET_MODE
USB: $usb_count dispositivos"

  dl_yesno "Resumen - Aplicar cambios?" "$summary" || exit 0
}

# =============================================================================
# BACKUP
# =============================================================================
backup_vm() {
  mkdir -p "$BACKUP_DIR"
  local backup_file="$BACKUP_DIR/${VM_NAME}.backup.json"

  if [ -f "$backup_file" ]; then
    echo -e "${CYAN}[*] Backup de '$VM_NAME' ya existe (configuración original conservada).${NC}"
    return
  fi

  echo -e "${YELLOW}[*] Guardando backup original de '$VM_NAME'...${NC}"

  local info=$("$VBOX" showvminfo "$VM_NAME" --machinereadable 2>/dev/null)
  local memory=$(echo "$info" | grep "^memory=" | cut -d'=' -f2)
  local cpus=$(echo "$info" | grep "^cpus=" | cut -d'=' -f2)
  local mac=$(echo "$info" | grep "^macaddress1=" | cut -d'"' -f2)
  local nic=$(echo "$info" | grep "^nic1=" | cut -d'"' -f2)
  local vram=$(echo "$info" | grep "^vram=" | cut -d'=' -f2)

  local extradata="{"
  local first=true
  while IFS= read -r line; do
    if echo "$line" | grep -q "^Key:"; then
      local key=$(echo "$line" | sed 's/Key: \(.*\), Value:.*/\1/')
      local val=$(echo "$line" | sed 's/.*Value: //' | sed 's/"/\\"/g')
      if [ "$first" = true ]; then first=false; else extradata+=","; fi
      extradata+="\"$key\":\"$val\""
    fi
  done < <("$VBOX" getextradata "$VM_NAME" enumerate 2>/dev/null)
  extradata+="}"

  cat > "$backup_file" << BKEOF
{
  "vm_name": "$VM_NAME",
  "date": "$(date '+%Y-%m-%d %H:%M:%S')",
  "mac_type": "$MAC_TYPE",
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

  echo -e "${GREEN}[OK] Backup guardado.${NC}"
}

# =============================================================================
# RESTORE
# =============================================================================
restore_vm() {
  if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR"/*.backup.json 2>/dev/null)" ]; then
    dl_msg "Sin backups" "No hay backups disponibles."
    return
  fi

  local items=()
  for file in "$BACKUP_DIR"/*.backup.json; do
    local name=$(jq -r '.vm_name' "$file")
    local date=$(jq -r '.date' "$file")
    local mac_type=$(jq -r '.mac_type // "desconocido"' "$file")
    local ram=$(jq -r '.config.memory' "$file")
    items+=("$file" "$name ($mac_type) - $date - ${ram}MB")
  done

  local selected=$(dl_menu "Restaurar VM" "Backups disponibles:" "${items[@]}")

  local vm_name=$(jq -r '.vm_name' "$selected")

  if ! "$VBOX" showvminfo "$vm_name" &>/dev/null; then
    dl_msg "Error" "La VM '$vm_name' ya no existe."
    return
  fi

  clear
  echo -e "${YELLOW}Restaurando '$vm_name'...${NC}"

  # Preparar VM
  "$VBOX" controlvm "$vm_name" poweroff 2>/dev/null || true
  "$VBOX" discardstate "$vm_name" 2>/dev/null || true
  sleep 2

  # Restaurar config
  local mem=$(jq -r '.config.memory' "$selected")
  local cpu=$(jq -r '.config.cpus' "$selected")
  local vr=$(jq -r '.config.vram' "$selected")
  local ma=$(jq -r '.config.macaddress1' "$selected")
  "$VBOX" modifyvm "$vm_name" --memory "$mem" --cpus "$cpu" --vram "$vr" 2>/dev/null || true
  [ -n "$ma" ] && [ "$ma" != "null" ] && "$VBOX" modifyvm "$vm_name" --macaddress1 "$ma" 2>/dev/null || true

  # Borrar extradata de camuflaje
  while IFS= read -r line; do
    if echo "$line" | grep -q "^Key: VBoxInternal/"; then
      local key=$(echo "$line" | sed 's/Key: \(VBoxInternal\/[^,]*\).*/\1/')
      "$VBOX" setextradata "$vm_name" "$key" 2>/dev/null || true
    fi
  done < <("$VBOX" getextradata "$vm_name" enumerate 2>/dev/null)

  # Restaurar extradata original
  for key in $(jq -r '.extradata | keys[]' "$selected"); do
    local val=$(jq -r ".extradata[\"$key\"]" "$selected")
    [ -n "$val" ] && [ "$val" != "null" ] && "$VBOX" setextradata "$vm_name" "$key" "$val" 2>/dev/null || true
  done

  echo -e "${GREEN}[OK] '$vm_name' restaurada.${NC}"
  read -p "Pulsa Enter para continuar..."
}

# =============================================================================
# APLICAR CAMBIOS
# =============================================================================
apply_changes() {
  clear
  echo ""
  echo -e "${BOLD}============================================${NC}"
  echo -e "${BOLD}  Aplicando camuflaje a '$VM_NAME'${NC}"
  echo -e "${BOLD}  Mac: $MAC_TYPE${NC}"
  echo -e "${BOLD}============================================${NC}"
  echo ""

  # Recursos
  echo -e "${YELLOW}[  5%] Ajustando RAM y CPUs...${NC}"
  "$VBOX" modifyvm "$VM_NAME" \
    --memory "$VM_RAM" --cpus "$VM_CPUS" --vram 128 \
    --graphicscontroller vmsvga --accelerate3d on \
    --paravirt-provider none --cpuid-portability-level 0 2>/dev/null || true

  # Red
  echo -e "${YELLOW}[ 10%] Configurando red...${NC}"
  if [ "$NET_MODE" = "bridged" ]; then
    "$VBOX" modifyvm "$VM_NAME" --nic1 bridged --bridgeadapter1 "$BRIDGE_IFACE" 2>/dev/null || true
  elif [ "$NET_MODE" = "nat" ]; then
    "$VBOX" modifyvm "$VM_NAME" --nic1 nat 2>/dev/null || true
  fi
  [ "$NET_MODE" != "keep" ] && "$VBOX" modifyvm "$VM_NAME" --macaddress1 "$NIC_MAC_NOCOLON" 2>/dev/null || true

  # VRDE
  echo -e "${YELLOW}[ 15%] Escritorio remoto...${NC}"
  "$VBOX" modifyvm "$VM_NAME" --vrde on --vrde-port 3389 --vrde-auth-type null 2>/dev/null || true
  "$VBOX" modifyvm "$VM_NAME" --vrde-property "Security/Method=Negotiate" 2>/dev/null || true

  # VMMDev
  echo -e "${YELLOW}[ 20%] Ocultando VirtualBox...${NC}"
  "$VBOX" setextradata "$VM_NAME" "VBoxInternal/Devices/VMMDev/0/Config/GetHostTimeDisabled" "1"

  # Detectar firmware
  local fw=$("$VBOX" showvminfo "$VM_NAME" --machinereadable 2>/dev/null | grep "^firmware=" | cut -d'"' -f2)
  local P="VBoxInternal/Devices/pcbios/0/Config"
  if echo "$fw" | grep -qi "efi"; then
    P="VBoxInternal/Devices/efi/0/Config"
  fi

  # DMI
  echo -e "${YELLOW}[ 30%] DMI: Sistema...${NC}"
  local mfg=".manufacturers[\"$MFG_CHOICE\"]"
  local sys_serial=$(gen_serial "PF" 6)

  SYS_VENDOR=$(jq -r "$mfg.system.vendor" "$DB")
  SYS_PRODUCT=$(jq -r "$mfg.system.product" "$DB")

  "$VBOX" setextradata "$VM_NAME" "$P/DmiSystemVendor"  "$SYS_VENDOR"
  "$VBOX" setextradata "$VM_NAME" "$P/DmiSystemProduct" "$SYS_PRODUCT"
  "$VBOX" setextradata "$VM_NAME" "$P/DmiSystemVersion" "$(jq -r "$mfg.system.version" "$DB")"
  "$VBOX" setextradata "$VM_NAME" "$P/DmiSystemSKU"     "$(jq -r "$mfg.system.sku" "$DB")"
  "$VBOX" setextradata "$VM_NAME" "$P/DmiSystemFamily"  "$(jq -r "$mfg.system.family" "$DB")"
  "$VBOX" setextradata "$VM_NAME" "$P/DmiSystemSerial"  "$sys_serial"
  "$VBOX" setextradata "$VM_NAME" "$P/DmiSystemUuid"    "$(gen_uuid)"

  echo -e "${YELLOW}[ 40%] DMI: BIOS...${NC}"
  "$VBOX" setextradata "$VM_NAME" "$P/DmiBIOSVendor"        "$(jq -r "$mfg.bios.vendor" "$DB")"
  "$VBOX" setextradata "$VM_NAME" "$P/DmiBIOSVersion"       "$(jq -r "$mfg.bios.version" "$DB")"
  "$VBOX" setextradata "$VM_NAME" "$P/DmiBIOSReleaseDate"   "$(jq -r "$mfg.bios.date" "$DB")"
  "$VBOX" setextradata "$VM_NAME" "$P/DmiBIOSReleaseMajor"  "$(jq -r "$mfg.bios.major" "$DB")"
  "$VBOX" setextradata "$VM_NAME" "$P/DmiBIOSReleaseMinor"  "$(jq -r "$mfg.bios.minor" "$DB")"
  "$VBOX" setextradata "$VM_NAME" "$P/DmiBIOSFirmwareMajor" "$(jq -r "$mfg.bios.firmware_major" "$DB")"
  "$VBOX" setextradata "$VM_NAME" "$P/DmiBIOSFirmwareMinor" "$(jq -r "$mfg.bios.firmware_minor" "$DB")"

  echo -e "${YELLOW}[ 50%] DMI: Placa base...${NC}"
  "$VBOX" setextradata "$VM_NAME" "$P/DmiBoardVendor"     "$(jq -r "$mfg.board.vendor" "$DB")"
  "$VBOX" setextradata "$VM_NAME" "$P/DmiBoardProduct"    "$(jq -r "$mfg.board.product" "$DB")"
  "$VBOX" setextradata "$VM_NAME" "$P/DmiBoardVersion"    "$(jq -r "$mfg.board.version" "$DB")"
  "$VBOX" setextradata "$VM_NAME" "$P/DmiBoardSerial"     "$(gen_serial 'L1HF' 7)"
  "$VBOX" setextradata "$VM_NAME" "$P/DmiBoardAssetTag"   "Not Available"
  "$VBOX" setextradata "$VM_NAME" "$P/DmiBoardLocInChass" "Not Available"

  echo -e "${YELLOW}[ 55%] DMI: Chasis...${NC}"
  "$VBOX" setextradata "$VM_NAME" "$P/DmiChassisVendor"   "$(jq -r "$mfg.chassis.vendor" "$DB")"
  "$VBOX" setextradata "$VM_NAME" "$P/DmiChassisVersion"  "$(jq -r "$mfg.chassis.version" "$DB")"
  "$VBOX" setextradata "$VM_NAME" "$P/DmiChassisSerial"   "$sys_serial"
  "$VBOX" setextradata "$VM_NAME" "$P/DmiChassisAssetTag" "No Asset Information"
  "$VBOX" setextradata "$VM_NAME" "$P/DmiChassisType"     "$(jq -r "$mfg.chassis.type" "$DB")"

  echo -e "${YELLOW}[ 60%] ACPI...${NC}"
  "$VBOX" setextradata "$VM_NAME" "VBoxInternal/Devices/acpi/0/Config/AcpiOemId"     "$(jq -r "$mfg.acpi.oem_id" "$DB")"
  "$VBOX" setextradata "$VM_NAME" "VBoxInternal/Devices/acpi/0/Config/AcpiCreatorId"  "$(jq -r "$mfg.acpi.creator_id" "$DB")"
  "$VBOX" setextradata "$VM_NAME" "VBoxInternal/Devices/acpi/0/Config/AcpiCreatorRev" "$(jq -r "$mfg.acpi.creator_rev" "$DB")"

  echo -e "${YELLOW}[ 70%] Disco...${NC}"
  "$VBOX" setextradata "$VM_NAME" "VBoxInternal/Devices/ahci/0/Config/Port0/SerialNumber"     "$DISK_SERIAL"
  "$VBOX" setextradata "$VM_NAME" "VBoxInternal/Devices/ahci/0/Config/Port0/FirmwareRevision"  "$DISK_FW"
  "$VBOX" setextradata "$VM_NAME" "VBoxInternal/Devices/ahci/0/Config/Port0/ModelNumber"       "$DISK_MODEL"

  "$VBOX" setextradata "$VM_NAME" "VBoxInternal/Devices/ahci/0/Config/Port1/ModelNumber"       "HL-DT-ST DVDRAM GU90N"
  "$VBOX" setextradata "$VM_NAME" "VBoxInternal/Devices/ahci/0/Config/Port1/SerialNumber"      "$(gen_serial 'K8OD' 6)"
  "$VBOX" setextradata "$VM_NAME" "VBoxInternal/Devices/ahci/0/Config/Port1/FirmwareRevision"  "A101"

  # USB
  # Audio integrado del Mac (micro + altavoces internos)
  echo -e "${YELLOW}[ 75%] Audio del Mac (micro y altavoces integrados)...${NC}"
  if [ "$ENABLE_AUDIO_IO" = true ]; then
    "$VBOX" modifyvm "$VM_NAME" --audio-enabled on --audio-driver coreaudio --audio-in on --audio-out on 2>/dev/null || true
    echo -e "    ${GREEN}[+] Micrófono integrado --> audio-in activado${NC}"
    echo -e "    ${GREEN}[+] Altavoces integrados --> audio-out activado${NC}"
  fi

  echo -e "${YELLOW}[ 80%] USB...${NC}"
  "$VBOX" modifyvm "$VM_NAME" --usb-xhci on 2>/dev/null || true

  if [ ${#USB_FILTERS[@]} -gt 0 ]; then
    local filter_idx=0
    for usb_entry in "${USB_FILTERS[@]}"; do
      local vid=$(echo "$usb_entry" | cut -d'|' -f1)
      local pid=$(echo "$usb_entry" | cut -d'|' -f2)
      local mfg_name=$(echo "$usb_entry" | cut -d'|' -f3)
      local prod=$(echo "$usb_entry" | cut -d'|' -f4)

      "$VBOX" usbfilter add "$filter_idx" --target "$VM_NAME" \
        --name "$mfg_name $prod" --vendorid "$vid" --productid "$pid" 2>/dev/null || true

      echo -e "    ${GREEN}[+] $prod${NC}"
      filter_idx=$((filter_idx + 1))
    done
  fi

  echo -e "${GREEN}[100%] Completado${NC}"
  echo ""
  echo -e "${GREEN}============================================${NC}"
  echo -e "${GREEN}  Camuflaje aplicado a '$VM_NAME'${NC}"
  echo -e "${GREEN}  Mac: $MAC_TYPE${NC}"
  echo -e "${GREEN}============================================${NC}"
  echo ""
  echo -e "  Equipo:      $MFG_LABEL"
  echo -e "  CPU:         $CPU_LABEL"
  echo -e "  RAM:         ${VM_CURRENT_RAM}MB --> ${VM_RAM}MB (${BOLD}$((VM_RAM/1024))GB${NC})"
  echo -e "  Disco:       $DISK_MODEL"
  echo -e "  GPU:         $GPU_LABEL"
  echo -e "  MAC:         $NIC_MAC"
  echo ""

  if dl_yesno "Arrancar VM" "¿Arrancar la VM ahora?"; then
    "$VBOX" startvm "$VM_NAME" --type gui 2>/dev/null
    echo -e "${GREEN}[OK] VM arrancada.${NC}"
  fi

  echo ""
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  check_deps

  dl_msg "VM Spoofer - macOS $MAC_TYPE" \
"Bienvenido a VM Spoofer para macOS

Tu Mac es: $MAC_TYPE ($(uname -m))
VirtualBox: $("$VBOX" --version 2>/dev/null)

Este asistente detecta tus máquinas virtuales
y les aplica un perfil de hardware real para
que no sean detectadas como VM.

Pulsa OK para comenzar."

  # Menú principal
  local action=$(dl_menu "Menú principal" \
    "Mac $MAC_TYPE - ¿Qué quieres hacer?" \
    "spoof"   "Camuflar una VM (aplicar perfil de hardware)" \
    "restore" "Restaurar una VM (volver a configuración original)" \
    "exit"    "Salir")

  case "$action" in
    restore) restore_vm; exit 0 ;;
    exit)    exit 0 ;;
  esac

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
