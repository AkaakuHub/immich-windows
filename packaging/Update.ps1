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
$candidateManifestText=Get-Content -Raw -LiteralPath (Join-Path $PackageRoot 'manifest.json')
$candidateManifest=$candidateManifestText|ConvertFrom-Json
$previousVersion = Get-WindowsPackageVersion $previousManifest
$candidateVersion = Get-WindowsPackageVersion $candidateManifest
if ($candidateVersion -le $previousVersion) { throw "Candidate $candidateVersion must be newer than installed $previousVersion." }
if (-not $PostgresRoot) { $PostgresRoot = if ($installedEnv['POSTGRES_ROOT']) { $installedEnv['POSTGRES_ROOT'] } elseif ($installedEnv['IMMICH_POSTGRES_BIN_DIR']) { Split-Path -Parent $installedEnv['IMMICH_POSTGRES_BIN_DIR'] } else { 'C:\Program Files\PostgreSQL\18' } }
if (-not $PostgresService) { $PostgresService = if ($installedEnv['POSTGRES_SERVICE']) { $installedEnv['POSTGRES_SERVICE'] } else { 'postgresql-x64-18' } }
# Serialize updates for this installation across user sessions. No lock file to leave behind.
$lockKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes([IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($InstallRoot)).ToUpperInvariant())))
$mutex = [Threading.Mutex]::new($false, "Global\ImmichWindowsUpdate-$lockKey")
$locked = $false
$startupMutex=$null
$startupLocked=$false
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
    controllerProcessId=$PID
    controllerMutexName="Global\ImmichWindowsStartup-$lockKey-$([guid]::NewGuid().ToString('N'))"
    previousRelease=$previousRelease
    previousVersion="v$previousVersion"
    candidatePackageRoot=$PackageRoot
    candidateRelease=$null
    candidateVersion="v$candidateVersion"
    databaseBackup=$null
    databaseUnchanged=$false
    dependencyTransfers=@()
    startedAtUtc=[DateTime]::UtcNow.ToString('o')
    completedAtUtc=$null
    failure=$null
}
$startupMutex=[Threading.Mutex]::new($false,$state.controllerMutexName)
$startupLocked=$startupMutex.WaitOne(0)
if (-not $startupLocked) { throw 'Could not acquire this update startup gate.' }
function Save-UpgradeState {
    $temporary = "$stateFile.tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($state|ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $stateFile, $true)
    } finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
}
Save-UpgradeState

Write-Host (Get-ImmichProgressText selection)
$stopScript=Join-Path $PSScriptRoot '..\runtime\launchers\Stop-Immich.ps1'
$updateProgress=@{}
try {
    $updateProgress.prepare=Start-ImmichProgress -Key prepare
    $candidateRelease = Join-Path $InstallRoot "releases\v$candidateVersion"
    $updateIdentity=@{PackageRoot=$PackageRoot;Release=$candidateRelease;PreviousRelease=$previousRelease;InstallRoot=$InstallRoot;DataRoot=$DataRoot;Scope=$Scope;Manifest=$candidateManifestText;EnvFile=$envFile}
    $controller = {
        param([string]$Phase,$Context,[bool]$DatabaseUnchanged)
        # This continuation is private to this invocation, with no saved receipt
        # or generic skip flag. Reject a foreign/changed/replayed preparation.
        foreach ($name in @('PackageRoot','Release','PreviousRelease','InstallRoot','DataRoot')) {
            if ([IO.Path]::GetFullPath($Context.$name) -ine [IO.Path]::GetFullPath($updateIdentity[$name])) { throw 'Prepared update paths do not match this transaction.' }
        }
        if ($Context.Scope -ne $updateIdentity.Scope -or (Get-CurrentReleaseTarget -InstallRoot $updateIdentity.InstallRoot) -ne $updateIdentity.PreviousRelease -or
            (Get-Content -Raw -LiteralPath (Join-Path $updateIdentity.PackageRoot 'manifest.json')) -cne $updateIdentity.Manifest -or
            (Get-Content -Raw -LiteralPath (Join-Path $updateIdentity.Release 'manifest.json')) -cne $updateIdentity.Manifest -or
            (Get-Content -Raw -LiteralPath $updateIdentity.EnvFile) -cne $state.previousEnv) { throw 'Prepared update identity or configuration changed.' }
        if ($Phase -eq 'Prepared' -and $state.status -eq 'preparing') {
            Update-ImmichProgress -State $updateProgress.prepare -Finished
            $state.candidateRelease=$candidateRelease
            $state.status='stopping'
            Save-UpgradeState
            $stopProgress=Start-ImmichProgress -Key stop
            $global:LASTEXITCODE=0
            & $stopScript -EnvFile $envFile -DataRoot $DataRoot -InstallRoot $InstallRoot
            if ($LASTEXITCODE -ne 0) { throw "Immich shutdown failed with exit code $LASTEXITCODE." }
            Update-ImmichProgress -State $stopProgress -Finished
            return
        }
        if ($Phase -ne 'DatabaseCompared' -or $state.status -ne 'stopping') { throw 'Unexpected update continuation phase.' }
        $state.databaseUnchanged=$DatabaseUnchanged
        if (-not $DatabaseUnchanged) {
            $backupProgress=Start-ImmichProgress -Key backup
            $global:LASTEXITCODE=0
            $backup=& (Join-Path $PSScriptRoot '..\migration\New-DatabaseBackup.ps1') -EnvFile $envFile -PostgresRoot $PostgresRoot
            if ($LASTEXITCODE -ne 0) { throw "Database backup failed with exit code $LASTEXITCODE." }
            $backup=@($backup)[-1]
            if (-not $backup -or -not (Test-Path -LiteralPath $backup -PathType Leaf)) { throw "Pre-upgrade database backup was not created: $backup" }
            Update-ImmichProgress -State $backupProgress -Finished
            $state.databaseBackup=$backup
            Write-Host "Pre-upgrade database backup: $backup"
        } else {
            Write-Host 'Database-facing payloads are identical. Skipping upgrade-only DB backup and all installer DB changes.'
        }
        $updateProgress.switch=Start-ImmichProgress -Key switch
        $state.status='installing'
        $state.dependencyTransfers=@()
        if ($Context.PSObject.Properties['DependencyReusePlan'] -and $null -ne $Context.DependencyReusePlan) { $state.dependencyTransfers=$Context.DependencyReusePlan.ToArray() }
        # Journal before rename. A crash between directories is recovered by their
        # source/destination presence; there is no tree scan or copy fallback.
        Save-UpgradeState
        if ($state.dependencyTransfers.Count) { Write-Host "Recovery script: $(Join-Path $candidateRelease 'installer/Recover-Upgrade.ps1')" }
        Move-ImmichReusedDependencies -DependencyReusePlan $state.dependencyTransfers -PreviousRelease $previousRelease -CandidateRelease $candidateRelease
        Assert-ImmichReusedDependencies -DependencyReusePlan $state.dependencyTransfers -CandidateRelease $candidateRelease
    }
    $global:LASTEXITCODE=0
    & (Join-Path $PSScriptRoot 'Install.ps1') `
        -PackageRoot $PackageRoot `
        -Scope $Scope `
        -EnvFile $envFile `
        -InstallRoot $InstallRoot `
        -DataRoot $DataRoot `
        -PostgresRoot $PostgresRoot `
        -PostgresService $PostgresService `
        -ReuseServices `
        -UpdateController $controller `
        -ResumeExistingRelease:(Test-Path -LiteralPath $candidateRelease) `
        -DoNotStart
    if ($LASTEXITCODE -ne 0) { throw "Candidate installation failed with exit code $LASTEXITCODE." }
    if ($state.status -ne 'installing' -or (Get-CurrentReleaseTarget -InstallRoot $InstallRoot) -ne $candidateRelease) { throw 'The installer did not complete its controlled preparation and activation.' }

    Update-ImmichProgress -State $updateProgress.switch -Finished
    $state.candidateRelease=Get-CurrentReleaseTarget -InstallRoot $InstallRoot
    $state.status='candidate-installed'
    Save-UpgradeState

    $startProgress=Start-ImmichProgress -Key start
    $global:LASTEXITCODE=0
    & (Join-Path $InstallRoot 'current\runtime\launchers\Start-Immich.ps1') -EnvFile $envFile -InstallRoot $InstallRoot -DataRoot $DataRoot -UpgradeInProgress
    if ($LASTEXITCODE -ne 0) { throw "Immich startup failed with exit code $LASTEXITCODE." }
    Update-ImmichProgress -State $startProgress -Finished
    $verifyProgress=Start-ImmichProgress -Key verify
    $global:LASTEXITCODE=0
    & (Join-Path $InstallRoot 'current\tests\Smoke-Windows.ps1') -InstallRoot $InstallRoot -DataRoot $DataRoot -PostgresRoot $PostgresRoot
    if ($LASTEXITCODE -ne 0) { throw "Updated installation verification failed with exit code $LASTEXITCODE." }

    Update-ImmichProgress -State $verifyProgress -Finished
    $state.status='qualified'
    $state.completedAtUtc=[DateTime]::UtcNow.ToString('o')
    Save-UpgradeState
    $nativeBackup=Join-Path $candidateRelease '.dependency-backups/sharp'
    if (Test-Path -LiteralPath $nativeBackup) { Remove-Item -LiteralPath $nativeBackup -Recurse -Force }
    Write-Host "Upgrade qualified: $($state.previousVersion) -> $($state.candidateVersion)"
    if ($state.databaseBackup) { Write-Host "Database backup retained at: $($state.databaseBackup)" }
} catch {
    $failure=$_
    $preparationFailed = $state.status -eq 'preparing'
    $state.status = if ($preparationFailed) { 'preparation-failed' } elseif ($state.status -eq 'stopping' -and -not $state.databaseBackup) { 'backup-failed' } else { 'failed' }
    $state.completedAtUtc=[DateTime]::UtcNow.ToString('o')
    $state.failure=$failure.Exception.ToString()
    Save-UpgradeState
    try {
        if (-not $preparationFailed) {
            $global:LASTEXITCODE=0
            & $stopScript -EnvFile $envFile -DataRoot $DataRoot -InstallRoot $InstallRoot
            if ($LASTEXITCODE -ne 0) { throw "Immich shutdown failed with exit code $LASTEXITCODE." }
            Move-ImmichReusedDependencies -DependencyReusePlan $state.dependencyTransfers -PreviousRelease $previousRelease -CandidateRelease $candidateRelease -Restore
        }
    } catch { Write-Warning "Shutdown or dependency restoration also failed; explicit recovery is required: $($_.Exception.Message)" }
    $recoveryRoot=if ($state.candidateRelease) { [string]$state.candidateRelease } else { $PackageRoot }
    throw "Upgrade failed. Recovery script: $(Join-Path $recoveryRoot 'installer/Recover-Upgrade.ps1'). Recovery state: $stateFile. Database backup: $($state.databaseBackup). $($failure.Exception.Message)"
}

# All entrypoints share this post-qualification lifecycle. Keep the v8 tray
# alive on update failure; after success, await its actual exit before deleting.
$trayStopped=$false
try {
    Stop-ImmichTray -InstallRoot $InstallRoot -ReleasePath $state.previousRelease
    $trayStopped=$true
    . (Join-Path $PSScriptRoot 'Remove-ObsoleteReleases.ps1')
    Remove-ImmichObsoleteReleases -InstallRoot $InstallRoot -DataRoot $DataRoot -CurrentReleasePath $state.candidateRelease -PreviousReleasePath $state.previousRelease -EnvFile $envFile | Out-Null
} catch { Write-Warning "The update is healthy, but previous release cleanup could not finish: $($_.Exception.Message)" }
finally {
    # Cleanup errors must not strand the desktop without its newly installed tray.
    if ($trayStopped) {
        try { Start-ImmichTray -InstallRoot $InstallRoot -DataRoot $DataRoot -Scope $Scope }
        catch { Write-Warning "The update is healthy, but the new tray could not start: $($_.Exception.Message)" }
    }
}

} finally {
    if ($startupLocked) { $startupMutex.ReleaseMutex() }
    if ($startupMutex) { $startupMutex.Dispose() }
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
$global:LASTEXITCODE=0
