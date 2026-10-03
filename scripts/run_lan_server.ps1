# Windows PowerShell version of run_lan_server.sh - runs the DCOV backend so
# Android phones on the same Wi-Fi can reach it.
#   powershell -ExecutionPolicy Bypass -File scripts\run_lan_server.ps1
param([int]$Port = 8000)
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
$Root = (Get-Location).Path

if (-not (Test-Path ".venv")) {
  Write-Host "== creating virtual environment"
  py -3 -m venv .venv
  .\.venv\Scripts\python -m pip install -q --upgrade pip
  .\.venv\Scripts\python -m pip install -q -r backend\requirements.txt
}
$Py = Join-Path $Root ".venv\Scripts\python.exe"

$EnvFile = "backend\.env"
if (-not (Test-Path $EnvFile)) {
  $secret = & $Py -c "import secrets;print(secrets.token_urlsafe(48))"
  $db = ($Root -replace '\\','/') + "/data/dcov.sqlite"
  @(
    "DCOV_SECRET_KEY=$secret",
    "DCOV_DATABASE_URL=sqlite+aiosqlite:///$db",
    "DCOV_ENVIRONMENT=production",
    "DCOV_FORCE_HTTPS=false",
    "DCOV_PASSWORD_SCHEME=pbkdf2_sha256"
  ) | Set-Content -Encoding ascii $EnvFile
  Write-Host "== wrote $EnvFile (keep it private)"
}
Get-Content $EnvFile | ForEach-Object {
  if ($_ -match '^\s*([^#=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($matches[1], $matches[2]) }
}

$LanIp = (Get-NetIPAddress -AddressFamily IPv4 |
  Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" -and $_.PrefixOrigin -ne "WellKnown" } |
  Select-Object -First 1).IPAddress
if (-not $LanIp) { $LanIp = "127.0.0.1" }
$env:DCOV_TRUSTED_HOSTS = "[""$LanIp"",""localhost"",""127.0.0.1"",""*.local""]"

Set-Location backend
$hasUsers = & $Py -c "import sqlite3; c=sqlite3.connect(r'$Root\data\dcov.sqlite'); c.execute('select 1 from users limit 1'); print('yes')" 2>$null
if ($hasUsers -ne "yes") {
  Write-Host "== first run: database, administrator, seed catalogue"
  & $Py -c "import asyncio; from app.core.database import init_models; asyncio.run(init_models())"
  $pw = (& $Py -c "import secrets;print(secrets.token_urlsafe(12))") + "Aa1!"
  & $Py -m app.cli create_admin --username admin --password $pw
  & $Py -m app.cli load_seed "$Root\data\components_seed.json"
  Write-Host ""
  Write-Host "   ADMIN LOGIN:  admin / $pw     (shown once - write it down)"
}

Write-Host ""
Write-Host " In the app: Settings > Server address = http://${LanIp}:$Port"
Write-Host " Test from the phone's browser:         http://${LanIp}:$Port/health"
Write-Host " If it cannot connect: allow Python through Windows Defender Firewall (Private networks)."
& $Py -m uvicorn app.main:app --host 0.0.0.0 --port $Port --proxy-headers
