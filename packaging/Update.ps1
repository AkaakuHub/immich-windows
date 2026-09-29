#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackageRoot,
    [ValidateSet('AllUsers','CurrentUser')][string]$Scope='AllUsers',
    [string]$InstallRoot,
    [string]$DataRoot,
    [string]$PostgresRoot='C:\Program Files\PostgreSQL\18',
    [string]$PostgresService='postgresql-x64-18'
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\runtime\Common.psm1') -Force
if ($Scope -eq 'AllUsers') {
    Assert-Administrator
}
$paths=Resolve-ImmichInstallPaths -Scope $Scope -InstallRoot $InstallRoot -DataRoot $DataRoot
$InstallRoot=$paths.InstallRoot
$DataRoot=$paths.DataRoot

$PackageRoot=(Resolve-Path -LiteralPath $PackageRoot).Path
$previousRelease=Get-CurrentReleaseTarget -InstallRoot $InstallRoot
if(-not $previousRelease -or -not(Test-Path -LiteralPath $previousRelease -PathType Container)){
    throw 'A valid existing current Immich release is required for an in-place update.'
}

$envFile=Join-Path $DataRoot 'immich.env'
$installedEnv=Read-EnvFile $envFile
if ($installedEnv.IMMICH_WINDOWS_INSTALL_SCOPE -ne $Scope) { throw 'The selected scope does not match the installed environment.' }
$previousManifest=Get-Content -Raw -LiteralPath (Join-Path $previousRelease 'manifest.json')|ConvertFrom-Json
$candidateManifest=Get-Content -Raw -LiteralPath (Join-Path $PackageRoot 'manifest.json')|ConvertFrom-Json
if($previousManifest.immichVersion -eq $candidateManifest.immichVersion){
    throw "Refusing an in-place update to the same Immich version $($candidateManifest.immichVersion). Use Install.ps1 only for an intentional reinstall."
}
if ([version]$candidateManifest.immichVersion.TrimStart('v') -lt [version]$previousManifest.immichVersion.TrimStart('v')) { throw 'Use paired backup recovery to restore a previous version; downgrading an existing database is not supported.' }

$stateDirectory=Join-Path $DataRoot 'state'
New-Item -ItemType Directory -Path $stateDirectory -Force|Out-Null
$stateFile=Join-Path $stateDirectory 'upgrade-recovery.json'
$state=[ordered]@{
    schemaVersion=1
    status='preparing'
    previousRelease=$previousRelease
    previousVersion=[string]$previousManifest.immichVersion
    candidatePackageRoot=$PackageRoot
    candidateRelease=$null
    candidateVersion=[string]$candidateManifest.immichVersion
    databaseBackup=$null
    startedAtUtc=[DateTime]::UtcNow.ToString('o')
    completedAtUtc=$null
    failure=$null
}
function Save-UpgradeState {
    $state|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $stateFile -Encoding utf8
}
Save-UpgradeState

$stopScript=Join-Path $InstallRoot 'current\runtime\launchers\Stop-Immich.ps1'
$backup=$null
try {
& $stopScript -EnvFile $envFile -DataRoot $DataRoot -InstallRoot $InstallRoot
$backup=& (Join-Path $PSScriptRoot '..\migration\New-DatabaseBackup.ps1') -EnvFile $envFile -PostgresRoot $PostgresRoot
$backup=@($backup)[-1]
if(-not(Test-Path -LiteralPath $backup -PathType Leaf)){throw "Pre-upgrade database backup was not created: $backup"}
$state.databaseBackup=$backup
$state.status='backup-created'
Save-UpgradeState
Write-Host "Pre-upgrade database backup: $backup"

    & (Join-Path $PSScriptRoot 'Install.ps1') `
        -PackageRoot $PackageRoot `
        -Scope $Scope `
        -EnvFile $envFile `
        -InstallRoot $InstallRoot `
        -DataRoot $DataRoot `
        -PostgresRoot $PostgresRoot `
        -PostgresService $PostgresService `
        -ReuseServices `
        -DoNotStart

    $state.candidateRelease=Get-CurrentReleaseTarget -InstallRoot $InstallRoot
    $state.status='candidate-installed'
    Save-UpgradeState

    & (Join-Path $InstallRoot 'current\runtime\launchers\Start-Immich.ps1') -EnvFile $envFile -InstallRoot $InstallRoot -DataRoot $DataRoot
    & (Join-Path $InstallRoot 'current\tests\Smoke-Windows.ps1') -InstallRoot $InstallRoot -DataRoot $DataRoot -PostgresRoot $PostgresRoot

    $state.status='qualified'
    $state.completedAtUtc=[DateTime]::UtcNow.ToString('o')
    Save-UpgradeState
    Write-Host "Upgrade qualified: $($state.previousVersion) -> $($state.candidateVersion)"
    Write-Host "Paired rollback backup retained at: $backup"
} catch {
    $failure=$_
    $state.status='failed'
    $state.completedAtUtc=[DateTime]::UtcNow.ToString('o')
    $state.failure=$failure.Exception.ToString()
    Save-UpgradeState
    try { & $stopScript -EnvFile $envFile -DataRoot $DataRoot -InstallRoot $InstallRoot }
    catch { Write-Warning "Immich shutdown also failed: $($_.Exception.Message)" }
    throw "Upgrade failed. Recovery state: $stateFile. Database backup: $backup. $($failure.Exception.Message)"
}
