@echo off
setlocal
set "installScript=%~dp0installer\Install.ps1"
where.exe pwsh.exe >nul 2>&1
if errorlevel 1 (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%installScript%" %*
) else (
  pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%installScript%" %*
)
set "result=%errorlevel%"
echo.
if not "%result%"=="0" echo Installation failed with exit code %result%.
pause
exit /b %result%
