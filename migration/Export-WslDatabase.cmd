@echo off
setlocal
where.exe pwsh.exe >nul 2>&1
if errorlevel 1 (
  echo PowerShell 7 is required.
  goto failed
)
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Export-WslDatabase.ps1" %*
if errorlevel 1 goto failed
echo.
echo Database export completed.
pause
exit /b 0
:failed
echo.
echo Database export failed. Read the error above before closing this window.
pause
exit /b 1
