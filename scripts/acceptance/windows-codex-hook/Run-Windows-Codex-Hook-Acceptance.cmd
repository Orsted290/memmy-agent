@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Run-Windows-Codex-Hook-Acceptance.ps1" %*
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" pause
exit /b %RESULT%
