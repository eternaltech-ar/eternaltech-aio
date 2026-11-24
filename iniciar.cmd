@echo off
rem EternalTech AIO - lanzador. Pide permisos de administrador y abre el script.
rem   iniciar.cmd        -> menú
rem   iniciar.cmd -Auto  -> todo automático
chcp 65001 >nul
net session >nul 2>&1
if %errorlevel% neq 0 (
  if "%~1"=="" (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  ) else (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
  )
  exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0aio.ps1" %*
pause
