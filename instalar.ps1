# EternalTech AIO - instalador de una linea.
#   PowerShell como administrador:   irm https://raw.githubusercontent.com/eternaltech-ar/eternaltech-aio/main/instalar.ps1 | iex
# Baja la ultima version del repositorio a C:\EternalTech\AIO (conserva herramientas, informes y logs) y abre el menu.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$repoZip = 'https://github.com/eternaltech-ar/eternaltech-aio/archive/refs/heads/main.zip'
$base = 'C:\EternalTech\AIO'

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    Write-Host 'Pidiendo permisos de administrador...' -ForegroundColor Yellow
    $cmd = "irm https://raw.githubusercontent.com/eternaltech-ar/eternaltech-aio/main/instalar.ps1 | iex"
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -NoExit -Command $cmd"
    return
}

Write-Host 'Descargando EternalTech AIO...' -ForegroundColor Cyan
$tmp = Join-Path $env:TEMP 'eternaltech-aio.zip'
$dir = Join-Path $env:TEMP 'eternaltech-aio'
Invoke-WebRequest -Uri $repoZip -OutFile $tmp -UseBasicParsing
Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive -Path $tmp -DestinationPath $dir -Force
$src = Get-ChildItem $dir -Directory | Select-Object -First 1
New-Item -ItemType Directory -Force -Path $base | Out-Null
# config.json local (si lo editaste en esta PC) se respeta
$conf = Join-Path $base 'config.json'
$guardar = if (Test-Path $conf) { Get-Content -Raw $conf } else { $null }
Copy-Item -Path (Join-Path $src.FullName '*') -Destination $base -Recurse -Force
if ($guardar) { Set-Content -Path $conf -Value $guardar -Encoding UTF8 }
Remove-Item $tmp, $dir -Recurse -Force -ErrorAction SilentlyContinue

Set-Location $base
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $base 'aio.ps1')
