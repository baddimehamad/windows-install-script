@echo off
setlocal
cd /d "%~dp0"

rem Window by default. Pass "console" to use the text menu instead.
if /i "%~1"=="console" goto console
if /i "%~1"=="/console" goto console
if /i "%~1"=="-console" goto console

if not exist "%~dp0Install-MyPC.Gui.ps1" goto console
start "" powershell.exe -NoProfile -Sta -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0Install-MyPC.Gui.ps1"
endlocal
exit /b 0

:console
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-MyPC.ps1"
if errorlevel 1 echo Setup finished with a warning or error. Review the Logs folder.
pause
endlocal
