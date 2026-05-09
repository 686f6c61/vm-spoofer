#!/bin/bash
# shellcheck disable=SC2001,SC2034,SC2069,SC2086,SC2155,SC2162,SC2181
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

die() {
  echo -e "${RED}[!] $*${NC}" >&2
  exit 1
}

vbox_run() {
  local output
  if ! output=$("$VBOX" "$@" 2>&1); then
    echo -e "${RED}[!] VBoxManage fallo: $*${NC}" >&2
    [ -n "$output" ] && echo "$output" >&2
    exit 1
  fi
  [ -n "$output" ] && printf '%s\n' "$output"
}

vbox_try() {
  "$VBOX" "$@" >/dev/null 2>&1 || true
}

mr_value() {
  local info="$1" key="$2"
  printf '%s\n' "$info" | awk -F= -v key="$key" '
    $1 == key {
      value = $2
      sub(/^"/, "", value)
      sub(/"$/, "", value)
      print value
      exit
    }'
}

normalize_mac() {
  local mac="${1//[:.-]/}"
  mac=$(printf '%s' "$mac" | tr '[:lower:]' '[:upper:]')
  echo "$mac" | grep -Eq '^[0-9A-F]{12}$' || return 1
  printf '%s' "$mac"
}

format_mac() {
  local mac
  mac=$(normalize_mac "$1") || return 1
  printf '%s:%s:%s:%s:%s:%s' \
    "${mac:0:2}" "${mac:2:2}" "${mac:4:2}" "${mac:6:2}" "${mac:8:2}" "${mac:10:2}"
}

safe_filename() {
  printf '%s' "$1" | sed 's#[/\\:*?"<>|]#_#g'
}

remove_spoofer_usb_filters() {
  local vm_name="$1" info idx remove_idx
  info=$("$VBOX" showvminfo "$vm_name" --machinereadable 2>/dev/null || true)
  while IFS= read -r idx; do
    [ -z "$idx" ] && continue
    remove_idx=$((idx - 1))
    [ "$remove_idx" -ge 0 ] && vbox_try usbfilter remove "$remove_idx" --target "$vm_name"
  done < <(echo "$info" | sed -n 's/^USBFilterName\([0-9]\+\)="VM Spoofer -.*/\1/p' | sort -rn)
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
  if ! NIC_MAC_NOCOLON=$(normalize_mac "$NIC_MAC"); then
    dl_msg "MAC invalida" "La dirección MAC no es válida.\n\nUsa 12 caracteres hexadecimales, con o sin separadores.\nEjemplo: $auto_mac"
    exit 1
  fi
  NIC_MAC=$(format_mac "$NIC_MAC_NOCOLON")
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

            usb_items+=("$idx" "$icon $current_mfg $current_prod" "off")
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
    "Dispositivos USB detectados.\nEl micro y altavoces internos se activan aparte.\nMarca solo una webcam o dispositivo externo que quieras capturar." \
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

  REMOTE_MODE=$(dl_menu "Acceso remoto de VirtualBox" \
    "VRDE/RDP da acceso a la consola de la VM desde el Mac.\nPor seguridad queda desactivado salvo que lo necesites." \
    "off"   "Desactivado (recomendado)" \
    "local" "Activar solo en 127.0.0.1 para acceso local")

  VRDE_PORT="3389"
  VRDE_ADDRESS="127.0.0.1"
  if [ "$REMOTE_MODE" = "local" ]; then
    VRDE_PORT=$(dl_input "Puerto VRDE" "Puerto local para conectar por RDP:" "$VRDE_PORT")
    if ! echo "$VRDE_PORT" | grep -Eq '^[0-9]{2,5}$' || [ "$VRDE_PORT" -lt 1 ] || [ "$VRDE_PORT" -gt 65535 ]; then
      dl_msg "Puerto inválido" "El puerto VRDE debe ser un número entre 1 y 65535."
      exit 1
    fi
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
Acceso remoto: $REMOTE_MODE
USB: $usb_count dispositivos"

  dl_yesno "Resumen - Aplicar cambios?" "$summary" || exit 0
}

# =============================================================================
# BACKUP
# =============================================================================
backup_vm() {
  mkdir -p "$BACKUP_DIR"
  local backup_name
  backup_name=$(safe_filename "$VM_NAME")
  local backup_file="$BACKUP_DIR/${backup_name}.backup.json"

  if [ -f "$backup_file" ]; then
    echo -e "${CYAN}[*] Backup de '$VM_NAME' ya existe (configuración original conservada).${NC}"
    return
  fi

  echo -e "${YELLOW}[*] Guardando backup original de '$VM_NAME'...${NC}"

  local info=$("$VBOX" showvminfo "$VM_NAME" --machinereadable 2>/dev/null)
  local memory=$(mr_value "$info" "memory")
  local cpus=$(mr_value "$info" "cpus")
  local mac=$(mr_value "$info" "macaddress1")
  local nic=$(mr_value "$info" "nic1")
  local bridgeadapter=$(mr_value "$info" "bridgeadapter1")
  local vram=$(mr_value "$info" "vram")
  local graphicscontroller=$(mr_value "$info" "graphicscontroller")
  local accelerate3d=$(mr_value "$info" "accelerate3d")
  local paravirtprovider=$(mr_value "$info" "paravirtprovider")
  local audiodriver=$(mr_value "$info" "audio")
  local audioout=$(mr_value "$info" "audio_out")
  local audioin=$(mr_value "$info" "audio_in")
  local clipboard=$(mr_value "$info" "clipboard")
  local draganddrop=$(mr_value "$info" "draganddrop")
  local xhci=$(mr_value "$info" "xhci")
  local vrde=$(mr_value "$info" "vrde")
  local vrdeport=$(mr_value "$info" "vrdeport")
  local vrdeaddress=$(mr_value "$info" "vrdeaddress")
  local vrdeauthtype=$(mr_value "$info" "vrdeauthtype")
  local cfg_file=$(mr_value "$info" "CfgFile")
  local cfg_backup=""

  if [ -n "$cfg_file" ] && [ -f "$cfg_file" ]; then
    cfg_backup="$BACKUP_DIR/${backup_name}.original.vbox"
    cp -p "$cfg_file" "$cfg_backup" 2>/dev/null || cfg_backup=""
  fi

  local extradata="{}"
  while IFS= read -r line; do
    if echo "$line" | grep -q "^Key:"; then
      local key=$(echo "$line" | sed 's/Key: \(.*\), Value:.*/\1/')
      local val=$(echo "$line" | sed 's/.*Value: //')
      extradata=$(jq -c --arg key "$key" --arg val "$val" '. + {($key): $val}' <<< "$extradata")
    fi
  done < <("$VBOX" getextradata "$VM_NAME" enumerate 2>/dev/null)

  jq -n \
    --arg vm_name "$VM_NAME" \
    --arg date "$(date '+%Y-%m-%d %H:%M:%S')" \
    --arg mac_type "$MAC_TYPE" \
    --arg cfg_file "$cfg_file" \
    --arg cfg_backup "$cfg_backup" \
    --arg memory "$memory" \
    --arg cpus "$cpus" \
    --arg macaddress1 "$mac" \
    --arg nic1 "$nic" \
    --arg bridgeadapter1 "$bridgeadapter" \
    --arg vram "$vram" \
    --arg graphicscontroller "$graphicscontroller" \
    --arg accelerate3d "$accelerate3d" \
    --arg paravirtprovider "$paravirtprovider" \
    --arg audiodriver "$audiodriver" \
    --arg audioout "$audioout" \
    --arg audioin "$audioin" \
    --arg clipboard "$clipboard" \
    --arg draganddrop "$draganddrop" \
    --arg xhci "$xhci" \
    --arg vrde "$vrde" \
    --arg vrdeport "$vrdeport" \
    --arg vrdeaddress "$vrdeaddress" \
    --arg vrdeauthtype "$vrdeauthtype" \
    --argjson extradata "$extradata" \
    '{
      vm_name: $vm_name,
      date: $date,
      mac_type: $mac_type,
      config_file: $cfg_file,
      config_backup: $cfg_backup,
      config: {
        memory: $memory,
        cpus: $cpus,
        macaddress1: $macaddress1,
        nic1: $nic1,
        bridgeadapter1: $bridgeadapter1,
        vram: $vram,
        graphicscontroller: $graphicscontroller,
        accelerate3d: $accelerate3d,
        paravirtprovider: $paravirtprovider,
        audiodriver: $audiodriver,
        audioout: $audioout,
        audioin: $audioin,
        clipboard: $clipboard,
        draganddrop: $draganddrop,
        xhci: $xhci,
        vrde: $vrde,
        vrdeport: $vrdeport,
        vrdeaddress: $vrdeaddress,
        vrdeauthtype: $vrdeauthtype
      },
      extradata: $extradata
    }' > "$backup_file"

  echo -e "${GREEN}[OK] Backup guardado.${NC}"
  [ -n "$cfg_backup" ] && echo -e "${GREEN}[OK] Copia .vbox guardada.${NC}"
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
  local nic=$(jq -r '.config.nic1 // empty' "$selected")
  local bridge=$(jq -r '.config.bridgeadapter1 // empty' "$selected")
  local graphics=$(jq -r '.config.graphicscontroller // empty' "$selected")
  local accel3d=$(jq -r '.config.accelerate3d // empty' "$selected")
  local paravirt=$(jq -r '.config.paravirtprovider // empty' "$selected")
  local audiodriver=$(jq -r '.config.audiodriver // empty' "$selected")
  local audioout=$(jq -r '.config.audioout // empty' "$selected")
  local audioin=$(jq -r '.config.audioin // empty' "$selected")
  local clipboard=$(jq -r '.config.clipboard // empty' "$selected")
  local draganddrop=$(jq -r '.config.draganddrop // empty' "$selected")
  local xhci=$(jq -r '.config.xhci // empty' "$selected")
  local vrde=$(jq -r '.config.vrde // empty' "$selected")
  local vrdeport=$(jq -r '.config.vrdeport // empty' "$selected")
  local vrdeaddress=$(jq -r '.config.vrdeaddress // empty' "$selected")
  local vrdeauthtype=$(jq -r '.config.vrdeauthtype // empty' "$selected")

  vbox_try modifyvm "$vm_name" --memory "$mem" --cpus "$cpu" --vram "$vr"
  [ -n "$ma" ] && [ "$ma" != "null" ] && vbox_try modifyvm "$vm_name" --macaddress1 "$ma"
  [ -n "$nic" ] && [ "$nic" != "null" ] && vbox_try modifyvm "$vm_name" --nic1 "$nic"
  [ "$nic" = "bridged" ] && [ -n "$bridge" ] && [ "$bridge" != "null" ] && vbox_try modifyvm "$vm_name" --bridgeadapter1 "$bridge"
  [ -n "$graphics" ] && [ "$graphics" != "null" ] && vbox_try modifyvm "$vm_name" --graphicscontroller "$graphics"
  [ -n "$accel3d" ] && [ "$accel3d" != "null" ] && vbox_try modifyvm "$vm_name" --accelerate3d "$accel3d"
  [ -n "$paravirt" ] && [ "$paravirt" != "null" ] && vbox_try modifyvm "$vm_name" --paravirt-provider "$paravirt"
  [ -n "$audiodriver" ] && [ "$audiodriver" != "null" ] && vbox_try modifyvm "$vm_name" --audio-driver "$audiodriver"
  [ -n "$audioout" ] && [ "$audioout" != "null" ] && vbox_try modifyvm "$vm_name" --audio-out "$audioout"
  [ -n "$audioin" ] && [ "$audioin" != "null" ] && vbox_try modifyvm "$vm_name" --audio-in "$audioin"
  [ -n "$clipboard" ] && [ "$clipboard" != "null" ] && vbox_try modifyvm "$vm_name" --clipboard-mode "$clipboard"
  [ -n "$draganddrop" ] && [ "$draganddrop" != "null" ] && vbox_try modifyvm "$vm_name" --drag-and-drop "$draganddrop"
  [ -n "$xhci" ] && [ "$xhci" != "null" ] && vbox_try modifyvm "$vm_name" --usb-xhci "$xhci"
  [ -n "$vrde" ] && [ "$vrde" != "null" ] && vbox_try modifyvm "$vm_name" --vrde "$vrde"
  [ -n "$vrdeport" ] && [ "$vrdeport" != "null" ] && vbox_try modifyvm "$vm_name" --vrde-port "$vrdeport"
  [ -n "$vrdeaddress" ] && [ "$vrdeaddress" != "null" ] && vbox_try modifyvm "$vm_name" --vrde-address "$vrdeaddress"
  [ -n "$vrdeauthtype" ] && [ "$vrdeauthtype" != "null" ] && vbox_try modifyvm "$vm_name" --vrde-auth-type "$vrdeauthtype"

  remove_spoofer_usb_filters "$vm_name"

  # Borrar extradata de camuflaje
  while IFS= read -r line; do
    if echo "$line" | grep -q "^Key: VBoxInternal/"; then
      local key=$(echo "$line" | sed 's/Key: \(VBoxInternal\/[^,]*\).*/\1/')
      vbox_try setextradata "$vm_name" "$key"
    fi
  done < <("$VBOX" getextradata "$vm_name" enumerate 2>/dev/null)

  # Restaurar extradata original
  for key in $(jq -r '.extradata | keys[]' "$selected"); do
    local val=$(jq -r ".extradata[\"$key\"]" "$selected")
    [ -n "$val" ] && [ "$val" != "null" ] && vbox_try setextradata "$vm_name" "$key" "$val"
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
  vbox_run modifyvm "$VM_NAME" \
    --memory "$VM_RAM" --cpus "$VM_CPUS" --vram 128 \
    --graphicscontroller vmsvga --accelerate3d on \
    --paravirt-provider none --cpuid-portability-level 0 \
    --clipboard-mode bidirectional \
    --drag-and-drop bidirectional >/dev/null

  # Red
  echo -e "${YELLOW}[ 10%] Configurando red...${NC}"
  if [ "$NET_MODE" = "bridged" ]; then
    vbox_run modifyvm "$VM_NAME" --nic1 bridged --bridgeadapter1 "$BRIDGE_IFACE" >/dev/null
  elif [ "$NET_MODE" = "nat" ]; then
    vbox_run modifyvm "$VM_NAME" --nic1 nat >/dev/null
  fi
  [ "$NET_MODE" != "keep" ] && vbox_run modifyvm "$VM_NAME" --macaddress1 "$NIC_MAC_NOCOLON" >/dev/null

  # VRDE
  echo -e "${YELLOW}[ 15%] Acceso remoto seguro...${NC}"
  if [ "$REMOTE_MODE" = "local" ]; then
    vbox_run modifyvm "$VM_NAME" --vrde on --vrde-address "$VRDE_ADDRESS" --vrde-port "$VRDE_PORT" --vrde-auth-type null >/dev/null
    vbox_run modifyvm "$VM_NAME" --vrde-property "Security/Method=Negotiate" >/dev/null
    echo -e "    ${GREEN}[OK] VRDE activo solo en $VRDE_ADDRESS:$VRDE_PORT${NC}"
  else
    vbox_run modifyvm "$VM_NAME" --vrde off >/dev/null
    echo -e "    ${GREEN}[OK] VRDE desactivado${NC}"
  fi

  # VMMDev
  echo -e "${YELLOW}[ 20%] Ocultando VirtualBox...${NC}"
  vbox_run setextradata "$VM_NAME" "VBoxInternal/Devices/VMMDev/0/Config/GetHostTimeDisabled" "1" >/dev/null

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

  vbox_run setextradata "$VM_NAME" "$P/DmiSystemVendor"  "$SYS_VENDOR" >/dev/null
  vbox_run setextradata "$VM_NAME" "$P/DmiSystemProduct" "$SYS_PRODUCT" >/dev/null
  vbox_run setextradata "$VM_NAME" "$P/DmiSystemVersion" "$(jq -r "$mfg.system.version" "$DB")" >/dev/null
  vbox_run setextradata "$VM_NAME" "$P/DmiSystemSKU"     "$(jq -r "$mfg.system.sku" "$DB")" >/dev/null
  vbox_run setextradata "$VM_NAME" "$P/DmiSystemFamily"  "$(jq -r "$mfg.system.family" "$DB")" >/dev/null
  vbox_run setextradata "$VM_NAME" "$P/DmiSystemSerial"  "$sys_serial" >/dev/null
  vbox_run setextradata "$VM_NAME" "$P/DmiSystemUuid"    "$(gen_uuid)" >/dev/null

  echo -e "${YELLOW}[ 40%] DMI: BIOS...${NC}"
  vbox_run setextradata "$VM_NAME" "$P/DmiBIOSVendor"        "$(jq -r "$mfg.bios.vendor" "$DB")" >/dev/null
  vbox_run setextradata "$VM_NAME" "$P/DmiBIOSVersion"       "$(jq -r "$mfg.bios.version" "$DB")" >/dev/null
  vbox_run setextradata "$VM_NAME" "$P/DmiBIOSReleaseDate"   "$(jq -r "$mfg.bios.date" "$DB")" >/dev/null
  vbox_run setextradata "$VM_NAME" "$P/DmiBIOSReleaseMajor"  "$(jq -r "$mfg.bios.major" "$DB")" >/dev/null
  vbox_run setextradata "$VM_NAME" "$P/DmiBIOSReleaseMinor"  "$(jq -r "$mfg.bios.minor" "$DB")" >/dev/null
  vbox_run setextradata "$VM_NAME" "$P/DmiBIOSFirmwareMajor" "$(jq -r "$mfg.bios.firmware_major" "$DB")" >/dev/null
  vbox_run setextradata "$VM_NAME" "$P/DmiBIOSFirmwareMinor" "$(jq -r "$mfg.bios.firmware_minor" "$DB")" >/dev/null

  echo -e "${YELLOW}[ 50%] DMI: Placa base...${NC}"
  vbox_run setextradata "$VM_NAME" "$P/DmiBoardVendor"     "$(jq -r "$mfg.board.vendor" "$DB")" >/dev/null
  vbox_run setextradata "$VM_NAME" "$P/DmiBoardProduct"    "$(jq -r "$mfg.board.product" "$DB")" >/dev/null
  vbox_run setextradata "$VM_NAME" "$P/DmiBoardVersion"    "$(jq -r "$mfg.board.version" "$DB")" >/dev/null
  vbox_run setextradata "$VM_NAME" "$P/DmiBoardSerial"     "$(gen_serial 'L1HF' 7)" >/dev/null
  vbox_run setextradata "$VM_NAME" "$P/DmiBoardAssetTag"   "Not Available" >/dev/null
  vbox_run setextradata "$VM_NAME" "$P/DmiBoardLocInChass" "Not Available" >/dev/null

  echo -e "${YELLOW}[ 55%] DMI: Chasis...${NC}"
  vbox_run setextradata "$VM_NAME" "$P/DmiChassisVendor"   "$(jq -r "$mfg.chassis.vendor" "$DB")" >/dev/null
  vbox_run setextradata "$VM_NAME" "$P/DmiChassisVersion"  "$(jq -r "$mfg.chassis.version" "$DB")" >/dev/null
  vbox_run setextradata "$VM_NAME" "$P/DmiChassisSerial"   "$sys_serial" >/dev/null
  vbox_run setextradata "$VM_NAME" "$P/DmiChassisAssetTag" "No Asset Information" >/dev/null
  vbox_run setextradata "$VM_NAME" "$P/DmiChassisType"     "$(jq -r "$mfg.chassis.type" "$DB")" >/dev/null

  echo -e "${YELLOW}[ 60%] ACPI...${NC}"
  vbox_run setextradata "$VM_NAME" "VBoxInternal/Devices/acpi/0/Config/AcpiOemId"     "$(jq -r "$mfg.acpi.oem_id" "$DB")" >/dev/null
  vbox_run setextradata "$VM_NAME" "VBoxInternal/Devices/acpi/0/Config/AcpiCreatorId"  "$(jq -r "$mfg.acpi.creator_id" "$DB")" >/dev/null
  vbox_run setextradata "$VM_NAME" "VBoxInternal/Devices/acpi/0/Config/AcpiCreatorRev" "$(jq -r "$mfg.acpi.creator_rev" "$DB")" >/dev/null

  echo -e "${YELLOW}[ 70%] Disco...${NC}"
  vbox_run setextradata "$VM_NAME" "VBoxInternal/Devices/ahci/0/Config/Port0/SerialNumber"     "$DISK_SERIAL" >/dev/null
  vbox_run setextradata "$VM_NAME" "VBoxInternal/Devices/ahci/0/Config/Port0/FirmwareRevision"  "$DISK_FW" >/dev/null
  vbox_run setextradata "$VM_NAME" "VBoxInternal/Devices/ahci/0/Config/Port0/ModelNumber"       "$DISK_MODEL" >/dev/null

  vbox_run setextradata "$VM_NAME" "VBoxInternal/Devices/ahci/0/Config/Port1/ModelNumber"       "HL-DT-ST DVDRAM GU90N" >/dev/null
  vbox_run setextradata "$VM_NAME" "VBoxInternal/Devices/ahci/0/Config/Port1/SerialNumber"      "$(gen_serial 'K8OD' 6)" >/dev/null
  vbox_run setextradata "$VM_NAME" "VBoxInternal/Devices/ahci/0/Config/Port1/FirmwareRevision"  "A101" >/dev/null

  # USB
  # Audio integrado del Mac (micro + altavoces internos)
  echo -e "${YELLOW}[ 75%] Audio del Mac (micro y altavoces integrados)...${NC}"
  if [ "$ENABLE_AUDIO_IO" = true ]; then
    vbox_try modifyvm "$VM_NAME" --audio-enabled on --audio-driver coreaudio --audio-in on --audio-out on
    echo -e "    ${GREEN}[+] Micrófono integrado --> audio-in activado${NC}"
    echo -e "    ${GREEN}[+] Altavoces integrados --> audio-out activado${NC}"
  fi

  echo -e "${YELLOW}[ 80%] USB...${NC}"
  vbox_try modifyvm "$VM_NAME" --usb-xhci on

  if [ ${#USB_FILTERS[@]} -gt 0 ]; then
    local filter_idx=0
    for usb_entry in "${USB_FILTERS[@]}"; do
      local vid=$(echo "$usb_entry" | cut -d'|' -f1)
      local pid=$(echo "$usb_entry" | cut -d'|' -f2)
      local mfg_name=$(echo "$usb_entry" | cut -d'|' -f3)
      local prod=$(echo "$usb_entry" | cut -d'|' -f4)

      vbox_try usbfilter add "$filter_idx" --target "$VM_NAME" \
        --name "VM Spoofer - $mfg_name $prod" --vendorid "$vid" --productid "$pid"

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
  echo -e "  VRDE:        $REMOTE_MODE"
  if [ "$REMOTE_MODE" = "local" ]; then
    echo -e "  RDP local:   127.0.0.1:$VRDE_PORT"
  fi
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
