#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if ! command -v node >/dev/null 2>&1; then
  echo "[!] Node.js no esta instalado."
  echo "    Instala Node.js y vuelve a ejecutar este launcher."
  echo "    Linux: sudo apt install -y nodejs npm"
  echo "    macOS: brew install node"
  exit 1
fi

exec node "$SCRIPT_DIR/launcher.js"
