@echo off
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if /i "%~1"=="debug" goto debug
start "" "%PS%" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0MRU-Layout.ps1"
exit /b
:debug
"%PS%" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0MRU-Layout.ps1"
pause
