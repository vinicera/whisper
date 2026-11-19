# Sobe o servidor ponte no Windows.
# Uso:  powershell -ExecutionPolicy Bypass -File server\scripts\run_server.ps1
$ErrorActionPreference = "Stop"
$server = Split-Path -Parent $PSScriptRoot
Set-Location $server

if (-not (Test-Path ".venv")) {
    python -m venv .venv
    .\.venv\Scripts\python -m pip install -e ".[dev]"
}
if (-not (Test-Path ".env")) {
    Copy-Item ".env.example" ".env"
    Write-Host "Criei server\.env a partir do exemplo. Preencha GEMINI_API_KEY e BRIDGE_TOKEN e rode de novo."
    exit 1
}
.\.venv\Scripts\python -m app
