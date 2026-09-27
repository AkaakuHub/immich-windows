[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
param(
    [ValidateSet('AllUsers','CurrentUser')][string]$Scope='AllUsers',
    [string]$InstallRoot,
    [string]$DataRoot,
    [string]$PostgresRoot='C:\Program Files\PostgreSQL\18',
    [string]$PostgresService='postgresql-x64-18',
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
if ($Scope -eq 'AllUsers') { Assert-Administrator }
$paths=Resolve-ImmichInstallPaths -Scope $Scope -InstallRoot $InstallRoot -DataRoot $DataRoot
$InstallRoot=$paths.InstallRoot
$DataRoot=$paths.DataRoot

$stateFile=Join-Path $DataRoot 'state\upgrade-recovery.json'
if(-not(Test-Path -LiteralPath $stateFile -PathType Leaf)){throw "Upgrade recovery state not found: $stateFile"}
$state=Get-Content -Raw -LiteralPath $stateFile|ConvertFrom-Json
if($state.status -eq 'qualified' -and -not $Force){
    throw 'The last upgrade is marked qualified. Recovery is destructive and requires -Force for a qualified release.'
}
if($state.status -eq 'recovered' -and -not $Force){throw 'The recorded upgrade has already been recovered.'}

$previousRelease=[string]$state.previousRelease
$backup=[string]$state.databaseBackup
if(-not(Test-Path -LiteralPath $previousRelease -PathType Container)){throw "Previous release is missing: $previousRelease"}
if(-not(Test-Path -LiteralPath $backup -PathType Leaf)){throw "Paired pre-upgrade database backup is missing: $backup"}
$previousManifest=Get-Content -Raw -LiteralPath (Join-Path $previousRelease 'manifest.json')|ConvertFrom-Json
$envFile=Join-Path $DataRoot 'immich.env'
$envs=Read-EnvFile $envFile

$description="restore database backup '$backup', restore PostgreSQL extension binaries from '$previousRelease', and switch current back to $($previousManifest.immichVersion)"
if(-not $PSCmdlet.ShouldProcess('Immich native Windows installation',$description)){return}

if ($Scope -eq 'CurrentUser') {
    & (Join-Path $InstallRoot 'current\runtime\Stop-Immich.ps1') -EnvFile $envFile -DataRoot $DataRoot -InstallRoot $InstallRoot
} else { foreach($name in @('ImmichServer','ImmichMachineLearning','ImmichValkey')){if(Get-Service $name -ErrorAction SilentlyContinue){Stop-Service $name -Force -ErrorAction SilentlyContinue}} }

# A Windows PostgreSQL extension DLL is global to the PostgreSQL installation,
# not release-local. Put back the extension binaries paired with the previous
# release before recreating the pre-upgrade database. RecoveryRestore explicitly
# skips ALTER EXTENSION against the failed candidate database; that database is
# replaced immediately below.
if ($Scope -eq 'AllUsers') { & (Join-Path $PSScriptRoot 'Install-PostgresExtensions.ps1') `
    -PackageRoot $previousRelease `
    -PostgresRoot $PostgresRoot `
    -PostgresService $PostgresService `
    -AdminUser $envs.DB_USERNAME `
    -DatabaseName $envs.DB_DATABASE_NAME `
    -DatabaseHost $envs.DB_HOSTNAME `
    -DatabasePort ([int]$envs.DB_PORT) `
    -AdminPassword $envs.DB_PASSWORD `
    -RecoveryRestore }

& (Join-Path $previousRelease 'migration\Import-Database.ps1') -Backup $backup -EnvFile $envFile -PostgresRoot $PostgresRoot
Set-CurrentReleaseJunction -InstallRoot $InstallRoot -ReleasePath $previousRelease

# The persistent environment deliberately points at the stable `current`
# junction. Only the informational source ref must be reset after rollback.
$envs=Read-EnvFile $envFile
$envs['IMMICH_SOURCE_REF']=[string]$previousManifest.immichVersion
$envs['IMMICH_BUILD_DATA']=Join-Path $InstallRoot 'current\build'
Write-EnvFile -Path $envFile -Values $envs
if ($Scope -eq 'AllUsers') { Protect-ImmichDataRoot -Path $DataRoot }

& (Join-Path $InstallRoot 'current\runtime\Start-Immich.ps1') -EnvFile $envFile -InstallRoot $InstallRoot -DataRoot $DataRoot
& (Join-Path $InstallRoot 'current\tests\Smoke-Windows.ps1') -InstallRoot $InstallRoot -DataRoot $DataRoot -PostgresRoot $PostgresRoot

$state.status='recovered'
$state.recoveredAtUtc=[DateTime]::UtcNow.ToString('o')
$state.recoveredRelease=$previousRelease
$state|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $stateFile -Encoding utf8
Write-Host "Recovered Immich $($previousManifest.immichVersion) with its paired pre-upgrade database backup."
