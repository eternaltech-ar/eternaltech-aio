<#
  Undervolt con MSI Afterburner (NVIDIA y AMD).

  El ajuste lo hacés vos en Afterburner, como siempre, y guardás cada variante en un perfil (1 a 5).
  El script:
    1. Toma como referencia la prueba de GPU de fábrica (opción 5) o la mide.
    2. Aplica cada perfil guardado (MSIAfterburner.exe -ProfileN) y lo prueba con Cinebench GPU,
       registrando puntaje, consumo, temperatura y reloj.
    3. Muestra la tabla comparativa y elegís con cuál quedarte.
    4. Deja ese perfil aplicándose al iniciar Windows (sección [Startup] del perfil de la placa en
       Afterburner + tarea al iniciar sesión).
#>

$Script:UvTarea = 'EternalTech AIO - perfil Afterburner'

function AB-Exe {
    foreach ($p in "${env:ProgramFiles(x86)}\MSI Afterburner\MSIAfterburner.exe", "$env:ProgramFiles\MSI Afterburner\MSIAfterburner.exe") {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Leer-Ini($ruta) {
    $secciones = [ordered]@{}; $actual = $null
    foreach ($l in (Get-Content -LiteralPath $ruta -Encoding Default)) {
        if ($l -match '^\s*\[(.+)\]\s*$') { $actual = $Matches[1]; $secciones[$actual] = New-Object System.Collections.ArrayList; continue }
        if ($actual) { [void]$secciones[$actual].Add($l) }
    }
    return $secciones
}

function Escribir-Ini($ruta, $secciones) {
    $out = New-Object System.Collections.ArrayList
    foreach ($k in $secciones.Keys) { [void]$out.Add("[$k]"); foreach ($l in $secciones[$k]) { [void]$out.Add($l) } }
    Set-Content -LiteralPath $ruta -Value $out -Encoding Default
}

function AB-PerfilPlaca($exe, $fab) {
    # Profiles\VEN_10DE&DEV_....cfg (NVIDIA) o VEN_1002 (AMD); hay uno por placa
    $ven = if ($fab -eq 'NVIDIA') { 'VEN_10DE' } elseif ($fab -eq 'AMD') { 'VEN_1002' } else { 'VEN_' }
    Get-ChildItem (Join-Path (Split-Path $exe) 'Profiles') -Filter "$ven*.cfg" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function AB-Aplicar($exe, $n) {
    Start-Process -FilePath $exe -ArgumentList "-Profile$n"
    Start-Sleep -Seconds 8   # Afterburner tarda unos segundos en aplicar
}

function Undervolt-Gpu {
    Titulo 'Undervolt con perfiles de MSI Afterburner'
    if (-not $Estado.hardware) { $Estado.hardware = Obtener-Hardware }
    $fab = Fabricante-Gpu $Estado.hardware
    if (-not $fab) { Aviso 'No hay placa de video dedicada.'; return }
    $exe = AB-Exe
    if (-not $exe) { Falla 'MSI Afterburner no está instalado (se instala en Programas).'; return }
    $cfg = AB-PerfilPlaca $exe $fab
    if (-not $cfg) { Falla 'No encontré el perfil de la placa en Afterburner: abrilo una vez, hacé el ajuste y guardalo en un perfil.'; return }
    $ini = Leer-Ini $cfg.FullName
    $perfiles = @(1..5 | Where-Object { $ini.Contains("Profile$_") -and @($ini["Profile$_"] | Where-Object { $_ -match '=' }).Count -gt 0 })
    if ($perfiles.Count -eq 0) { Falla 'No hay perfiles guardados en Afterburner (botones 1 a 5). Guardá al menos un ajuste.'; return }
    Info "Perfiles guardados en Afterburner: $($perfiles -join ', ')"

    $ded = @($Estado.hardware.gpus | Where-Object { Es-GpuDedicada $_.nombre }) | Select-Object -First 1
    if ($ded.vram_gb -and $ded.vram_gb -lt 8) { Aviso 'Cinebench GPU pide 8 GB de VRAM o más: con esta placa no se puede usar para comparar.'; return }
    if ($fab -eq 'AMD' -and $ded.nombre -notmatch '\b9\d{3}\b') { Aviso 'Cinebench GPU en AMD solo funciona con la serie RX 9000: esta placa no se puede comparar con Cinebench.'; return }
    $cb = Ruta-Cinebench
    if (-not $cb) { Falla 'Falta Cinebench en herramientas\cinebench.'; return }
    [void](Iniciar-Sensores)
    $dur = [int]$Cfg.undervolt.duracion_prueba_seg

    # 1) referencia de fábrica
    $ref = @($Estado.pruebas | Where-Object { $_.prueba -eq 'GPU' -and $_.puntaje -and -not $_.cortada }) | Select-Object -Last 1
    if ($ref) { Info 'Referencia: la prueba de GPU de fábrica que ya se hizo (opción 5).' }
    else {
        Read-Host '  Poné la placa de fábrica en Afterburner (botón Reset y Aplicar) y apretá Enter' | Out-Null
        $ref = Prueba-Cinebench $cb 'GPU fábrica' 'g_CinebenchGpuTest' $dur
        if (-not $ref.puntaje) { Falla 'No se pudo medir la referencia de fábrica.'; return }
    }

    # 2) probar cada perfil
    $res = New-Object System.Collections.ArrayList
    foreach ($n in $perfiles) {
        Info "Aplicando perfil $n de Afterburner..."
        AB-Aplicar $exe $n
        $r = Prueba-Cinebench $cb "GPU perfil $n" 'g_CinebenchGpuTest' $dur
        $estable = [bool]($r.puntaje -and -not $r.cortada)
        [void]$res.Add([ordered]@{ perfil = $n; r = $r; estable = $estable })
        if (-not $estable) { Aviso "Perfil $n no fue estable (sin puntaje o cortado)." }
    }

    # 3) tabla y elección (recomendado: el estable con mejor puntaje por watt que no pierda más de lo permitido)
    $perdida = [double]$Cfg.undervolt.perdida_maxima_pct
    $validos = @($res | Where-Object { $_.estable -and $_.r.puntaje -ge $ref.puntaje * (1 - $perdida / 100) })
    $recom = $null
    if ($validos.Count) {
        $recom = ($validos | Sort-Object { if ($_.r.gpu_w_max) { $_.r.puntaje / $_.r.gpu_w_max } else { $_.r.puntaje } } -Descending | Select-Object -First 1).perfil
    }
    Write-Host ''
    Write-Host ('  {0,-12}{1,10}{2,10}{3,10}{4,10}{5,12}' -f 'Ajuste', 'Puntaje', 'W máx', '°C máx', 'MHz', 'Pts por W') -ForegroundColor Cyan
    $fila = { param($nom, $r, $extra)
        $ppw = if ($r.gpu_w_max) { '{0:N1}' -f ($r.puntaje / $r.gpu_w_max) } else { '--' }
        Write-Host ('  {0,-12}{1,10:N0}{2,10}{3,10}{4,10}{5,12}{6}' -f $nom, $r.puntaje, (Fmt $r.gpu_w_max ''), (Fmt $r.gpu_temp_max ''), (Fmt $r.gpu_mhz_prom ''), $ppw, $extra) }
    & $fila 'Fábrica' $ref ''
    foreach ($x in $res) {
        $extra = if (-not $x.estable) { '  INESTABLE' } elseif ($x.perfil -eq $recom) { '  <- recomendado' } else { '' }
        & $fila "Perfil $($x.perfil)" $x.r $extra
    }
    $elegido = $recom
    if (-not $Auto) {
        $msg = if ($recom) { "  ¿Con cuál nos quedamos? Número de perfil (Enter = $recom, 0 = de fábrica)" } else { '  ¿Con cuál nos quedamos? Número de perfil (0 = de fábrica)' }
        $resp = (Read-Host $msg).Trim()
        if ($resp -match '^\d$') { $elegido = [int]$resp }
    }
    if (-not $elegido -or $elegido -eq 0 -or -not ($res | Where-Object { $_.perfil -eq $elegido })) {
        UV-Revertir; Ok 'La placa queda con valores de fábrica.'; return
    }
    $x = $res | Where-Object { $_.perfil -eq $elegido } | Select-Object -First 1
    if (-not $x.estable) { Aviso "El perfil $elegido no fue estable en la prueba: igual se aplica porque lo elegiste." }

    # 4) dejarlo fijo al iniciar Windows
    AB-Aplicar $exe $elegido
    Copy-Item $cfg.FullName "$($cfg.FullName).eternaltech.bak" -Force
    $ini['Startup'] = New-Object System.Collections.ArrayList
    foreach ($l in $ini["Profile$elegido"]) { [void]$ini['Startup'].Add($l) }
    Escribir-Ini $cfg.FullName $ini
    $accion = New-ScheduledTaskAction -Execute $exe -Argument "-Profile$elegido"
    $disparo = New-ScheduledTaskTrigger -AtLogOn
    $ppal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $Script:UvTarea -Action $accion -Trigger $disparo -Principal $ppal -Force | Out-Null

    $Estado.undervolt = [ordered]@{
        herramienta = 'MSI Afterburner'; perfil = $elegido; gpu = $ded.nombre; fecha = (Get-Date).ToString('s')
        fabrica = [ordered]@{ puntaje = $ref.puntaje; w_max = $ref.gpu_w_max; temp_max = $ref.gpu_temp_max; mhz = $ref.gpu_mhz_prom }
        undervolt = [ordered]@{ puntaje = $x.r.puntaje; w_max = $x.r.gpu_w_max; temp_max = $x.r.gpu_temp_max; mhz = $x.r.gpu_mhz_prom }
        probados = @($res | ForEach-Object { [ordered]@{ perfil = $_.perfil; estable = $_.estable; puntaje = $_.r.puntaje; w_max = $_.r.gpu_w_max; temp_max = $_.r.gpu_temp_max } })
    }
    Guardar-Estado
    Ok "Perfil $elegido aplicado y configurado para iniciar con Windows."
}

function UV-Revertir {
    Unregister-ScheduledTask -TaskName $Script:UvTarea -Confirm:$false -ErrorAction SilentlyContinue
    $exe = AB-Exe
    if ($exe -and $Estado.hardware) {
        $cfg = AB-PerfilPlaca $exe (Fabricante-Gpu $Estado.hardware)
        if ($cfg) {
            $ini = Leer-Ini $cfg.FullName
            if ($ini.Contains('Startup')) { $ini.Remove('Startup'); Escribir-Ini $cfg.FullName $ini }
        }
    }
    $Estado.undervolt = $null; Guardar-Estado
    Ok 'Quitado el perfil de inicio. Si Afterburner está abierto, apretá Reset para volver a fábrica ya mismo.'
}
