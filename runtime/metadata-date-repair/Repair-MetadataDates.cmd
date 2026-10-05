@echo off
setlocal
where.exe pwsh.exe >nul 2>&1
if errorlevel 1 (
  echo PowerShell 7 is required. Install PowerShell 7, then try again.
  pause
  exit /b 1
)
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-MetadataDateRepair.ps1"
set "result=%errorlevel%"
echo.
pause
exit /b %result%
