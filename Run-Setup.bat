@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-MyPC.ps1"
if errorlevel 1 echo Setup finished with a warning or error. Review the Logs folder.
pause
endlocal
