@echo off
where pwsh.exe >nul 2>nul
if errorlevel 1 (
  echo PowerShell 7 is required. Install PowerShell 7 and try again.
  pause
  exit /b 1
)
start "" pwsh.exe -NoProfile -STA -WindowStyle Hidden -File "%~dp0Start.ps1"
