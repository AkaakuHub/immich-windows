#requires -Version 7.0
[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
param(
    [ValidateSet('AllUsers','CurrentUser')][string]$Scope='AllUsers',
    [string]$InstallRoot,
    [string]$DataRoot,
    [string]$PostgresRoot,
    [string]$PostgresService,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\runtime\Common.psm1') -Force
if ($Scope -eq 'AllUsers') { Assert-Administrator }
$paths=Resolve-ImmichInstallPaths -Scope $Scope -InstallRoot $InstallRoot -DataRoot $DataRoot
$InstallRoot=$paths.InstallRoot
$DataRoot=$paths.DataRoot

$stateFile=Join-Path $DataRoot 'state\upgrade-recovery.json'
if(-not(Test-Path -LiteralPath $stateFile -PathType Leaf)){throw "Upgrade recovery state not found: $stateFile"}
$state=Get-Content -Raw -LiteralPath $stateFile|ConvertFrom-Json -AsHashtable
if($state.status -eq 'qualified' -and -not $Force){
    throw 'The last upgrade is marked qualified. Recovery is destructive and requires -Force for a qualified release.'
}
if($state.status -eq 'recovered' -and -not $Force){throw 'The recorded upgrade has already been recovered.'}

$previousRelease=[string]$state.previousRelease
$backup=[string]$state.databaseBackup
if(-not(Test-Path -LiteralPath $previousRelease -PathType Container)){throw "Previous release is missing: $previousRelease"}
$databaseUnchanged = $state.ContainsKey('databaseUnchanged') -and [bool]$state.databaseUnchanged
if(-not $databaseUnchanged -and -not(Test-Path -LiteralPath $backup -PathType Leaf)){throw "Paired pre-upgrade database backup is missing: $backup"}
$previousManifest=Get-Content -Raw -LiteralPath (Join-Path $previousRelease 'manifest.json')|ConvertFrom-Json
$envFile=Join-Path $DataRoot 'immich.env'
$envs=Read-EnvFile $envFile
if ($envs.IMMICH_WINDOWS_INSTALL_SCOPE -ne $Scope) { throw 'The selected scope does not match the installed environment.' }
if (-not $PostgresRoot) { $PostgresRoot = if ($envs['POSTGRES_ROOT']) { $envs['POSTGRES_ROOT'] } elseif ($envs['IMMICH_POSTGRES_BIN_DIR']) { Split-Path -Parent $envs['IMMICH_POSTGRES_BIN_DIR'] } else { 'C:\Program Files\PostgreSQL\18' } }
if (-not $PostgresService) { $PostgresService = if ($envs['POSTGRES_SERVICE']) { $envs['POSTGRES_SERVICE'] } else { 'postgresql-x64-18' } }

$description="restore database backup '$backup', restore PostgreSQL extension binaries from '$previousRelease', and switch current back to $($previousManifest.immichVersion)"
if ($databaseUnchanged) { $description = "restore previous application and settings from '$previousRelease' without restoring the unchanged database schema" }
if(-not $PSCmdlet.ShouldProcess('Immich native Windows installation',$description)){return}

$lockKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes([IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($InstallRoot)).ToUpperInvariant())))
$mutex = [Threading.Mutex]::new($false, "Global\ImmichWindowsUpdate-$lockKey")
$locked = $false
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'An update or recovery is already running.' }
    $state.status='recovering'
    $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $stateFile -Encoding utf8

& (Join-Path $PSScriptRoot '..\runtime\launchers\Stop-Immich.ps1') -EnvFile $envFile -DataRoot $DataRoot -InstallRoot $InstallRoot

# A Windows PostgreSQL extension DLL is global to the PostgreSQL installation,
# not release-local. Put back the extension binaries paired with the previous
# release before recreating the pre-upgrade database. RecoveryRestore explicitly
# skips ALTER EXTENSION against the failed candidate database; that database is
# replaced immediately below.
if (-not $databaseUnchanged -and $Scope -eq 'AllUsers') { & (Join-Path $PSScriptRoot 'Install-PostgresExtensions.ps1') `
    -PackageRoot $previousRelease `
    -PostgresRoot $PostgresRoot `
    -PostgresService $PostgresService `
    -AdminUser $envs.DB_USERNAME `
    -DatabaseName $envs.DB_DATABASE_NAME `
    -DatabaseHost $envs.DB_HOSTNAME `
    -DatabasePort ([int]$envs.DB_PORT) `
    -AdminPassword $envs.DB_PASSWORD `
    -RecoveryRestore }

if (-not $databaseUnchanged) {
    & (Join-Path $previousRelease 'migration\Import-Database.ps1') -Backup $backup -EnvFile $envFile -PostgresRoot $PostgresRoot
}
Set-CurrentReleaseJunction -InstallRoot $InstallRoot -ReleasePath $previousRelease

# The persistent environment deliberately points at the stable `current`
# junction. Only the informational source ref must be reset after rollback.
if ($state.ContainsKey('previousEnv')) {
    [IO.File]::WriteAllText($envFile, [string]$state.previousEnv, [Text.UTF8Encoding]::new($false))
    foreach ($name in $state.previousServices.Keys) {
        [IO.File]::WriteAllText((Join-Path $DataRoot "services\$name.xml"), [string]$state.previousServices[$name], [Text.UTF8Encoding]::new($false))
        Copy-Item (Join-Path $previousRelease 'runtime\winsw\WinSW-x64.exe') (Join-Path $DataRoot "services\$name.exe") -Force
    }
    if ($state.previousValkeyConfig) { [IO.File]::WriteAllText((Join-Path $DataRoot 'valkey.conf'), [string]$state.previousValkeyConfig, [Text.UTF8Encoding]::new($false)) }
}
$envs=Read-EnvFile $envFile
$envs['IMMICH_SOURCE_REF']=[string]$previousManifest.immichVersion
$envs['IMMICH_BUILD_DATA']=Join-Path $InstallRoot 'current\build'
Write-EnvFile -Path $envFile -Values $envs
if ($Scope -eq 'AllUsers') { Protect-ImmichDataRoot -Path $DataRoot }

$state.status='recovery-starting'
$state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $stateFile -Encoding utf8
& (Join-Path $InstallRoot 'current\runtime\launchers\Start-Immich.ps1') -EnvFile $envFile -InstallRoot $InstallRoot -DataRoot $DataRoot
& (Join-Path $InstallRoot 'current\tests\Smoke-Windows.ps1') -InstallRoot $InstallRoot -DataRoot $DataRoot -PostgresRoot $PostgresRoot

$state.status='recovered'
$state.recoveredAtUtc=[DateTime]::UtcNow.ToString('o')
$state.recoveredRelease=$previousRelease
$state|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $stateFile -Encoding utf8
Write-Host "Recovered Immich $($previousManifest.immichVersion). Database restored: $(-not $databaseUnchanged)."

} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
