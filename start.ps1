$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host "[!] Node.js no esta instalado." -ForegroundColor Red
    Write-Host "    Descargalo desde https://nodejs.org"
    Read-Host "Pulsa Enter para salir"
    exit 1
}

& node (Join-Path $ScriptDir "launcher.js")
