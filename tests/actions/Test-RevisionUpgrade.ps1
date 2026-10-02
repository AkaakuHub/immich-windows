#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackageRoot,
    [Parameter(Mandatory)][string]$InstallRoot,
    [Parameter(Mandatory)][string]$DataRoot,
    [Parameter(Mandatory)][ValidateSet('AllUsers','CurrentUser')][string]$Scope,
    [switch]$UseLegacyMachineLearning
)
# Only for the disposable GitHub Actions install. Never simulate legacy metadata on a user's installation.
$ErrorActionPreference='Stop'
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'This destructive fixture is restricted to disposable CI installations.' }
Import-Module (Join-Path $PSScriptRoot '..\..\runtime\Common.psm1') -Force
function Assert-TrayRegistration {
    $entry=Get-ImmichTrayEntry -InstallRoot $InstallRoot -DataRoot $DataRoot -Scope $Scope
    $path=Join-Path ([Environment]::GetFolderPath('Startup')) ($entry.Name+'.lnk')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing tray startup shortcut: $path" }
    $shortcut=Read-ImmichShortcut $path
    if ($shortcut.IconLocation -ine $entry.IconLocation -or $shortcut.TargetPath -ine $entry.TargetPath -or $shortcut.Arguments -cne $entry.Arguments) { throw 'Tray startup does not use the expected icon, paths and scope.' }
    $programs=[Environment]::GetFolderPath($(if ($Scope -eq 'AllUsers') { 'CommonPrograms' } else { 'Programs' }))
    foreach ($name in Get-ImmichManagedShortcutNames) {
        if (Test-Path -LiteralPath (Join-Path $programs "Immich\$name.lnk")) { throw 'An unwanted legacy Start-menu shortcut remains.' }
    }
    $check=Start-Process -FilePath $entry.TargetPath -ArgumentList ($entry.Arguments+' --check') -Wait -PassThru
    if ($check.ExitCode -ne 0) { throw "Installed tray validation failed (exit $($check.ExitCode))." }
    Write-Host "Tray startup verified for ${Scope}: upstream icon, all four actions, no legacy Start-menu entries."
}
Assert-TrayRegistration
# Simulate exactly the managed legacy entries; the update must remove them and
# leave a user's unrelated shortcut alone.
$legacyMenu=Join-Path ([Environment]::GetFolderPath($(if ($Scope -eq 'AllUsers') { 'CommonPrograms' } else { 'Programs' }))) 'Immich'
New-Item -ItemType Directory $legacyMenu -Force | Out-Null
foreach ($name in Get-ImmichManagedShortcutNames) { Set-Content (Join-Path $legacyMenu "$name.lnk") 'managed legacy fixture' }
$unrelated=Join-Path $legacyMenu 'My own shortcut.lnk'
Set-Content $unrelated 'user fixture'
$envFile=Join-Path $DataRoot 'immich.env'
$current=Get-CurrentReleaseTarget -InstallRoot $InstallRoot
$manifest=Get-Content -Raw (Join-Path $current 'manifest.json')|ConvertFrom-Json
$expected=[string]$manifest.packageVersion
$legacyRelease=Join-Path $InstallRoot "releases\$($manifest.immichVersion)"
& (Join-Path $current 'runtime\launchers\Stop-Immich.ps1') -InstallRoot $InstallRoot -DataRoot $DataRoot -EnvFile $envFile
[IO.Directory]::Delete((Join-Path $InstallRoot 'current'))
Move-Item -LiteralPath $current -Destination $legacyRelease
if ($UseLegacyMachineLearning) {
    # Exact requirements from the SHA256-verified official v3.2.2 application release.
    $legacyRequirements=Join-Path $PSScriptRoot '..\fixtures\ml-requirements-v3.2.2.txt'
    if ((Get-FileHash -Algorithm SHA256 $legacyRequirements).Hash -ine '7f38dea075b3b6fd61e318be07c6a2425363a33192bc38c9c22b81078f1b2a03') { throw 'Legacy ML fixture changed.' }
    $legacyPython=Get-ChildItem (Join-Path $legacyRelease 'machine-learning\python-runtime') -Filter python.exe -File -Recurse |
        Where-Object { $_.FullName -notmatch '\\Scripts\\' } | Select-Object -First 1
    $uv=Join-Path $InstallRoot "tools\uv\$($manifest.dependencies.uv.version)\uv.exe"
    & $uv pip sync $legacyRequirements --python $legacyPython.FullName --system --break-system-packages --cache-dir (Join-Path $InstallRoot 'cache\uv')
    if ($LASTEXITCODE -ne 0) { throw 'Could not prepare the actual legacy CPU ML dependencies.' }
    Copy-Item -LiteralPath $legacyRequirements -Destination (Join-Path $legacyRelease 'machine-learning\requirements.txt') -Force
    & $legacyPython.FullName -I -c 'import onnxruntime; assert onnxruntime.__version__ == "1.26.0"'
    if ($LASTEXITCODE -ne 0) { throw 'Legacy CPU ONNX Runtime fixture is invalid.' }
}
$manifest.schemaVersion=1
foreach ($key in @('packageVersion','windowsRevision','sourceCommit','nativeDependenciesSha256','nativeDependencyFiles','nativeDependencyMetadata')) { $manifest.PSObject.Properties.Remove($key) }
$manifest | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $legacyRelease 'manifest.json') -Encoding utf8
Set-CurrentReleaseJunction -InstallRoot $InstallRoot -ReleasePath $legacyRelease
$envs=Read-EnvFile $envFile
$envs['IMMICH_WINDOWS_TEST_PRESERVE']='value=with spaces'
$envs['IMMICH_HOST']='127.0.0.1'
Write-EnvFile -Path $envFile -Values $envs
& (Join-Path $legacyRelease 'runtime\launchers\Start-Immich.ps1') -InstallRoot $InstallRoot -DataRoot $DataRoot -EnvFile $envFile

# The new updater must use its own fixed shutdown code, not depend on legacy launcher behavior.
Set-Content (Join-Path $legacyRelease 'runtime/launchers/Stop-Immich.ps1') "throw 'Legacy shutdown code must not be used by the new updater.'"

# Incomplete candidate must fail before shutdown or any DB/config mutation.
$invalid=Join-Path $env:RUNNER_TEMP ("invalid-candidate-"+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $invalid | Out-Null
Copy-Item (Join-Path $PackageRoot 'manifest.json') $invalid
try {
    $rejected=$false
    try { & (Join-Path $PackageRoot 'installer\Update.ps1') -PackageRoot $invalid -Scope $Scope -InstallRoot $InstallRoot -DataRoot $DataRoot } catch { $rejected=$true }
    if (-not $rejected) { throw 'Incomplete candidate was accepted.' }
    if ((Get-CurrentReleaseTarget $InstallRoot) -ne $legacyRelease) { throw 'Invalid candidate changed the active release.' }
    Wait-HttpOk -Uri "http://127.0.0.1:$($envs['IMMICH_PORT'])/api/server/ping" -TimeoutSeconds 10
} finally { Remove-Item -LiteralPath $invalid -Recurse -Force }

# Build provenance differs across real releases even when all runtime DLLs are identical.
# Legacy installers did not update Sharp versions.json after DLL injection.
Set-Content (Join-Path $legacyRelease 'server\node_modules\@img\sharp-win32-x64\versions.json') '{"vips":"legacy-stock-metadata"}'
$oldVcMetadata=Join-Path $legacyRelease 'runtime\vc-runtime\vc-runtime.json'
@{source='old-build-machine';builtAtUtc='2026-01-01T00:00:00Z'} | ConvertTo-Json | Set-Content $oldVcMetadata
# A legacy installation need not retain archive/package caches. It must still reuse installed payloads.
$cacheBackups = @{}
$oldUvOffline = $env:UV_OFFLINE
$oldNpmOffline = $env:npm_config_offline
if (-not $UseLegacyMachineLearning) { $env:UV_OFFLINE = '1' }
$env:npm_config_offline = 'true'
function global:Invoke-WebRequest {
    param([uri]$Uri,[switch]$UseBasicParsing,[int]$TimeoutSec,[string]$OutFile)
    if ($Uri.Scheme -ne 'http' -or -not $Uri.IsLoopback) { throw "Unexpected dependency download during identical-payload update: $Uri" }
    Microsoft.PowerShell.Utility\Invoke-WebRequest @PSBoundParameters
}
try {
    $cacheNames=if ($UseLegacyMachineLearning) { @() } else { @('downloads','uv','pnpm-store','npm') }
    foreach ($name in $cacheNames) {
        $path=Join-Path $InstallRoot "cache\$name"
        if (Test-Path -LiteralPath $path) {
            $saved="$path.reuse-test"
            Move-Item -LiteralPath $path -Destination $saved
            $cacheBackups[$path]=$saved
        }
    }
    # Simulate the old coarse completion marker; reuse must compare actual dependency inputs.
    @{immichVersion=$manifest.immichVersion;node=$manifest.dependencies.node.version;pnpm=$manifest.dependencies.pnpm.version} |
        ConvertTo-Json | Set-Content (Join-Path $legacyRelease '.node-dependencies-installed.json')
    # Actual v3.2.2 shipped this two-field ML completion marker (no requirementsSha256).
    @{immichVersion=$manifest.immichVersion;python=$manifest.dependencies.python.version} |
        ConvertTo-Json | Set-Content (Join-Path $legacyRelease 'machine-learning\.dependencies-installed.json')
    $transcript=Join-Path $env:RUNNER_TEMP ("reuse-"+[guid]::NewGuid().ToString('N')+'.log')
    Start-Transcript -Path $transcript | Out-Null
    try { & (Join-Path $PackageRoot 'installer\Update.ps1') -PackageRoot $PackageRoot -Scope $Scope -InstallRoot $InstallRoot -DataRoot $DataRoot }
    finally { Stop-Transcript | Out-Null }
    $text=Get-Content -Raw -LiteralPath $transcript
    foreach ($message in @('Reused installed node runtime','Reused installed ffmpeg runtime','Reused installed Python runtime',
        'Reused installed server Node packages','Reused installed cli Node packages','Reused installed Machine Learning packages')) {
        if (-not $text.Contains($message)) { throw "Missing dependency reuse evidence: $message" }
    }
    if ($UseLegacyMachineLearning) { Write-Host 'Actual legacy CPU ML requirements upgraded to DirectML dependencies successfully.' }
    else { Write-Host 'Empty-cache legacy update reused installed dependencies without network acquisition.' }
} finally {
    Remove-Item Function:\Invoke-WebRequest -ErrorAction SilentlyContinue
    $env:UV_OFFLINE=$oldUvOffline
    $env:npm_config_offline=$oldNpmOffline
    foreach ($path in $cacheBackups.Keys) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
        Move-Item -LiteralPath $cacheBackups[$path] -Destination $path
    }
}
$updated=Get-CurrentReleaseTarget $InstallRoot
$updatedManifest=Get-Content -Raw (Join-Path $updated 'manifest.json')|ConvertFrom-Json
if ($updatedManifest.packageVersion -ne $expected) { throw 'Update did not activate the requested Windows revision.' }
$after=Read-EnvFile $envFile
foreach ($key in @('IMMICH_WINDOWS_TEST_PRESERVE','IMMICH_HOST','DB_PASSWORD','IMMICH_MEDIA_LOCATION','MACHINE_LEARNING_ACCELERATOR','MACHINE_LEARNING_DEVICE_ID')) {
    if ([string]$after[$key] -cne [string]$envs[$key]) { throw "Update changed persistent setting: $key" }
}
$state=Get-Content -Raw (Join-Path $DataRoot 'state\upgrade-recovery.json')|ConvertFrom-Json
if ($state.status -ne 'qualified' -or -not $state.databaseUnchanged -or $state.databaseBackup) { throw 'An identical server/DB payload must update without an extra database dump.' }
if (-not (Test-Path (Join-Path $legacyRelease 'manifest.json'))) { throw 'Update overwrote the legacy release.' }
$rejected=$false
try { & (Join-Path $PackageRoot 'installer\Update.ps1') -PackageRoot $PackageRoot -Scope $Scope -InstallRoot $InstallRoot -DataRoot $DataRoot } catch { $rejected=$true }
if (-not $rejected) { throw 'Equal-version update was accepted.' }
Wait-HttpOk -Uri "http://127.0.0.1:$($after['IMMICH_PORT'])/api/server/ping" -TimeoutSeconds 10
Write-Host "Running $Scope installation: legacy-to-revision update, config preservation, invalid/equal-version rejection passed."

Assert-TrayRegistration
if (-not (Test-Path -LiteralPath $unrelated)) { throw 'Legacy menu cleanup removed a user-owned shortcut.' }
Remove-Item -LiteralPath $unrelated
