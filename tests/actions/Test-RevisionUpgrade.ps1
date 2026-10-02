#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackageRoot,
    [Parameter(Mandatory)][string]$InstallRoot,
    [Parameter(Mandatory)][string]$DataRoot,
    [Parameter(Mandatory)][ValidateSet('AllUsers','CurrentUser')][string]$Scope
)
# Only for the disposable GitHub Actions install. Never simulate legacy metadata on a user's installation.
$ErrorActionPreference='Stop'
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'This destructive fixture is restricted to disposable CI installations.' }
Import-Module (Join-Path $PSScriptRoot '..\..\runtime\Common.psm1') -Force
$envFile=Join-Path $DataRoot 'immich.env'
$current=Get-CurrentReleaseTarget -InstallRoot $InstallRoot
$manifest=Get-Content -Raw (Join-Path $current 'manifest.json')|ConvertFrom-Json
$expected=[string]$manifest.packageVersion
$legacyRelease=Join-Path $InstallRoot "releases\$($manifest.immichVersion)"
& (Join-Path $current 'runtime\launchers\Stop-Immich.ps1') -InstallRoot $InstallRoot -DataRoot $DataRoot -EnvFile $envFile
[IO.Directory]::Delete((Join-Path $InstallRoot 'current'))
Move-Item -LiteralPath $current -Destination $legacyRelease
$manifest.schemaVersion=1
foreach ($key in @('packageVersion','windowsRevision','sourceCommit','nativeDependenciesSha256')) { $manifest.PSObject.Properties.Remove($key) }
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

& (Join-Path $PackageRoot 'installer\Update.ps1') -PackageRoot $PackageRoot -Scope $Scope -InstallRoot $InstallRoot -DataRoot $DataRoot
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
