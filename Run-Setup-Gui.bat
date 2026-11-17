@echo off
setlocal
cd /d "%~dp0"
start "" powershell.exe -NoProfile -Sta -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0Install-MyPC.Gui.ps1"
endlocal
