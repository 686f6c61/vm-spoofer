#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if ! command -v node >/dev/null 2>&1; then
  echo "[!] Node.js no esta instalado."
  echo "    Instala Node.js con: brew install node"
  read -r -p "Pulsa Enter para salir..."
  exit 1
fi

node "$SCRIPT_DIR/launcher.js"
read -r -p "Pulsa Enter para cerrar..."
