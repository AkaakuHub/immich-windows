#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackageRoot,
    [ValidateSet('AllUsers','CurrentUser')][string]$Scope='AllUsers',
    [string]$InstallRoot,
    [string]$DataRoot,
    [string]$PostgresRoot,
    [string]$PostgresService
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
& (Join-Path $PSScriptRoot 'Test-ReleasePackage.ps1') -PackageRoot $PackageRoot
$previousVersion = Get-WindowsPackageVersion $previousManifest
$candidateVersion = Get-WindowsPackageVersion $candidateManifest
if ($candidateVersion -le $previousVersion) { throw "Candidate $candidateVersion must be newer than installed $previousVersion." }
if (-not $PostgresRoot) { $PostgresRoot = if ($installedEnv['POSTGRES_ROOT']) { $installedEnv['POSTGRES_ROOT'] } elseif ($installedEnv['IMMICH_POSTGRES_BIN_DIR']) { Split-Path -Parent $installedEnv['IMMICH_POSTGRES_BIN_DIR'] } else { 'C:\Program Files\PostgreSQL\18' } }
if (-not $PostgresService) { $PostgresService = if ($installedEnv['POSTGRES_SERVICE']) { $installedEnv['POSTGRES_SERVICE'] } else { 'postgresql-x64-18' } }
# Serialize updates for this installation across user sessions. No lock file to leave behind.
$lockKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes([IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($InstallRoot)).ToUpperInvariant())))
$mutex = [Threading.Mutex]::new($false, "Global\ImmichWindowsUpdate-$lockKey")
$locked = $false
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Another update is already running for this installation.' }
    if ((Get-CurrentReleaseTarget -InstallRoot $InstallRoot) -ne $previousRelease) { throw 'Installed release changed during validation; rerun the update.' }
$stateDirectory=Join-Path $DataRoot 'state'
New-Item -ItemType Directory -Path $stateDirectory -Force|Out-Null
if ($Scope -eq 'AllUsers') { Protect-ImmichDataRoot -Path $DataRoot }
$stateFile=Join-Path $stateDirectory 'upgrade-recovery.json'
if (Test-Path -LiteralPath $stateFile -PathType Leaf) {
    $lastState = Get-Content -Raw -LiteralPath $stateFile | ConvertFrom-Json
    if ($lastState.status -notin @('qualified','recovered','preparation-failed','preparing','backup-failed')) {
        throw "The previous update is incomplete ($($lastState.status)). Resolve or recover it before starting another update."
    }
}
$previousServices = [ordered]@{}
foreach ($name in @('ImmichServer','ImmichMachineLearning')) {
    $xml = Join-Path $DataRoot "services\$name.xml"
    if (Test-Path -LiteralPath $xml -PathType Leaf) { $previousServices[$name] = Get-Content -Raw -LiteralPath $xml }
}
$state=[ordered]@{
    schemaVersion=2
    previousEnv=(Get-Content -Raw -LiteralPath $envFile)
    previousServices=$previousServices
    previousValkeyConfig=$(if (Test-Path (Join-Path $DataRoot 'valkey.conf')) { Get-Content -Raw (Join-Path $DataRoot 'valkey.conf') } else { $null })
    status='preparing'
    previousRelease=$previousRelease
    previousVersion="v$previousVersion"
    candidatePackageRoot=$PackageRoot
    candidateRelease=$null
    candidateVersion="v$candidateVersion"
    databaseBackup=$null
    databaseUnchanged=$false
    startedAtUtc=[DateTime]::UtcNow.ToString('o')
    completedAtUtc=$null
    failure=$null
}
function Save-UpgradeState {
    $temporary = "$stateFile.tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($state|ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $stateFile, $true)
    } finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
}
Save-UpgradeState

$stopScript=Join-Path $PSScriptRoot '..\runtime\launchers\Stop-Immich.ps1'
$backup=$null
try {
    $candidateRelease = Join-Path $InstallRoot "releases\v$candidateVersion"
    & (Join-Path $PSScriptRoot 'Install.ps1') -PackageRoot $PackageRoot -Scope $Scope -EnvFile $envFile -InstallRoot $InstallRoot -DataRoot $DataRoot -PostgresRoot $PostgresRoot -PostgresService $PostgresService -ReuseServices -PrepareOnly -ResumeExistingRelease:(Test-Path -LiteralPath $candidateRelease)
    $state.databaseUnchanged = Test-ImmichDatabasePayloadEqual -PreviousRelease $previousRelease -CandidateRelease $candidateRelease
    $state.candidateRelease = $candidateRelease
    $state.status = 'stopping'
    Save-UpgradeState
& $stopScript -EnvFile $envFile -DataRoot $DataRoot -InstallRoot $InstallRoot
if (-not $state.databaseUnchanged) {
    $backup=& (Join-Path $PSScriptRoot '..\migration\New-DatabaseBackup.ps1') -EnvFile $envFile -PostgresRoot $PostgresRoot
    $backup=@($backup)[-1]
    if(-not(Test-Path -LiteralPath $backup -PathType Leaf)){throw "Pre-upgrade database backup was not created: $backup"}
    $state.databaseBackup=$backup
    Write-Host "Pre-upgrade database backup: $backup"
} else {
    Write-Host 'Database-facing payloads are identical. Skipping upgrade-only DB backup and all installer DB changes.'
}
$state.status='installing'
Save-UpgradeState

    & (Join-Path $PSScriptRoot 'Install.ps1') `
        -PackageRoot $PackageRoot `
        -Scope $Scope `
        -EnvFile $envFile `
        -InstallRoot $InstallRoot `
        -DataRoot $DataRoot `
        -PostgresRoot $PostgresRoot `
        -PostgresService $PostgresService `
        -ReuseServices `
        -ApplicationOnly:$state.databaseUnchanged `
        -ResumeExistingRelease `
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
    if ($backup) { Write-Host "Paired rollback backup retained at: $backup" }
} catch {
    $failure=$_
    $preparationFailed = $state.status -eq 'preparing'
    $state.status = if ($preparationFailed) { 'preparation-failed' } elseif ($state.status -eq 'stopping' -and -not $state.databaseBackup) { 'backup-failed' } else { 'failed' }
    $state.completedAtUtc=[DateTime]::UtcNow.ToString('o')
    $state.failure=$failure.Exception.ToString()
    Save-UpgradeState
    try { if (-not $preparationFailed) { & $stopScript -EnvFile $envFile -DataRoot $DataRoot -InstallRoot $InstallRoot } }
    catch { Write-Warning "Immich shutdown also failed: $($_.Exception.Message)" }
    throw "Upgrade failed. Recovery state: $stateFile. Database backup: $backup. $($failure.Exception.Message)"
}

} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
