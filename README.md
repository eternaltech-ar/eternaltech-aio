# EternalTech AIO

Script para preparar, probar y optimizar las PCs que arma EternalTech (Windows 10 y 11).

## Uso rápido

PowerShell **como administrador**:

```powershell
irm https://raw.githubusercontent.com/eternaltech-ar/eternaltech-aio/main/instalar.ps1 | iex
```

Baja la última versión a `C:\EternalTech\AIO` y abre el menú. Para el modo automático, desde esa carpeta: `automatico.cmd`.

También funciona desde un pendrive: copiar el repositorio y ejecutar `iniciar.cmd`.

## Qué hace

1. Diagnóstico: componentes, RAM sin XMP/EXPO, monitor en el video integrado, Hz, drivers faltantes, discos con CrystalDiskInfo, activación, TPM.
2. Drivers: `.inf` del pendrive, instaladores de chipset/video y Windows Update.
3. Programas: Office (Microsoft 365 Apps), HWiNFO, MSI Afterburner + RivaTuner (solo con placa dedicada y no notebook) y los que se elijan (winget).
4. Optimización de Windows.
5. Cinebench 2026 CPU y GPU con valores de fábrica, con registro de temperaturas.
6. Informe HTML para el cliente.
7. Undervolt: prueba los perfiles guardados en MSI Afterburner y deja el elegido al inicio.
9. Finalizar: borra Cinebench y las herramientas de prueba.

Detalle completo en `LEEME.txt`. Configuración en `config.json`.

## Herramientas que no están en el repositorio

Por licencia, se agregan aparte en `herramientas\` (o se descargan si hay URL en `config.json`):

- `cinebench\` — Cinebench 2026 (maxon.net)
- `lhm\` — LibreHardwareMonitor (versión net472)
- `crystaldiskinfo\` — CrystalDiskInfo portable (si falta, se instala con winget)
- `drivers\`, `instaladores\`, `winget\` — opcionales
