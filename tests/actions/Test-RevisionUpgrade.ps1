#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackageRoot,
    [Parameter(Mandatory)][string]$InstallRoot,
    [Parameter(Mandatory)][string]$DataRoot,
    [Parameter(Mandatory)][ValidateSet('AllUsers','CurrentUser')][string]$Scope,
    [Parameter(Mandatory)][string]$BaselinePackageRoot,
    [string[]]$SharpFixture = @(),
    [switch]$TestMachineLearningLifecycle
)
# Only for disposable GitHub Actions installs of a SHA-256 verified prior release.
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
$envFile=Join-Path $DataRoot 'immich.env'
$previousRelease=Get-CurrentReleaseTarget -InstallRoot $InstallRoot
$manifest=Get-Content -Raw (Join-Path $previousRelease 'manifest.json') | ConvertFrom-Json
$candidate=Get-Content -Raw (Join-Path $PackageRoot 'manifest.json') | ConvertFrom-Json
$expected=[string]$candidate.packageVersion
$previousVersion=Get-WindowsPackageVersion $manifest
$candidateVersion=Get-WindowsPackageVersion $candidate
if ($previousVersion -ge $candidateVersion) { throw 'The running baseline must be an authentic older released package, not a relabeled candidate.' }
# Verify the installed source bytes against the immutable released extraction,
# including ML requirements. Installation may inject native libraries separately.
foreach ($relative in @('manifest.json','server/package.json','server/dist/main.js','machine-learning/requirements.txt','machine-learning/app/immich_ml/__main__.py')) {
    $installedHash=(Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $previousRelease $relative)).Hash
    $releasedHash=(Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $BaselinePackageRoot $relative)).Hash
    if ($installedHash -cne $releasedHash) { throw "Running baseline differs from the verified release: $relative" }
}
$upstreamChanged=[string]$manifest.immichVersion -cne [string]$candidate.immichVersion
$envs=Read-EnvFile $envFile
$envs['IMMICH_WINDOWS_TEST_PRESERVE']='value=with spaces'
$envs['IMMICH_HOST']='127.0.0.1'
Write-EnvFile -Path $envFile -Values $envs
$lifecycleOriginalEnv = if ($TestMachineLearningLifecycle) { [IO.File]::ReadAllBytes($envFile) } else { $null }
$lifecycleProcessEnv = @{}
try {
if ($TestMachineLearningLifecycle) {
    # The real updater will start a fresh worker with these disposable settings.
    # Its smoke only pings ML; it does not mark the worker as prediction-used.
    $lifecycleSettings = Read-EnvFile $envFile
    foreach ($key in @('MACHINE_LEARNING_MODEL_TTL','MACHINE_LEARNING_MODEL_TTL_POLL_S','MACHINE_LEARNING_WORKERS')) {
        $lifecycleProcessEnv[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        $lifecycleSettings[$key] = '1'
    }
    Write-EnvFile -Path $envFile -Values $lifecycleSettings
}
# The baseline has already started and migrated its own separate disposable DB.
Wait-HttpOk -Uri "http://127.0.0.1:$($envs['IMMICH_PORT'])/api/server/ping" -TimeoutSeconds 10

# Simulate only managed legacy menu entries, without changing package identity.
$legacyMenu=Join-Path ([Environment]::GetFolderPath($(if ($Scope -eq 'AllUsers') { 'CommonPrograms' } else { 'Programs' }))) 'Immich'
New-Item -ItemType Directory $legacyMenu -Force | Out-Null
foreach ($name in Get-ImmichManagedShortcutNames) { Set-Content (Join-Path $legacyMenu "$name.lnk") 'managed legacy fixture' }
$unrelated=Join-Path $legacyMenu 'My own shortcut.lnk'
Set-Content $unrelated 'user fixture'

# The new updater must use its own fixed shutdown code, not depend on legacy launcher behavior.
Set-Content (Join-Path $previousRelease 'runtime/launchers/Stop-Immich.ps1') "throw 'Legacy shutdown code must not be used by the new updater.'"

# Incomplete candidate must fail before shutdown or any DB/config mutation.
$invalid=Join-Path $env:RUNNER_TEMP ("invalid-candidate-"+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $invalid | Out-Null
Copy-Item (Join-Path $PackageRoot 'manifest.json') $invalid
try {
    $rejected=$false
    try { & (Join-Path $PackageRoot 'installer\Update.ps1') -PackageRoot $invalid -Scope $Scope -InstallRoot $InstallRoot -DataRoot $DataRoot } catch { $rejected=$true }
    if (-not $rejected) { throw 'Incomplete candidate was accepted.' }
    if ((Get-CurrentReleaseTarget $InstallRoot) -ne $previousRelease) { throw 'Invalid candidate changed the active release.' }
    Wait-HttpOk -Uri "http://127.0.0.1:$($envs['IMMICH_PORT'])/api/server/ping" -TimeoutSeconds 10
} finally { Remove-Item -LiteralPath $invalid -Recurse -Force }

# Upstream changes may require new Node/ML/native inputs, so allow their normal
# acquisition. Offline identical-input reuse has separate focused test coverage.
$global:LASTEXITCODE=0
# This is the freshly downloaded Install.cmd entrypoint. Its saved-env routing
# must use the candidate updater even when the old wrapper rejects revision zero.
& (Join-Path $PackageRoot 'installer/Install.ps1') -PackageRoot $PackageRoot -Scope $Scope -InstallRoot $InstallRoot -DataRoot $DataRoot
if ($LASTEXITCODE -ne 0) { throw 'The authentic baseline bootstrap upgrade failed.' }
$updated=Get-CurrentReleaseTarget $InstallRoot
$updatedManifest=Get-Content -Raw (Join-Path $updated 'manifest.json')|ConvertFrom-Json
if ($updatedManifest.packageVersion -ne $expected) { throw 'Update did not activate the requested Windows revision.' }
$after=Read-EnvFile $envFile
foreach ($key in @('IMMICH_WINDOWS_TEST_PRESERVE','IMMICH_WINDOWS_INSTALL_SCOPE','IMMICH_HOST','DB_HOSTNAME','DB_PORT','DB_DATABASE_NAME','DB_USERNAME','DB_PASSWORD','IMMICH_MEDIA_LOCATION','POSTGRES_ROOT','POSTGRES_SERVICE','MACHINE_LEARNING_ACCELERATOR','MACHINE_LEARNING_DEVICE_ID')) {
    if ([string]$after[$key] -cne [string]$envs[$key]) { throw "Update changed persistent setting: $key" }
}
$state=Get-Content -Raw (Join-Path $DataRoot 'state\upgrade-recovery.json')|ConvertFrom-Json
if ($state.status -ne 'qualified') { throw 'The baseline upgrade did not qualify.' }
if ($upstreamChanged -and ($state.databaseUnchanged -or -not $state.databaseBackup -or -not (Test-Path -LiteralPath $state.databaseBackup -PathType Leaf))) {
    throw 'A cross-upstream upgrade must retain its real pre-migration database backup.'
}
if ($state.databaseUnchanged -and $state.databaseBackup) { throw 'An identical DB payload must not create an unnecessary database dump.' }
if ($state.previousVersion -cne "v$previousVersion" -or $state.candidateVersion -cne "v$candidateVersion") { throw 'Upgrade evidence does not match the actual baseline and candidate.' }
if (Test-Path -LiteralPath $previousRelease) { throw 'Successful tray replacement must allow obsolete application cleanup.' }
$rejected=$false
try { & (Join-Path $PackageRoot 'installer\Update.ps1') -PackageRoot $PackageRoot -Scope $Scope -InstallRoot $InstallRoot -DataRoot $DataRoot } catch { $rejected=$true }
if (-not $rejected) { throw 'Equal-version update was accepted.' }
Wait-HttpOk -Uri "http://127.0.0.1:$($after['IMMICH_PORT'])/api/server/ping" -TimeoutSeconds 10
Write-Host "Running $Scope installation: $previousVersion -> $candidateVersion upgrade, config preservation, invalid/equal-version rejection and cleanup passed."

Assert-TrayRegistration
if (-not (Test-Path -LiteralPath $unrelated)) { throw 'Legacy menu cleanup removed a user-owned shortcut.' }
Remove-Item -LiteralPath $unrelated
if ($SharpFixture.Count) {
    & (Join-Path $PSScriptRoot 'Test-InstalledMediaFixtures.ps1') -ReleaseRoot $updated -Fixture $SharpFixture
}
if ($TestMachineLearningLifecycle) {
    & (Join-Path $PSScriptRoot 'Test-MachineLearningLifecycle.ps1') -InstallRoot $InstallRoot -DataRoot $DataRoot -UseRunningConfiguration -LeaveStopped
}
} finally {
    if ($null -ne $lifecycleOriginalEnv) { [IO.File]::WriteAllBytes($envFile, $lifecycleOriginalEnv) }
    foreach ($key in $lifecycleProcessEnv.Keys) {
        if ($null -eq $lifecycleProcessEnv[$key]) { Remove-Item "Env:$key" -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($key, $lifecycleProcessEnv[$key], 'Process') }
    }
}
