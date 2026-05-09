#!/usr/bin/env bash
set -euo pipefail

STRICT=0
CLEAN_LOGS=0
YES=0
DRY_RUN=0

usage() {
  cat <<'EOF'
Uso: sudo bash guest-cleanup-linux.sh [opciones]

Opciones:
  --strict       Desactiva servicios, purga paquetes guest y limpia artefactos.
  --clean-logs   Limpia logs que pueden contener trazas antiguas del hipervisor.
  --yes          No pedir confirmacion interactiva.
  --dry-run      Mostrar acciones sin ejecutarlas.
  --help         Mostrar ayuda.

Este script no cambia DMI/SMBIOS ni PCI raw IDs. Solo limpia el sistema invitado.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --strict) STRICT=1; CLEAN_LOGS=1 ;;
    --clean-logs) CLEAN_LOGS=1 ;;
    --yes) YES=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "[!] Opcion desconocida: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

if [ "$(id -u)" -ne 0 ]; then
  echo "[!] Ejecuta como root: sudo bash guest-cleanup-linux.sh --strict" >&2
  exit 1
fi

confirm() {
  [ "$YES" -eq 1 ] && return 0
  echo ""
  echo "Esto puede desinstalar Guest Additions/SPICE/QEMU/VMware tools y limpiar logs."
  echo "Puede afectar portapapeles compartido, carpetas compartidas, auto-resize y agentes guest."
  read -r -p "Continuar? [s/N]: " answer
  case "${answer,,}" in
    s|si|y|yes) return 0 ;;
    *) echo "Cancelado."; exit 0 ;;
  esac
}

run() {
  echo "+ $*"
  [ "$DRY_RUN" -eq 1 ] && return 0
  "$@" || true
}

service_exists() {
  systemctl list-unit-files "$1" >/dev/null 2>&1
}

disable_services() {
  echo "[1/5] Desactivando servicios guest conocidos..."
  local services=(
    vboxadd.service
    vboxadd-service.service
    vboxadd-x11.service
    virtualbox-guest-utils.service
    vboxservice.service
    spice-vdagent.service
    qemu-guest-agent.service
    vmtoolsd.service
    open-vm-tools.service
  )
  if command -v systemctl >/dev/null 2>&1; then
    for svc in "${services[@]}"; do
      if service_exists "$svc"; then
        run systemctl disable --now "$svc"
        run systemctl mask "$svc"
      fi
    done
  fi
}

blacklist_modules() {
  echo "[2/5] Bloqueando modulos guest conocidos..."
  if [ "$DRY_RUN" -eq 0 ]; then
    cat > /etc/modprobe.d/vm-spoofer-guest-cleanup.conf <<'EOF'
blacklist vboxguest
blacklist vboxsf
blacklist vboxvideo
blacklist vmw_vmci
blacklist vmw_vsock_vmci_transport
blacklist vmwgfx
blacklist virtio_balloon
blacklist qxl
install vboxguest /bin/false
install vboxsf /bin/false
install vboxvideo /bin/false
EOF
  else
    echo "+ write /etc/modprobe.d/vm-spoofer-guest-cleanup.conf"
  fi

  if command -v update-initramfs >/dev/null 2>&1; then
    run update-initramfs -u
  elif command -v dracut >/dev/null 2>&1; then
    run dracut -f
  fi
}

installed_dpkg_packages() {
  dpkg-query -W -f='${Package}\n' "$@" 2>/dev/null || true
}

purge_packages() {
  [ "$STRICT" -eq 1 ] || return 0
  echo "[3/5] Eliminando paquetes guest conocidos..."

  local packages=(
    virtualbox-guest-utils
    virtualbox-guest-x11
    virtualbox-guest-dkms
    virtualbox-guest-additions-iso
    spice-vdagent
    qemu-guest-agent
    open-vm-tools
    open-vm-tools-desktop
  )

  if command -v dpkg-query >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
    mapfile -t present < <(installed_dpkg_packages "${packages[@]}")
    if [ "${#present[@]}" -gt 0 ]; then
      run apt-get purge -y "${present[@]}"
      run apt-get autoremove -y
    fi
  elif command -v rpm >/dev/null 2>&1; then
    local present=()
    for pkg in "${packages[@]}"; do
      rpm -q "$pkg" >/dev/null 2>&1 && present+=("$pkg")
    done
    if [ "${#present[@]}" -gt 0 ]; then
      if command -v dnf >/dev/null 2>&1; then
        run dnf remove -y "${present[@]}"
      elif command -v yum >/dev/null 2>&1; then
        run yum remove -y "${present[@]}"
      fi
    fi
  elif command -v pacman >/dev/null 2>&1; then
    local present=()
    for pkg in "${packages[@]}"; do
      pacman -Q "$pkg" >/dev/null 2>&1 && present+=("$pkg")
    done
    [ "${#present[@]}" -gt 0 ] && run pacman -Rns --noconfirm "${present[@]}"
  fi
}

remove_artifacts() {
  [ "$STRICT" -eq 1 ] || return 0
  echo "[4/5] Eliminando artefactos guest conocidos..."
  local paths=(
    /dev/vboxguest
    /dev/vboxuser
    /dev/vmci
    /dev/virtio-ports
    /dev/xen
    /usr/bin/VBoxClient
    /usr/sbin/VBoxService
    /sbin/mount.vboxsf
    /opt/VBoxGuestAdditions-*
    /opt/vmware-tools
    "/Library/Application Support/VirtualBox Guest Additions"
  )
  for item in "${paths[@]}"; do
    # shellcheck disable=SC2086
    run rm -rf $item
  done

  local unit_links=(
    /etc/systemd/system/vboxadd.service
    /etc/systemd/system/vboxadd-service.service
    /etc/systemd/system/vboxadd-x11.service
    /etc/systemd/system/virtualbox-guest-utils.service
    /etc/systemd/system/vboxservice.service
    /etc/systemd/system/spice-vdagent.service
    /etc/systemd/system/qemu-guest-agent.service
    /etc/systemd/system/vmtoolsd.service
    /etc/systemd/system/open-vm-tools.service
    /etc/systemd/system/multi-user.target.wants/virtualbox-guest-utils.service
    /etc/systemd/system/multi-user.target.wants/spice-vdagent.service
    /etc/systemd/system/multi-user.target.wants/qemu-guest-agent.service
    /etc/systemd/system/multi-user.target.wants/vmtoolsd.service
  )
  for unit in "${unit_links[@]}"; do
    [ -e "$unit" ] || [ -L "$unit" ] || continue
    run rm -f "$unit"
  done

  command -v systemctl >/dev/null 2>&1 && run systemctl daemon-reload
}

clean_logs() {
  [ "$CLEAN_LOGS" -eq 1 ] || return 0
  echo "[5/5] Limpiando logs con trazas historicas..."
  if command -v journalctl >/dev/null 2>&1; then
    run journalctl --rotate
    run journalctl --vacuum-time=1s
  fi
  local logs=(
    /var/log/dmesg
    /var/log/kern.log
    /var/log/syslog
    /var/log/messages
    /var/log/boot.log
  )
  for log in "${logs[@]}"; do
    [ -e "$log" ] && run truncate -s 0 "$log"
  done
}

confirm
disable_services
blacklist_modules
purge_packages
remove_artifacts
clean_logs

echo ""
echo "[OK] Limpieza guest completada."
echo "Reinicia la VM y ejecuta: sudo node check.js --advanced"
