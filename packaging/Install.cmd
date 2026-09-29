@echo off
setlocal
where.exe pwsh.exe >nul 2>&1
if errorlevel 1 (
  echo PowerShell 7 is required. Install it, then run Install.cmd again.
  echo https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows
  pause
  exit /b 1
)
set "immichVersion=__IMMICH_VERSION__"
set "IMMICH_BOOTSTRAP_STAGE=%TEMP%\immich-bootstrap-%RANDOM%-%RANDOM%"
echo Downloading Immich %immichVersion% for Windows.
pwsh.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $version=$env:immichVersion; if($version -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+$'){throw 'Invalid installer version.'}; $folder='immich-windows-'+$version+'-win-x64'; $stage=$env:IMMICH_BOOTSTRAP_STAGE; if(Test-Path -LiteralPath $stage){throw 'Installer staging directory already exists.'}; New-Item -ItemType Directory -Path $stage | Out-Null; $archive=Join-Path $stage ($folder+'.zip'); Invoke-WebRequest -Uri ('https://github.com/AkaakuHub/immich-windows/releases/download/'+$version+'/'+$folder+'.zip') -OutFile $archive; Expand-Archive -LiteralPath $archive -DestinationPath $stage; $package=Join-Path $stage $folder; & (Join-Path $package 'installer\Test-ReleasePackage.ps1') -PackageRoot $package -Version $version"
if errorlevel 1 goto failed
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%IMMICH_BOOTSTRAP_STAGE%\immich-windows-%immichVersion%-win-x64\installer\Install.ps1" %*
set "result=%errorlevel%"
goto finish
:failed
set "result=%errorlevel%"
:finish
pwsh.exe -NoProfile -Command "$stage=[IO.Path]::GetFullPath($env:IMMICH_BOOTSTRAP_STAGE); $parent=[IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($env:TEMP)); if([IO.Path]::GetDirectoryName($stage) -ine $parent -or [IO.Path]::GetFileName($stage) -notmatch '^immich-bootstrap-[0-9]+-[0-9]+$'){throw 'Invalid installer staging path.'}; if(Test-Path -LiteralPath $stage){Remove-Item -LiteralPath $stage -Recurse -Force}"
echo.
if not "%result%"=="0" echo Installation failed with exit code %result%.
pause
exit /b %result%
