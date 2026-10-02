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
function Assert-StartMenu {
    param([string]$Culture=[Globalization.CultureInfo]::CurrentUICulture.Name)
    $programs=[Environment]::GetFolderPath($(if ($Scope -eq 'AllUsers') { 'CommonPrograms' } else { 'Programs' }))
    $directory=Join-Path $programs 'Immich'
    $entries=@(Get-ImmichStartMenuEntries -InstallRoot $InstallRoot -DataRoot $DataRoot -Scope $Scope -Culture $Culture)
    foreach ($entry in $entries) {
        $path=Join-Path $directory "$($entry.Name).lnk"
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing Start menu shortcut: $path" }
        $shortcut=Read-ImmichShortcut $path
        if ($shortcut.IconLocation -ine $entry.IconLocation -or -not (Test-Path -LiteralPath (Join-Path $InstallRoot 'current\build\www\favicon.ico'))) { throw "Invalid Immich icon: $path" }
        if ($shortcut.TargetPath -ine $entry.TargetPath -or $shortcut.Arguments -cne $entry.Arguments) { throw "Incorrect shortcut launch command: $path" }
    }
    foreach ($name in (Get-ImmichManagedShortcutNames | Where-Object { $_ -notin $entries.Name })) {
        if (Test-Path -LiteralPath (Join-Path $directory "$name.lnk")) { throw "Obsolete localized shortcut was not removed: $name" }
    }
    Write-Host "Start menu verified for ${Scope}: four shortcuts using upstream Immich icon."
}
Assert-StartMenu
foreach ($culture in @('ja-JP','en-US',[Globalization.CultureInfo]::CurrentUICulture.Name)) {
    Set-ImmichStartMenu -InstallRoot $InstallRoot -DataRoot $DataRoot -Scope $Scope -Culture $culture
    Assert-StartMenu -Culture $culture
}
$envFile=Join-Path $DataRoot 'immich.env'
$current=Get-CurrentReleaseTarget -InstallRoot $InstallRoot
$manifest=Get-Content -Raw (Join-Path $current 'manifest.json')|ConvertFrom-Json
$expected=[string]$manifest.packageVersion
$legacyRelease=Join-Path $InstallRoot "releases\$($manifest.immichVersion)"
& (Join-Path $current 'runtime\launchers\Stop-Immich.ps1') -InstallRoot $InstallRoot -DataRoot $DataRoot -EnvFile $envFile
[IO.Directory]::Delete((Join-Path $InstallRoot 'current'))
Move-Item -LiteralPath $current -Destination $legacyRelease
$manifest.schemaVersion=1
foreach ($key in @('packageVersion','windowsRevision','sourceCommit','nativeDependenciesSha256','nativeDependencyFiles')) { $manifest.PSObject.Properties.Remove($key) }
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

# A legacy installation need not retain archive/package caches. It must still reuse installed payloads.
$cacheBackups = @{}
$oldUvOffline = $env:UV_OFFLINE
$oldNpmOffline = $env:npm_config_offline
$env:UV_OFFLINE = '1'
$env:npm_config_offline = 'true'
function global:Invoke-WebRequest { throw 'Unexpected dependency download during identical-payload update.' }
try {
    foreach ($name in @('downloads','uv','pnpm-store','npm')) {
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
    $transcript=Join-Path $env:RUNNER_TEMP ("reuse-"+[guid]::NewGuid().ToString('N')+'.log')
    Start-Transcript -Path $transcript | Out-Null
    try { & (Join-Path $PackageRoot 'installer\Update.ps1') -PackageRoot $PackageRoot -Scope $Scope -InstallRoot $InstallRoot -DataRoot $DataRoot }
    finally { Stop-Transcript | Out-Null }
    $text=Get-Content -Raw -LiteralPath $transcript
    foreach ($message in @('Reused installed node runtime','Reused installed ffmpeg runtime','Reused installed Python runtime',
        'Reused installed server Node packages','Reused installed cli Node packages','Reused installed Machine Learning packages')) {
        if (-not $text.Contains($message)) { throw "Missing dependency reuse evidence: $message" }
    }
    Write-Host 'Empty-cache legacy update reused installed dependencies without network acquisition.'
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

Assert-StartMenu
