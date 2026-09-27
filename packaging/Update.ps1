[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackageRoot,
    [string]$InstallRoot='C:\Program Files\Immich',
    [string]$DataRoot='C:\ProgramData\Immich',
    [string]$PostgresRoot='C:\Program Files\PostgreSQL\18',
    [string]$PostgresService='postgresql-x64-18'
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
Assert-Administrator

$PackageRoot=(Resolve-Path -LiteralPath $PackageRoot).Path
$previousRelease=Get-CurrentReleaseTarget -InstallRoot $InstallRoot
if(-not $previousRelease -or -not(Test-Path -LiteralPath $previousRelease -PathType Container)){
    throw 'A valid existing current Immich release is required for an in-place update.'
}

$envFile=Join-Path $DataRoot 'immich.env'
$e=Read-EnvFile $envFile
$previousManifest=Get-Content -Raw -LiteralPath (Join-Path $previousRelease 'manifest.json')|ConvertFrom-Json
$candidateManifest=Get-Content -Raw -LiteralPath (Join-Path $PackageRoot 'manifest.json')|ConvertFrom-Json
if($previousManifest.immichVersion -eq $candidateManifest.immichVersion){
    throw "Refusing an in-place update to the same Immich version $($candidateManifest.immichVersion). Use Install.ps1 only for an intentional reinstall."
}

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

$backup=& (Join-Path $PSScriptRoot '..\migration\New-DatabaseBackup.ps1') -EnvFile $envFile -PostgresRoot $PostgresRoot
$backup=@($backup)[-1]
if(-not(Test-Path -LiteralPath $backup -PathType Leaf)){throw "Pre-upgrade database backup was not created: $backup"}
$state.databaseBackup=$backup
$state.status='backup-created'
Save-UpgradeState
Write-Host "Pre-upgrade database backup: $backup"

foreach($name in @('ImmichServer','ImmichMachineLearning','ImmichValkey')){
    if(Get-Service $name -ErrorAction SilentlyContinue){
        Stop-Service $name -Force -ErrorAction SilentlyContinue
        (Get-Service $name).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(60))
    }
}

try {
    $redisMode=if($e.IMMICH_WINDOWS_REDIS_MODE){$e.IMMICH_WINDOWS_REDIS_MODE}else{'BundledValkey'}
    $redisHost=if($e.REDIS_HOSTNAME){$e.REDIS_HOSTNAME}else{'127.0.0.1'}
    $redisPort=if($e.REDIS_PORT){[int]$e.REDIS_PORT}else{6379}

    & (Join-Path $PSScriptRoot 'Install.ps1') `
        -PackageRoot $PackageRoot `
        -MediaRoot $e.IMMICH_MEDIA_LOCATION `
        -DatabasePassword $e.DB_PASSWORD `
        -InstallRoot $InstallRoot `
        -DataRoot $DataRoot `
        -PostgresRoot $PostgresRoot `
        -PostgresService $PostgresService `
        -DatabaseName $e.DB_DATABASE_NAME `
        -DatabaseUser $e.DB_USERNAME `
        -DatabaseHost $e.DB_HOSTNAME `
        -DatabasePort ([int]$e.DB_PORT) `
        -RedisMode $redisMode `
        -RedisHost $redisHost `
        -RedisPort $redisPort `
        -PreserveExistingEnv `
        -ReuseServices `
        -DoNotStart

    $state.candidateRelease=Get-CurrentReleaseTarget -InstallRoot $InstallRoot
    $state.status='candidate-installed'
    Save-UpgradeState

    & (Join-Path $InstallRoot 'current\runtime\launchers\Start-Immich.ps1') -EnvFile $envFile
    & (Join-Path $InstallRoot 'current\tests\Smoke-Windows.ps1') -InstallRoot $InstallRoot -DataRoot $DataRoot -PostgresRoot $PostgresRoot

    $state.status='qualified'
    $state.completedAtUtc=[DateTime]::UtcNow.ToString('o')
    Save-UpgradeState
    Write-Host "Upgrade qualified: $($state.previousVersion) -> $($state.candidateVersion)"
    Write-Host "Paired rollback backup retained at: $backup"
} catch {
    foreach($name in @('ImmichServer','ImmichMachineLearning')){
        if(Get-Service $name -ErrorAction SilentlyContinue){Stop-Service $name -Force -ErrorAction SilentlyContinue}
    }
    $state.status='failed'
    $state.completedAtUtc=[DateTime]::UtcNow.ToString('o')
    $state.failure=$_.Exception.ToString()
    Save-UpgradeState
    Write-Error "Upgrade failed and Immich services were stopped. Recovery state: $stateFile. Database backup: $backup. Run installer\Recover-Upgrade.ps1; do not point the previous Immich binary at this database before restoring the paired backup. $($_.Exception.Message)"
    throw
}
