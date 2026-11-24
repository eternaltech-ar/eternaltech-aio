<#
  EternalTech AIO - preparación, optimización y prueba de PCs armadas.
  Compatible con Windows PowerShell 5.1 (Windows 10 y 11). Se ejecuta como administrador desde iniciar.cmd.

  Modos:
    iniciar.cmd            -> menú (elegís qué hacer, y en Programas qué instalar)
    iniciar.cmd -Auto      -> todo automático: diagnóstico, drivers, programas faltantes, optimización,
                              reinicio si hace falta, pruebas con Cinebench e informe.
#>
param([switch]$Auto, [switch]$Reanudar)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ------------------------------------------------------------------ salida por pantalla
function Titulo($t) { Write-Host ''; Write-Host ('=' * 70) -ForegroundColor DarkCyan; Write-Host "  $t" -ForegroundColor Cyan; Write-Host ('=' * 70) -ForegroundColor DarkCyan }
function Info($t)   { Write-Host "  $t" }
function Ok($t)     { Write-Host "  [OK] $t" -ForegroundColor Green }
function Aviso($t)  { Write-Host "  [!]  $t" -ForegroundColor Yellow }
function Falla($t)  { Write-Host "  [X]  $t" -ForegroundColor Red }


# ------------------------------------------------------------------ rutas
$Origen = $PSScriptRoot
$Base = 'C:\EternalTech\AIO'
$TareaReanudar = 'EternalTech AIO - reanudar'

function Es-Removible($ruta) {
    try {
        $letra = (Split-Path -Qualifier $ruta).TrimEnd(':')
        $vol = Get-Volume -DriveLetter $letra -ErrorAction Stop
        return $vol.DriveType -eq 'Removable'
    } catch { return $false }
}

# Si corre desde el pendrive, se copia al disco: así sobrevive a los reinicios aunque saques el USB.
if ($Origen -ne $Base) {
    New-Item -ItemType Directory -Force -Path $Base | Out-Null
    Copy-Item -Path (Join-Path $Origen '*') -Destination $Base -Recurse -Force -Exclude 'informes'
}
$CarpetaInformes = if (Es-Removible $Origen) { Join-Path $Origen 'informes' } else { Join-Path $Base 'informes' }
$ArchivoEstado = Join-Path $Base 'estado.json'
# Al reanudar después de un reinicio se usa la carpeta de informes del pendrive si sigue conectado.
if ($Reanudar -and (Test-Path $ArchivoEstado)) {
    $ci = (Get-Content -Raw -Encoding UTF8 $ArchivoEstado | ConvertFrom-Json).carpeta_informes
    if ($ci -and (Test-Path (Split-Path -Qualifier $ci))) { $CarpetaInformes = $ci }
}
New-Item -ItemType Directory -Force -Path $CarpetaInformes, (Join-Path $Base 'logs') | Out-Null

$Cfg = Get-Content -Raw -Encoding UTF8 (Join-Path $Base 'config.json') | ConvertFrom-Json
Start-Transcript -Path (Join-Path $Base ("logs\aio_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))) -Append | Out-Null


# ------------------------------------------------------------------ estado (sobrevive a reinicios)
$Estado = [ordered]@{ inicio = (Get-Date).ToString('s'); pasos = @(); hardware = $null; diagnostico = @();
                      drivers = @(); programas = @(); optimizacion = @(); pruebas = @(); undervolt = $null; reinicio_pendiente = $false; carpeta_informes = $CarpetaInformes }
if ($Reanudar -and (Test-Path $ArchivoEstado)) {
    $prev = Get-Content -Raw -Encoding UTF8 $ArchivoEstado | ConvertFrom-Json
    foreach ($p in $prev.PSObject.Properties) { if ($p.Name -ne 'carpeta_informes') { $Estado[$p.Name] = $p.Value } }
    $Estado.pasos = @($Estado.pasos)
}
function Guardar-Estado { $Estado | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 $ArchivoEstado }
function Paso-Hecho($p) { return @($Estado.pasos) -contains $p }
function Marcar-Paso($p) { $Estado.pasos = @(@($Estado.pasos) + $p | Select-Object -Unique); Guardar-Estado }

# ================================================================== 1. HARDWARE Y DIAGNÓSTICO
function Obtener-VRAM {
    # AdapterRAM de WMI se corta en 4 GB; el registro tiene el valor real.
    $res = @{}
    Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}' -ErrorAction SilentlyContinue |
        ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($p -and $p.DriverDesc -and $p.'HardwareInformation.qwMemorySize') {
                $res[$p.DriverDesc] = [math]::Round([double]$p.'HardwareInformation.qwMemorySize' / 1GB, 1)
            }
        }
    return $res
}

function Obtener-Hardware {
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $mb = Get-CimInstance Win32_BaseBoard
    $bios = Get-CimInstance Win32_BIOS
    $os = Get-CimInstance Win32_OperatingSystem
    $vram = Obtener-VRAM
    $ram = @(Get-CimInstance Win32_PhysicalMemory | ForEach-Object {
        [ordered]@{ slot = $_.DeviceLocator; gb = [math]::Round($_.Capacity / 1GB); fabricante = "$($_.Manufacturer)".Trim()
                    modelo = "$($_.PartNumber)".Trim(); mhz_nominal = $_.Speed; mhz_actual = $_.ConfiguredClockSpeed }
    })
    $gpus = @(Get-CimInstance Win32_VideoController | ForEach-Object {
        [ordered]@{ nombre = $_.Name; driver = $_.DriverVersion; vram_gb = $vram[$_.Name]
                    activa = [bool]$_.CurrentHorizontalResolution
                    resolucion = if ($_.CurrentHorizontalResolution) { "$($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution)" } else { $null }
                    hz_actual = $_.CurrentRefreshRate; hz_max = $_.MaxRefreshRate }
    })
    $discos = @(Get-PhysicalDisk | ForEach-Object {
        [ordered]@{ nombre = $_.FriendlyName; tipo = "$($_.MediaType)"; bus = "$($_.BusType)"
                    gb = [math]::Round($_.Size / 1GB); salud = "$($_.HealthStatus)" }
    })
    $activado = $null
    try {
        $lic = Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND Name LIKE 'Windows%'" -ErrorAction Stop | Select-Object -First 1
        $activado = ($lic.LicenseStatus -eq 1)
    } catch {}
    $secure = $null; try { $secure = Confirm-SecureBootUEFI -ErrorAction Stop } catch {}
    $tpm = $null; try { $t = Get-Tpm -ErrorAction Stop; $tpm = [bool]($t.TpmPresent -and $t.TpmReady) } catch {}
    return [ordered]@{
        equipo = $env:COMPUTERNAME
        serie = "$($bios.SerialNumber)".Trim()
        cpu = "$($cpu.Name)".Trim(); nucleos = $cpu.NumberOfCores; hilos = $cpu.NumberOfLogicalProcessors
        fabricante_cpu = if ($cpu.Manufacturer -match 'AMD') { 'AMD' } elseif ($cpu.Manufacturer -match 'Intel') { 'Intel' } else { "$($cpu.Manufacturer)" }
        mother = ("{0} {1}" -f $mb.Manufacturer, $mb.Product).Trim()
        bios = ("{0} ({1:yyyy-MM-dd})" -f $bios.SMBIOSBIOSVersion, $bios.ReleaseDate)
        ram_total_gb = [math]::Round(($ram | Measure-Object -Property gb -Sum).Sum)
        ram = $ram; gpus = $gpus; discos = $discos
        windows = ("{0} (compilación {1})" -f $os.Caption, $os.BuildNumber)
        activado = $activado; secure_boot = $secure; tpm = $tpm
    }
}

function Es-Notebook {
    # Tipos de chasis portátiles (SMBIOS) o batería presente
    $tipos = @((Get-CimInstance Win32_SystemEnclosure -ErrorAction SilentlyContinue).ChassisTypes)
    if ($tipos | Where-Object { $_ -in 8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32 }) { return $true }
    return [bool](Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
}

function Es-GpuDedicada($nombre) {
    if ($nombre -match 'NVIDIA|GeForce|RTX|GTX|Quadro') { return $true }
    if ($nombre -match 'Radeon' -and $nombre -match 'RX|PRO W|Vega 56|Vega 64') { return $true }
    if ($nombre -match 'Intel.*Arc' -and $nombre -notmatch 'Graphics$') { return $true }
    return $false
}

function Fabricante-Gpu($hw) {
    $g = @($hw.gpus | Where-Object { Es-GpuDedicada $_.nombre }) | Select-Object -First 1
    if (-not $g) { return $null }
    if ($g.nombre -match 'NVIDIA|GeForce|RTX|GTX|Quadro') { return 'NVIDIA' }
    if ($g.nombre -match 'Radeon') { return 'AMD' }
    return 'Intel'
}

# ------------------------------------------------------------------ CrystalDiskInfo (salud SMART de los discos)
function Ruta-CrystalDiskInfo {
    $c = Get-ChildItem (Join-Path $Base 'herramientas\crystaldiskinfo') -Filter 'DiskInfo64.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.FullName }
    foreach ($p in "$env:ProgramFiles\CrystalDiskInfo\DiskInfo64.exe", "${env:ProgramFiles(x86)}\CrystalDiskInfo\DiskInfo64.exe") { if (Test-Path $p) { return $p } }
    # Si no está en el pendrive ni instalado, se instala con winget
    if ((Hay-Internet) -and (Asegurar-Winget)) {
        Info 'Instalando CrystalDiskInfo...'
        & winget install --id CrystalDewWorld.CrystalDiskInfo -e --silent --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
        foreach ($p in "$env:ProgramFiles\CrystalDiskInfo\DiskInfo64.exe", "${env:ProgramFiles(x86)}\CrystalDiskInfo\DiskInfo64.exe") { if (Test-Path $p) { return $p } }
    }
    return $null
}

function CrystalDisk {
    # "DiskInfo64.exe /CopyExit" escribe DiskInfo.txt (informe completo) en su carpeta y se cierra
    $exe = Ruta-CrystalDiskInfo
    if (-not $exe) { Aviso 'No está CrystalDiskInfo (herramientas\crystaldiskinfo): se usa solo la salud que informa Windows.'; return @() }
    $txt = Join-Path (Split-Path $exe) 'DiskInfo.txt'
    Remove-Item $txt -ErrorAction SilentlyContinue
    Start-Process -FilePath $exe -ArgumentList '/CopyExit' -Wait -WindowStyle Hidden
    if (-not (Test-Path $txt)) { Aviso 'CrystalDiskInfo no generó el informe.'; return @() }
    Copy-Item $txt (Join-Path $Base ("logs\DiskInfo_{0:yyyyMMdd_HHmmss}.txt" -f (Get-Date))) -Force
    $discos = New-Object System.Collections.ArrayList
    $actual = $null
    foreach ($l in (Get-Content $txt)) {
        if ($l -match '^\s*\((\d+)\)\s+(.+?)\s*$' -and $l -notmatch ':') {
            $actual = [ordered]@{ modelo = $Matches[2]; salud = $null; porcentaje = $null; temp = $null; horas = $null; encendidos = $null
                                  escrito = $null; interfaz = $null; modo = $null; tamano = $null }
            [void]$discos.Add($actual); continue
        }
        if (-not $actual -or $l -notmatch '^\s*([^:]+?)\s*:\s*(.*)$') { continue }
        $k = $Matches[1]; $v = $Matches[2].Trim()
        switch -Regex ($k) {
            '^Health Status$'   { $actual.salud = ($v -replace '\s*\(.*$', ''); if ($v -match '(\d+)\s*%') { $actual.porcentaje = [int]$Matches[1] } }
            '^Temperature$'     { if ($v -match '^(\d+)') { $actual.temp = [int]$Matches[1] } }
            '^Power On Hours$'  { if ($v -match '(\d+)') { $actual.horas = [int]$Matches[1] } }
            '^Power On Count$'  { if ($v -match '(\d+)') { $actual.encendidos = [int]$Matches[1] } }
            '^Host Writes$'     { $actual.escrito = $v }
            '^Interface$'       { $actual.interfaz = $v }
            '^Transfer Mode$'   { $actual.modo = $v }
            '^Disk Size$'       { $actual.tamano = $v }
        }
    }
    return @($discos)
}

function Diagnostico {
    Titulo 'Diagnóstico del equipo'
    $hw = Obtener-Hardware
    $Estado.hardware = $hw
    $h = New-Object System.Collections.ArrayList
    function Hallazgo($nivel, $texto) { [void]$h.Add([ordered]@{ nivel = $nivel; texto = $texto }) }

    Info "CPU:     $($hw.cpu) ($($hw.nucleos) núcleos / $($hw.hilos) hilos)"
    Info "Mother:  $($hw.mother)  -  BIOS $($hw.bios)"
    Info "RAM:     $($hw.ram_total_gb) GB en $(@($hw.ram).Count) módulo(s)"
    foreach ($g in $hw.gpus) { Info "GPU:     $($g.nombre)  (driver $($g.driver))" }
    foreach ($d in $hw.discos) { Info "Disco:   $($d.nombre)  $($d.gb) GB  $($d.bus)  salud: $($d.salud)" }
    Info "Windows: $($hw.windows)"

    # RAM: XMP/EXPO y canales
    foreach ($m in $hw.ram) {
        if ($m.mhz_nominal -and $m.mhz_actual -and $m.mhz_actual -lt $m.mhz_nominal) {
            Hallazgo 'aviso' "La RAM ($($m.slot)) trabaja a $($m.mhz_actual) MHz y soporta $($m.mhz_nominal) MHz: activar XMP/EXPO en el BIOS."
            break
        }
    }
    $actual = ($hw.ram | Select-Object -First 1).mhz_actual
    if ($actual -in 2133, 2400, 4800 -and -not ($h | Where-Object { $_.texto -match 'XMP' })) { Hallazgo 'aviso' "La RAM corre a $actual MHz (velocidad base JEDEC): revisar que XMP/EXPO esté activado." }
    if (@($hw.ram).Count -eq 1) { Hallazgo 'aviso' 'Hay un solo módulo de RAM: trabaja en un canal (menos rendimiento, sobre todo con video integrado).' }
    elseif (@($hw.ram).Count -eq 2) {
        $slots = ($hw.ram | ForEach-Object { $_.slot }) -join ' '
        Hallazgo 'info' "RAM en las ranuras: $slots (para doble canal suelen ir en A2 y B2; ver manual del mother)."
    }

    # Video: monitor en la placa dedicada y frecuencia de refresco
    $dedicadas = @($hw.gpus | Where-Object { Es-GpuDedicada $_.nombre })
    if ($dedicadas.Count -gt 0) {
        $activaIntegrada = @($hw.gpus | Where-Object { $_.activa -and -not (Es-GpuDedicada $_.nombre) })
        if ($activaIntegrada.Count -gt 0 -and -not ($dedicadas | Where-Object { $_.activa })) {
            Hallazgo 'error' 'El monitor está conectado al video integrado del mother y no a la placa de video.'
        }
    }
    foreach ($g in ($hw.gpus | Where-Object { $_.activa })) {
        if ($g.hz_max -and $g.hz_actual -and $g.hz_actual -lt $g.hz_max -and $g.hz_max -le 360) {
            Hallazgo 'aviso' "El monitor está a $($g.hz_actual) Hz y la salida permite $($g.hz_max) Hz: subir la frecuencia en Configuración > Pantalla > Pantalla avanzada."
        }
        if (-not $g.driver -or $g.nombre -match 'Microsoft Basic') { Hallazgo 'error' "Falta el driver de video ($($g.nombre))." }
    }

    # Discos: salud SMART con CrystalDiskInfo (y la de Windows como respaldo)
    $cdi = CrystalDisk
    $hw.crystaldisk = $cdi
    foreach ($d in $cdi) {
        $det = "$($d.modelo): $($d.salud)$(if ($d.porcentaje) { " ($($d.porcentaje) %)" }), $(Fmt $d.temp ' °C'), $($d.horas) h de uso, $($d.encendidos) encendidos"
        switch -Regex ("$($d.salud)") {
            'Good|Bueno'      { Hallazgo 'ok' "Disco $det" }
            'Caution|Precau'  { Hallazgo 'aviso' "Disco con advertencia - $det" }
            'Bad|Malo'        { Hallazgo 'error' "Disco en mal estado - $det" }
            default           { Hallazgo 'info' "Disco $det" }
        }
        if ($d.horas -gt [int]$Cfg.discos.horas_max_nuevo) { Hallazgo 'aviso' "$($d.modelo) tiene $($d.horas) horas de uso: no es un disco nuevo." }
        if ($d.temp -gt [int]$Cfg.discos.temp_max) { Hallazgo 'aviso' "$($d.modelo) está a $($d.temp) °C en reposo: revisar disipador o flujo de aire." }
        # Modo de transferencia "actual | máximo": si el actual es menor, está en un puerto o slot más lento
        if ($d.modo -match '^\s*(.+?)\s*\|\s*(.+?)\s*$' -and $Matches[1] -ne $Matches[2] -and $Matches[1] -notmatch '----') {
            Hallazgo 'aviso' "$($d.modelo) trabaja en $($Matches[1]) y soporta $($Matches[2]): revisar slot M.2 / puerto SATA o cable."
        }
    }
    if ($cdi.Count -eq 0) {
        foreach ($d in $hw.discos) { if ($d.salud -and $d.salud -ne 'Healthy') { Hallazgo 'error' "El disco $($d.nombre) informa salud '$($d.salud)'." } }
    }

    # Dispositivos sin driver o con error
    $malos = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.Status -in 'Error', 'Degraded', 'Unknown' })
    foreach ($d in $malos) { Hallazgo 'error' "Dispositivo con problema: $($d.FriendlyName) [$($d.Class)] - $($d.Status)" }
    if ($malos.Count -eq 0) { Hallazgo 'ok' 'Todos los dispositivos tienen driver.' }

    # Windows
    if ($hw.activado -eq $false) { Hallazgo 'aviso' 'Windows no está activado.' }
    if ($hw.secure_boot -eq $false) { Hallazgo 'info' 'Secure Boot desactivado.' }
    if ($hw.tpm -eq $false) { Hallazgo 'aviso' 'TPM no disponible o no listo (necesario para Windows 11): activar fTPM/PTT en el BIOS.' }

    foreach ($x in $h) {
        switch ($x.nivel) { 'error' { Falla $x.texto } 'aviso' { Aviso $x.texto } 'ok' { Ok $x.texto } default { Info $x.texto } }
    }
    $Estado.diagnostico = @($h)
    Guardar-Estado
}

# ================================================================== 2. DRIVERS
function Drivers {
    Titulo 'Drivers'
    if (-not $Estado.hardware) { $Estado.hardware = Obtener-Hardware }
    $hw = $Estado.hardware
    $res = New-Object System.Collections.ArrayList

    # a) .inf del pendrive (red, wifi...) para tener internet en equipos sin driver de red
    $carpetaInf = Join-Path $Base 'herramientas\drivers'
    if (Test-Path $carpetaInf) {
        Info 'Instalando drivers del pendrive (.inf)...'
        $salida = & pnputil.exe /add-driver (Join-Path $carpetaInf '*.inf') /subdirs /install 2>&1
        $n = @($salida | Select-String -Pattern 'added|agregado|Added driver').Count
        Ok "Drivers del pendrive procesados ($n paquetes)."
        [void]$res.Add([ordered]@{ origen = 'pendrive (.inf)'; resultado = "$n paquetes" })
    }

    # b) instaladores (chipset, video) que estén en herramientas\instaladores
    $carpetaInst = Join-Path $Base 'herramientas\instaladores'
    $gpuFab = Fabricante-Gpu $hw
    foreach ($i in @($Cfg.drivers.instaladores)) {
        if ($i.si_cpu -and $i.si_cpu -ne $hw.fabricante_cpu) { continue }
        if ($i.si_gpu -and $i.si_gpu -ne $gpuFab) { continue }
        $arch = Get-ChildItem -Path $carpetaInst -Filter $i.archivo -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $arch) { continue }
        Info "Instalando $($arch.Name)..."
        $p = Start-Process -FilePath $arch.FullName -ArgumentList $i.argumentos -Wait -PassThru
        if ($p.ExitCode -in 0, 3010, 1641) { Ok "$($arch.Name) instalado."; if ($p.ExitCode -ne 0) { $Estado.reinicio_pendiente = $true } }
        else { Aviso "$($arch.Name) terminó con código $($p.ExitCode)." }
        [void]$res.Add([ordered]@{ origen = $arch.Name; resultado = "código $($p.ExitCode)" })
    }

    # c) Windows Update (solo drivers)
    if ($Cfg.drivers.windows_update) {
        if (-not (Hay-Internet)) { Aviso 'Sin internet: se saltea la búsqueda de drivers en Windows Update.' }
        else {
            Info 'Buscando drivers en Windows Update (puede tardar varios minutos)...'
            try {
                $sesion = New-Object -ComObject Microsoft.Update.Session
                $buscador = $sesion.CreateUpdateSearcher()
                $encontrados = $buscador.Search("IsInstalled=0 and Type='Driver' and IsHidden=0").Updates
                if ($encontrados.Count -eq 0) { Ok 'Windows Update no tiene drivers pendientes.' }
                else {
                    $col = New-Object -ComObject Microsoft.Update.UpdateColl
                    foreach ($u in $encontrados) { Info "  - $($u.Title)"; if (-not $u.EulaAccepted) { $u.AcceptEula() }; [void]$col.Add($u) }
                    $desc = $sesion.CreateUpdateDownloader(); $desc.Updates = $col; [void]$desc.Download()
                    $inst = $sesion.CreateUpdateInstaller(); $inst.Updates = $col; $r = $inst.Install()
                    for ($k = 0; $k -lt $col.Count; $k++) {
                        $codigo = $r.GetUpdateResult($k).ResultCode   # 2 = correcto, 3 = con errores, 4 = falló
                        [void]$res.Add([ordered]@{ origen = 'Windows Update'; resultado = $col.Item($k).Title + $(if ($codigo -eq 2) { '' } else { " (código $codigo)" }) })
                    }
                    if ($r.RebootRequired) { $Estado.reinicio_pendiente = $true }
                    Ok "Windows Update: $($col.Count) driver(s) instalados."
                }
            } catch { Falla "Windows Update: $($_.Exception.Message)" }
        }
    }
    $Estado.drivers = @($res)
    Guardar-Estado
}

# ================================================================== 3. PROGRAMAS (winget)
function Hay-Internet {
    try { if (Test-Connection -ComputerName 1.1.1.1 -Count 1 -Quiet -ErrorAction Stop) { return $true } } catch {}
    try { $r = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 8; return ($r.StatusCode -eq 200) } catch { return $false }
}

function Asegurar-Winget {
    if (Get-Command winget -ErrorAction SilentlyContinue) { return $true }
    Info 'winget no está disponible; intentando registrarlo...'
    try { Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop } catch {}
    if (Get-Command winget -ErrorAction SilentlyContinue) { return $true }
    # Instalador guardado en el pendrive: herramientas\winget\ (msixbundle + dependencias .appx)
    $carp = Join-Path $Base 'herramientas\winget'
    if (Test-Path $carp) {
        Get-ChildItem $carp -Filter *.appx | ForEach-Object { try { Add-AppxPackage $_.FullName -ErrorAction Stop } catch {} }
        Get-ChildItem $carp -Filter *.msixbundle | ForEach-Object { try { Add-AppxPackage $_.FullName -ErrorAction Stop } catch {} }
    }
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User') + ";$env:LOCALAPPDATA\Microsoft\WindowsApps"
    return [bool](Get-Command winget -ErrorAction SilentlyContinue)
}

function Programas-Instalados {
    # winget export lista los programas instalados que winget reconoce, con su ID exacto.
    $tmp = Join-Path $env:TEMP 'et_winget.json'
    Remove-Item $tmp -ErrorAction SilentlyContinue
    & winget export -o $tmp --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
    $ids = @{}
    if (Test-Path $tmp) {
        $j = Get-Content -Raw $tmp | ConvertFrom-Json
        foreach ($s in $j.Sources) { foreach ($p in $s.Packages) { $ids[$p.PackageIdentifier.ToLower()] = $true } }
    }
    return $ids
}

function Instalar-Lista($lista) {
    $res = New-Object System.Collections.ArrayList
    foreach ($p in $lista) {
        Info "Instalando $($p.nombre)..."
        & winget install --id $p.id -e --silent --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
        $c = $LASTEXITCODE
        # 0 ok; -1978335189 / -1978335135 = ya instalado / sin actualización aplicable
        if ($c -eq 0) { Ok "$($p.nombre) instalado."; $r = 'instalado' }
        elseif ($c -in -1978335189, -1978335135) { Ok "$($p.nombre) ya estaba instalado."; $r = 'ya estaba' }
        elseif ($c -in 3010, 1641) { Ok "$($p.nombre) instalado (pide reinicio)."; $r = 'instalado'; $Estado.reinicio_pendiente = $true }
        else { Falla "$($p.nombre): error $c"; $r = "error $c" }
        [void]$res.Add([ordered]@{ nombre = $p.nombre; id = $p.id; resultado = $r })
    }
    return @($res)
}

function Office-Instalado {
    foreach ($r in "$env:ProgramFiles\Microsoft Office\root\Office16\WINWORD.EXE", "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16\WINWORD.EXE") {
        if (Test-Path $r) { return $true }
    }
    return $false
}

function Instalar-Office {
    $o = $Cfg.office
    if (-not $o -or -not $o.instalar) { return }
    if (Office-Instalado) { Ok 'Office ya está instalado.'; return }
    Info 'Descargando el instalador de Office (Microsoft 365 Apps, español, 64 bits)...'
    $exe = Join-Path $env:TEMP 'OfficeSetup.exe'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $o.url -OutFile $exe -UseBasicParsing
        Info 'Instalando Office (tarda varios minutos, se ve la ventana de progreso de Microsoft)...'
        Start-Process -FilePath $exe -Wait
        # el instalador de clic para ejecutar termina antes que la instalación: se espera a que aparezca Word
        for ($i = 0; $i -lt 90 -and -not (Office-Instalado); $i++) { Start-Sleep -Seconds 10 }
        if (Office-Instalado) { Ok 'Office instalado.'; $r = 'instalado' } else { Aviso 'Office no terminó de instalarse todavía (revisar la ventana de Microsoft).'; $r = 'pendiente' }
    } catch { Falla "Office: $($_.Exception.Message)"; $r = 'error' }
    $Estado.programas = @(@($Estado.programas) + [ordered]@{ nombre = 'Microsoft Office'; id = 'office'; resultado = $r })
    Guardar-Estado
}

function Programas([switch]$Automatico) {
    Titulo 'Programas'
    if (-not (Hay-Internet)) { Falla 'Sin internet: no se pueden instalar programas.'; return }
    Instalar-Office
    if (-not (Asegurar-Winget)) { Falla 'No se pudo habilitar winget (actualizar "Instalador de aplicación" desde Microsoft Store).'; return }
    Info 'Revisando qué está instalado...'
    $inst = Programas-Instalados
    if (-not $Estado.hardware) { $Estado.hardware = Obtener-Hardware }
    $notebook = Es-Notebook
    $dedicada = [bool](Fabricante-Gpu $Estado.hardware)
    $todos = @($Cfg.programas | Where-Object {
        -not ($_.solo_gpu_dedicada -and -not $dedicada) -and -not ($_.omitir_notebook -and $notebook) })
    if ($notebook) { Info 'Es una notebook: no se instalan MSI Afterburner ni RivaTuner.' }
    elseif (-not $dedicada) { Info 'Sin placa de video dedicada: no se instalan MSI Afterburner ni RivaTuner.' }

    if ($Automatico) {
        $elegidos = @($todos | Where-Object { $_.auto -and -not $inst[$_.id.ToLower()] })
        $ya = @($todos | Where-Object { $_.auto -and $inst[$_.id.ToLower()] })
        foreach ($p in $ya) { Ok "$($p.nombre) ya está instalado." }
    } else {
        $elegidos = Menu-Programas $todos $inst
    }
    if (@($elegidos).Count -eq 0) { Info 'Nada para instalar.'; return }
    $r = Instalar-Lista $elegidos
    $Estado.programas = @(@($Estado.programas) + $r)
    Guardar-Estado
}

function Menu-Programas($todos, $inst) {
    $marcados = @{}
    for ($i = 0; $i -lt $todos.Count; $i++) { if ($todos[$i].auto -and -not $inst[$todos[$i].id.ToLower()]) { $marcados[$i] = $true } }
    while ($true) {
        Write-Host ''
        $grupo = ''
        for ($i = 0; $i -lt $todos.Count; $i++) {
            $p = $todos[$i]
            if ($p.grupo -ne $grupo) { $grupo = $p.grupo; Write-Host "  -- $grupo --" -ForegroundColor DarkGray }
            $ya = $inst[$p.id.ToLower()]
            $marca = if ($ya) { '[instalado]' } elseif ($marcados[$i]) { '[X]' } else { '[ ]' }
            $color = if ($ya) { 'DarkGray' } elseif ($marcados[$i]) { 'Green' } else { 'Gray' }
            Write-Host ("  {0,2}. {1,-12} {2}" -f ($i + 1), $marca, $p.nombre) -ForegroundColor $color
        }
        Write-Host ''
        Write-Host '  Números separados por coma para marcar/desmarcar (ej: 3,5,12)'
        Write-Host '  g:NOMBRE marca un grupo (ej: g:juegos)   I = instalar lo marcado   0 = volver'
        $r = (Read-Host '  Opción').Trim()
        if ($r -eq '0') { return @() }
        if ($r -match '^[iI]$') { return @($marcados.Keys | Sort-Object | ForEach-Object { $todos[$_] }) }
        if ($r -match '^g:(.+)$') {
            $g = $Matches[1].Trim()
            for ($i = 0; $i -lt $todos.Count; $i++) { if ($todos[$i].grupo -eq $g -and -not $inst[$todos[$i].id.ToLower()]) { $marcados[$i] = $true } }
            continue
        }
        foreach ($n in ($r -split '[,\s]+' | Where-Object { $_ -match '^\d+$' })) {
            $k = [int]$n - 1
            if ($k -ge 0 -and $k -lt $todos.Count -and -not $inst[$todos[$k].id.ToLower()]) {
                if ($marcados[$k]) { $marcados.Remove($k) } else { $marcados[$k] = $true }
            }
        }
    }
}

# ================================================================== 4. OPTIMIZACIÓN DE WINDOWS
function Reg-Set($ruta, $nombre, $valor, $tipo = 'DWord') {
    if (-not (Test-Path $ruta)) { New-Item -Path $ruta -Force | Out-Null }
    New-ItemProperty -Path $ruta -Name $nombre -Value $valor -PropertyType $tipo -Force | Out-Null
}

function Optimizar {
    Titulo 'Optimización de Windows'
    $o = $Cfg.optimizacion
    $res = New-Object System.Collections.ArrayList
    function Hecho($t) { Ok $t; [void]$res.Add($t) }

    if ($o.punto_de_restauracion) {
        try {
            Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
            Reg-Set 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' 'SystemRestorePointCreationFrequency' 0
            Checkpoint-Computer -Description 'EternalTech AIO - antes de optimizar' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
            Hecho 'Punto de restauración creado.'
        } catch { Aviso "No se pudo crear el punto de restauración: $($_.Exception.Message)" }
    }

    if ($o.plan_energia -eq 'alto_rendimiento') {
        & powercfg /setactive SCHEME_MIN 2>&1 | Out-Null    # SCHEME_MIN = Alto rendimiento
        Hecho 'Plan de energía: Alto rendimiento.'
    }
    if ($o.suspension_nunca) {
        & powercfg /change standby-timeout-ac 0; & powercfg /change hibernate-timeout-ac 0; & powercfg /change monitor-timeout-ac 15
        Hecho 'Suspensión desactivada (la pantalla se apaga a los 15 min).'
    }
    if ($o.modo_juego) {
        Reg-Set 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1
        Reg-Set 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1
        Hecho 'Modo juego activado.'
    }
    if ($o.gpu_scheduling -and (Fabricante-Gpu $Estado.hardware)) {
        Reg-Set 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2
        $Estado.reinicio_pendiente = $true
        Hecho 'Programación de GPU acelerada por hardware activada (aplica al reiniciar).'
    }
    if ($o.quitar_publicidad_y_sugerencias) {
        $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
        foreach ($v in 'SilentInstalledAppsEnabled', 'SystemPaneSuggestionsEnabled', 'SoftLandingEnabled', 'SubscribedContent-338388Enabled',
                       'SubscribedContent-338389Enabled', 'SubscribedContent-353694Enabled', 'SubscribedContent-353696Enabled', 'PreInstalledAppsEnabled', 'OemPreInstalledAppsEnabled') {
            Reg-Set $cdm $v 0
        }
        Reg-Set 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
        Reg-Set 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_IrisRecommendations' 0
        Hecho 'Publicidad, sugerencias e instalación automática de apps promocionadas desactivadas.'
    }
    if ($o.quitar_apps_preinstaladas) {
        $quitadas = 0
        foreach ($n in @($o.apps_a_quitar)) {
            $pk = @(Get-AppxPackage -AllUsers -Name $n -ErrorAction SilentlyContinue)
            foreach ($x in $pk) { try { Remove-AppxPackage -Package $x.PackageFullName -AllUsers -ErrorAction Stop; $quitadas++ } catch {} }
            Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $n } |
                ForEach-Object { try { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction Stop | Out-Null } catch {} }
        }
        Hecho "Apps preinstaladas quitadas: $quitadas."
    }
    $Estado.optimizacion = @($res)
    Guardar-Estado
}

# ================================================================== 5. SENSORES Y PRUEBAS
$Script:LHM = $null
function Iniciar-Sensores {
    if ($Script:LHM) { return $true }
    $dll = Get-ChildItem (Join-Path $Base 'herramientas\lhm') -Filter 'LibreHardwareMonitorLib.dll' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $dll -and $Cfg.descargas.librehardwaremonitor_zip) {
        Descargar-Zip $Cfg.descargas.librehardwaremonitor_zip (Join-Path $Base 'herramientas\lhm')
        $dll = Get-ChildItem (Join-Path $Base 'herramientas\lhm') -Filter 'LibreHardwareMonitorLib.dll' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if (-not $dll) { Aviso 'Sin LibreHardwareMonitor en herramientas\lhm: no habrá temperatura de CPU (la de GPU NVIDIA se lee con nvidia-smi).'; return $false }
    try {
        Get-ChildItem $dll.DirectoryName -Filter *.dll | ForEach-Object { try { Add-Type -Path $_.FullName -ErrorAction Stop } catch {} }
        $c = New-Object LibreHardwareMonitor.Hardware.Computer
        $c.IsCpuEnabled = $true; $c.IsGpuEnabled = $true
        $c.Open()
        $Script:LHM = $c
        return $true
    } catch { Aviso "No se pudo iniciar LibreHardwareMonitor: $($_.Exception.Message)"; return $false }
}

function Leer-Sensores {
    $s = @{ cpu_temp = $null; cpu_w = $null; gpu_temp = $null; gpu_w = $null; gpu_mhz = $null }
    if ($Script:LHM) {
        foreach ($hw in $Script:LHM.Hardware) {
            $hw.Update()
            $tipo = "$($hw.HardwareType)"
            foreach ($x in $hw.Sensors) {
                if ($null -eq $x.Value) { continue }
                $st = "$($x.SensorType)"; $n = $x.Name; $v = [double]$x.Value
                if ($tipo -eq 'Cpu') {
                    if ($st -eq 'Temperature' -and $n -match 'Package|Tctl|Tdie|Core Max') { if ($null -eq $s.cpu_temp -or $v -gt $s.cpu_temp) { $s.cpu_temp = $v } }
                    if ($st -eq 'Power' -and $n -match 'Package') { $s.cpu_w = $v }
                } elseif ($tipo -match '^Gpu') {
                    if ($st -eq 'Temperature' -and $n -eq 'GPU Core') { $s.gpu_temp = $v }
                    if ($st -eq 'Power' -and $n -match 'GPU Package|GPU Power|Board Power|GPU Core') { if ($null -eq $s.gpu_w) { $s.gpu_w = $v } }
                    if ($st -eq 'Clock' -and $n -eq 'GPU Core') { $s.gpu_mhz = $v }
                }
            }
        }
    }
    if ($null -eq $s.gpu_temp -and (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) {
        $l = (& nvidia-smi --query-gpu=temperature.gpu,power.draw,clocks.gr --format=csv,noheader,nounits 2>$null | Select-Object -First 1)
        if ($l) { $p = $l -split ',\s*'; $s.gpu_temp = [double]$p[0]; $s.gpu_w = [double]($p[1] -replace '[^\d.]', ''); $s.gpu_mhz = [double]$p[2] }
    }
    return $s
}

function Descargar-Zip($url, $destino) {
    if (-not $url -or -not (Hay-Internet)) { return }
    try {
        Info "Descargando $url ..."
        $zip = Join-Path $env:TEMP ('et_' + [IO.Path]::GetFileName($url))
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
        New-Item -ItemType Directory -Force -Path $destino | Out-Null
        Expand-Archive -Path $zip -DestinationPath $destino -Force
    } catch { Aviso "No se pudo descargar: $($_.Exception.Message)" }
}

function Ruta-Cinebench {
    $exe = Join-Path $Base $Cfg.pruebas.cinebench_exe
    if (Test-Path $exe) { return $exe }
    $alt = Get-ChildItem (Join-Path $Base 'herramientas') -Filter 'Cinebench.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($alt) { return $alt.FullName }
    if ($Cfg.descargas.cinebench_zip) {
        Descargar-Zip $Cfg.descargas.cinebench_zip (Join-Path $Base 'herramientas\cinebench')
        $alt = Get-ChildItem (Join-Path $Base 'herramientas') -Filter 'Cinebench.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($alt) { return $alt.FullName }
    }
    return $null
}

function Prueba-Cinebench($exe, $nombre, $parametro, $duracion) {
    Info "$nombre (mínimo $duracion s, no uses la PC mientras tanto)..."
    $log = Join-Path $Base ("logs\cinebench_{0}_{1:HHmmss}.txt" -f ($nombre -replace '\W', ''), (Get-Date))
    # "start /b /wait" hace que Cinebench escriba el resultado en la consola y se pueda capturar.
    $cmd = '/c start "parentconsole" /b /wait "{0}" {1}=true g_CinebenchMinimumTestDuration={2} > "{3}" 2>&1' -f $exe, $parametro, $duracion, $log
    $proc = Start-Process -FilePath cmd.exe -ArgumentList $cmd -PassThru -WindowStyle Hidden
    $lect = New-Object System.Collections.ArrayList
    $t0 = Get-Date
    $limCpu = [double]$Cfg.pruebas.temp_max_cpu; $limGpu = [double]$Cfg.pruebas.temp_max_gpu
    $cortada = $null
    while (-not $proc.HasExited) {
        Start-Sleep -Seconds ([int]$Cfg.pruebas.intervalo_lectura_seg)
        $s = Leer-Sensores
        [void]$lect.Add($s)
        $seg = [int]((Get-Date) - $t0).TotalSeconds
        $linea = "    {0,4}s  CPU {1}  GPU {2}" -f $seg, (Fmt $s.cpu_temp '°C'), (Fmt $s.gpu_temp '°C')
        Write-Host "`r$linea      " -NoNewline
        # Corte de seguridad: 5 °C por encima del límite
        if (($s.cpu_temp -and $s.cpu_temp -gt $limCpu + 5) -or ($s.gpu_temp -and $s.gpu_temp -gt $limGpu + 5)) {
            $cortada = 'temperatura excesiva'
            Get-Process -Name 'Cinebench' -ErrorAction SilentlyContinue | Stop-Process -Force
            break
        }
    }
    Write-Host ''
    $texto = if (Test-Path $log) { Get-Content -Raw $log } else { '' }
    $m = [regex]::Matches($texto, 'CB\s*[:=]?\s*([0-9]+(?:[.,][0-9]+)?)')
    $puntaje = if ($m.Count -gt 0) { [double]($m[$m.Count - 1].Groups[1].Value -replace ',', '.') } else { $null }

    function Estad($campo) {
        $v = @($lect | ForEach-Object { $_[$campo] } | Where-Object { $null -ne $_ })
        if ($v.Count -eq 0) { return @{ max = $null; prom = $null } }
        $mm = $v | Measure-Object -Maximum -Average
        return @{ max = [math]::Round($mm.Maximum, 1); prom = [math]::Round($mm.Average, 1) }
    }
    $r = [ordered]@{
        prueba = $nombre; puntaje = $puntaje; segundos = [int]((Get-Date) - $t0).TotalSeconds
        cpu_temp_max = (Estad 'cpu_temp').max; cpu_temp_prom = (Estad 'cpu_temp').prom; cpu_w_max = (Estad 'cpu_w').max
        gpu_temp_max = (Estad 'gpu_temp').max; gpu_temp_prom = (Estad 'gpu_temp').prom; gpu_w_max = (Estad 'gpu_w').max
        gpu_mhz_prom = (Estad 'gpu_mhz').prom; cortada = $cortada; log = $log
    }
    if ($cortada) { Falla "$nombre cortada por $cortada." }
    elseif ($puntaje) { Ok ("{0}: {1} puntos" -f $nombre, $puntaje) }
    else { Aviso "$nombre terminó pero no se encontró el puntaje (ver $log)." }
    if ($r.cpu_temp_max -and $r.cpu_temp_max -gt $limCpu) { Aviso "CPU llegó a $($r.cpu_temp_max) °C (límite $limCpu °C): revisar pasta y refrigeración." }
    if ($r.gpu_temp_max -and $r.gpu_temp_max -gt $limGpu) { Aviso "GPU llegó a $($r.gpu_temp_max) °C (límite $limGpu °C): revisar flujo de aire del gabinete." }
    return $r
}

function Fmt($v, $u) { if ($null -eq $v) { return '--' } return ('{0:N0}{1}' -f $v, $u) }

function Pruebas {
    Titulo 'Pruebas de estabilidad y Cinebench 2026 (valores de fábrica)'
    $exe = Ruta-Cinebench
    if (-not $exe) { Falla 'No está Cinebench: copiar la carpeta de Cinebench 2026 a herramientas\cinebench.'; return }
    [void](Iniciar-Sensores)
    if (-not $Estado.hardware) { $Estado.hardware = Obtener-Hardware }
    $p = $Cfg.pruebas
    $res = New-Object System.Collections.ArrayList
    if ($p.cpu_single) { [void]$res.Add((Prueba-Cinebench $exe 'CPU un núcleo' 'g_CinebenchCpu1Test' 0)) }
    if ($p.cpu_multi)  { [void]$res.Add((Prueba-Cinebench $exe 'CPU multinúcleo' 'g_CinebenchCpuXTest' ([int]$p.duracion_minima_seg))) }
    if ($p.gpu) {
        $ded = @($Estado.hardware.gpus | Where-Object { Es-GpuDedicada $_.nombre }) | Select-Object -First 1
        if (-not $ded) { Info 'Sin placa de video dedicada: se saltea la prueba de GPU.' }
        elseif ($ded.vram_gb -and $ded.vram_gb -lt 8) { Info "La GPU tiene $($ded.vram_gb) GB: Cinebench 2026 pide 8 GB o más, se saltea la prueba de GPU." }
        else { [void]$res.Add((Prueba-Cinebench $exe 'GPU' 'g_CinebenchGpuTest' ([int]$p.duracion_minima_seg))) }
    }
    $Estado.pruebas = @($res)
    Guardar-Estado
}

. (Join-Path $Base 'undervolt.ps1')

# ================================================================== 6. INFORME
function Html($t) { return [System.Net.WebUtility]::HtmlEncode("$t") }

function Informe {
    Titulo 'Informe'
    if (-not $Estado.hardware) { $Estado.hardware = Obtener-Hardware }
    $hw = $Estado.hardware; $t = $Cfg.taller
    $fecha = Get-Date
    $filas = { param($pares) ($pares | ForEach-Object { "<tr><th>$(Html $_[0])</th><td>$(Html $_[1])</td></tr>" }) -join "`n" }

    $equipo = & $filas @(
        ,@('Procesador', "$($hw.cpu) - $($hw.nucleos) núcleos / $($hw.hilos) hilos")
        ,@('Mother', $hw.mother)
        ,@('BIOS', $hw.bios)
        ,@('Memoria', ("{0} GB - " -f $hw.ram_total_gb) + (($hw.ram | ForEach-Object { "$($_.gb) GB $($_.fabricante) $($_.modelo) a $($_.mhz_actual) MHz" }) -join ' + '))
        ,@('Video', (($hw.gpus | ForEach-Object { $_.nombre + $(if ($_.vram_gb) { " ($($_.vram_gb) GB)" } else { '' }) }) -join ' / '))
        ,@('Almacenamiento', (($hw.discos | ForEach-Object { "$($_.nombre) $($_.gb) GB ($($_.bus))" }) -join ' / '))
        ,@('Sistema', $hw.windows + $(if ($hw.activado) { ' - activado' } elseif ($hw.activado -eq $false) { ' - sin activar' } else { '' }))
    )
    $cdi = @($hw.crystaldisk)
    $discosHtml = if ($cdi.Count) {
        "<h2>Discos (CrystalDiskInfo)</h2><table><thead><tr><td>Disco</td><td>Salud</td><td class='num'>Temp.</td><td class='num'>Horas de uso</td><td class='num'>Encendidos</td><td>Conexión</td></tr></thead>" +
        (($cdi | ForEach-Object { "<tr><td>$(Html $_.modelo) $(Html $_.tamano)</td><td>$(Html $_.salud)$(if ($_.porcentaje) { " ($($_.porcentaje) %)" })</td><td class='num'>$(Fmt $_.temp ' °C')</td><td class='num'>$($_.horas)</td><td class='num'>$($_.encendidos)</td><td>$(Html $_.modo)</td></tr>" }) -join '') + "</table>"
    } else { '' }
    $diag = ($Estado.diagnostico | ForEach-Object { "<li class='$($_.nivel)'>$(Html $_.texto)</li>" }) -join "`n"
    $pru = ($Estado.pruebas | ForEach-Object {
        "<tr><td>$(Html $_.prueba)</td><td class='num'>$(if ($_.puntaje) { '{0:N0}' -f $_.puntaje } else { '-' })</td>" +
        "<td class='num'>$(Fmt $_.cpu_temp_max ' °C')</td><td class='num'>$(Fmt $_.gpu_temp_max ' °C')</td>" +
        "<td class='num'>$(Fmt $_.cpu_w_max ' W') / $(Fmt $_.gpu_w_max ' W')</td><td>$(if ($_.cortada) { 'Cortada: ' + $_.cortada } else { 'Estable (' + $_.segundos + ' s)' })</td></tr>"
    }) -join "`n"
    $prog = ($Estado.programas | ForEach-Object { "<li>$(Html $_.nombre) - $(Html $_.resultado)</li>" }) -join "`n"
    $opt = ($Estado.optimizacion | ForEach-Object { "<li>$(Html $_)</li>" }) -join "`n"
    $uv = $Estado.undervolt
    $uvHtml = if ($uv) {
        "<h2>Undervolt de la placa de video</h2><table><thead><tr><td></td><td class='num'>Puntaje</td><td class='num'>Consumo máx</td><td class='num'>Temp. máx</td></tr></thead>" +
        "<tr><td>De fábrica</td><td class='num'>$('{0:N0}' -f $uv.fabrica.puntaje)</td><td class='num'>$(Fmt $uv.fabrica.w_max ' W')</td><td class='num'>$(Fmt $uv.fabrica.temp_max ' °C')</td></tr>" +
        "<tr><td>Con undervolt</td><td class='num'>$('{0:N0}' -f $uv.undervolt.puntaje)</td><td class='num'>$(Fmt $uv.undervolt.w_max ' W')</td><td class='num'>$(Fmt $uv.undervolt.temp_max ' °C')</td></tr></table>" +
        "<p style='font-size:13px;color:#667'>Ajuste hecho con MSI Afterburner: rendimiento similar con menos voltaje, así la placa consume menos, calienta menos y hace menos ruido. Afterburner lo aplica solo al iniciar Windows: no hace falta tocar nada.</p>"
    } else { '' }
    $drv = ($Estado.drivers | ForEach-Object { "<li>$(Html $_.origen): $(Html $_.resultado)</li>" }) -join "`n"

    $html = @"
<!DOCTYPE html><html lang="es"><head><meta charset="utf-8"><title>Informe de tu PC - $(Html $t.nombre)</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;max-width:860px;margin:30px auto;color:#1d2330;padding:0 16px}
h1{margin:0;font-size:26px} .sub{color:#667;margin:4px 0 24px} h2{font-size:18px;border-bottom:2px solid #e3e6ee;padding-bottom:6px;margin-top:28px}
table{width:100%;border-collapse:collapse} th,td{padding:7px 8px;border-bottom:1px solid #eceef3;text-align:left;font-size:14px;vertical-align:top}
th{width:170px;color:#556} .num{text-align:right;font-variant-numeric:tabular-nums} thead td{font-weight:600;color:#556}
li{margin:4px 0;font-size:14px} li.error{color:#b42318} li.aviso{color:#a15c00} li.ok{color:#1a7f37}
.pie{margin-top:36px;color:#667;font-size:13px;border-top:1px solid #e3e6ee;padding-top:12px}
</style></head><body>
<h1>$(Html $t.nombre) - Informe de tu PC</h1>
<div class="sub">Equipo $(Html $hw.equipo) $(if ($hw.serie) { '- serie ' + (Html $hw.serie) }) - $($fecha.ToString('dd/MM/yyyy HH:mm'))</div>
<h2>Componentes</h2><table>$equipo</table>
<h2>Pruebas de rendimiento y estabilidad</h2>
$(if ($pru) { "<table><thead><tr><td>Prueba</td><td class='num'>Puntaje Cinebench 2026</td><td class='num'>Temp. máx CPU</td><td class='num'>Temp. máx GPU</td><td class='num'>Consumo máx CPU / GPU</td><td>Resultado</td></tr></thead>$pru</table><p style='font-size:13px;color:#667'>Puntajes con la configuración de fábrica, medidos en nuestro taller. Sirven como referencia si en el futuro notás que la PC rinde menos.</p>" } else { '<p>No se realizaron pruebas.</p>' })
$uvHtml
$discosHtml
<h2>Revisión</h2><ul>$diag</ul>
$(if ($drv) { "<h2>Drivers</h2><ul>$drv</ul>" })
$(if ($prog) { "<h2>Programas instalados</h2><ul>$prog</ul>" })
$(if ($opt) { "<h2>Ajustes de Windows</h2><ul>$opt</ul>" })
<div class="pie">$(Html $t.nombre) - $(Html $t.direccion) - WhatsApp $(Html $t.whatsapp) - $(Html $t.web)</div>
</body></html>
"@
    $nombre = '{0:yyyy-MM-dd_HHmm}_{1}' -f $fecha, (($hw.serie, $hw.equipo | Where-Object { $_ -and $_ -notmatch 'default|to be filled|O\.E\.M' } | Select-Object -First 1) -replace '[^\w-]', '')
    $archHtml = Join-Path $CarpetaInformes "$nombre.html"
    $html | Set-Content -Encoding UTF8 $archHtml
    $Estado | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 (Join-Path $CarpetaInformes "$nombre.json")
    $escritorio = [Environment]::GetFolderPath('CommonDesktopDirectory')
    Copy-Item $archHtml (Join-Path $escritorio "Informe de tu PC - $($t.nombre).html") -Force
    Ok "Informe guardado en $archHtml"
    Ok 'Copia para el cliente en el escritorio.'
}

# ================================================================== REINICIO Y REANUDACIÓN
function Programar-Reanudacion {
    $accion = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$Base\aio.ps1`" -Auto -Reanudar"
    $disparo = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $ppal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $TareaReanudar -Action $accion -Trigger $disparo -Principal $ppal -Force | Out-Null
}
function Quitar-Reanudacion { Unregister-ScheduledTask -TaskName $TareaReanudar -Confirm:$false -ErrorAction SilentlyContinue }

function Reiniciar-Y-Seguir {
    Guardar-Estado
    Programar-Reanudacion
    Aviso 'Hace falta reiniciar. El script sigue solo después de iniciar sesión (Ctrl+C para cancelar).'
    for ($i = 15; $i -gt 0; $i--) { Write-Host "`r  Reiniciando en $i s...  " -NoNewline; Start-Sleep 1 }
    Stop-Transcript | Out-Null
    Restart-Computer -Force
    exit
}

# ================================================================== FINALIZAR (entrega al cliente)
function Finalizar {
    Titulo 'Finalizar: quitar herramientas de prueba'
    # Cinebench y el lector de sensores ya no hacen falta. Se conservan los informes y los registros
    # (el undervolt lo mantiene MSI Afterburner).
    foreach ($c in 'herramientas\cinebench', 'herramientas\crystaldiskinfo', 'herramientas\lhm', 'herramientas\instaladores', 'herramientas\drivers', 'herramientas\winget') {
        $p = Join-Path $Base $c
        if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue; Ok "Borrado $c" }
    }
    Get-ChildItem "$env:APPDATA\Maxon", "$env:LOCALAPPDATA\Maxon" -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'cinebench' } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem "$env:PUBLIC\Desktop", ([Environment]::GetFolderPath('Desktop')) -Filter '*Cinebench*.lnk' -ErrorAction SilentlyContinue | Remove-Item -Force
    Remove-Item $ArchivoEstado -ErrorAction SilentlyContinue
    Ok 'Cinebench quitado. La PC queda lista para entregar.'
}

# ================================================================== MODOS
function Modo-Automatico {
    if ($Reanudar) { Quitar-Reanudacion; Titulo 'Reanudando después del reinicio'; $Estado.reinicio_pendiente = $false; Guardar-Estado }
    if (-not (Paso-Hecho 'diagnostico')) { Diagnostico; Marcar-Paso 'diagnostico' }
    if (-not (Paso-Hecho 'drivers'))     { Drivers; Marcar-Paso 'drivers' }
    if (-not (Paso-Hecho 'programas'))   { Programas -Automatico; Marcar-Paso 'programas' }
    if (-not (Paso-Hecho 'optimizar'))   { Optimizar; Marcar-Paso 'optimizar' }
    if ($Estado.reinicio_pendiente -and -not (Paso-Hecho 'reinicio')) { Marcar-Paso 'reinicio'; Reiniciar-Y-Seguir }
    if (-not (Paso-Hecho 'diagnostico2')) { Diagnostico; Marcar-Paso 'diagnostico2' }   # se repite con drivers ya cargados
    if (-not (Paso-Hecho 'pruebas'))     { Pruebas; Marcar-Paso 'pruebas' }
    Informe
    Remove-Item $ArchivoEstado -ErrorAction SilentlyContinue
    Titulo 'Listo'
}

function Menu {
    while ($true) {
        Titulo "$($Cfg.taller.nombre) AIO"
        Write-Host '   1. Diagnóstico (componentes, RAM/XMP, monitor, drivers faltantes)'
        Write-Host '   2. Drivers (pendrive + Windows Update)'
        Write-Host '   3. Programas (elegir qué instalar)'
        Write-Host '   4. Optimizar Windows'
        Write-Host '   5. Pruebas de estabilidad + Cinebench 2026 (CPU y GPU)'
        Write-Host '   6. Generar informe'
        Write-Host '   7. Undervolt: probar los perfiles de MSI Afterburner y elegir uno'
        Write-Host '   8. Quitar undervolt (sacar el perfil de inicio de Afterburner)'
        Write-Host '   9. Finalizar: borrar Cinebench y herramientas de prueba (al terminar los tuneos)'
        Write-Host '   A. Todo automático'
        Write-Host '   0. Salir'
        switch ((Read-Host '  Opción').Trim().ToUpper()) {
            '1' { Diagnostico }
            '2' { Drivers }
            '3' { Programas }
            '4' { Optimizar }
            '5' { Pruebas }
            '6' { Informe }
            '7' { Undervolt-Gpu }
            '8' { UV-Revertir }
            '9' { Finalizar }
            'A' { Modo-Automatico; return }
            '0' { return }
            default { }
        }
        if ($Estado.reinicio_pendiente) { Aviso 'Hay cambios que necesitan reiniciar la PC.' }
    }
}

if ($Auto) { Modo-Automatico } else { Menu }
if ($Script:LHM) { try { $Script:LHM.Close() } catch {} }
Stop-Transcript | Out-Null
