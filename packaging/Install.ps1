#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$PackageRoot,
    [string]$MediaRoot,
    [string]$DatabasePassword,
    [string]$EnvFile,
    [ValidateSet('AllUsers','CurrentUser')][string]$Scope,
    [string]$InstallRoot,
    [string]$DataRoot,
    [string]$PostgresRoot = 'C:\Program Files\PostgreSQL\18',
    [string]$PostgresService = 'postgresql-x64-18',
    [string]$DatabaseName = 'immich',
    [string]$DatabaseUser = 'postgres',
    [string]$DatabaseHost = '127.0.0.1',
    [ValidateRange(1,65535)][int]$DatabasePort = 5432,
    [ValidateRange(1,65535)][int]$ServerPort = 2283,
    [ValidateRange(1,65535)][int]$MachineLearningPort = 3003,
    [ValidateSet('cpu','directml')][string]$MachineLearningAccelerator = 'cpu',
    [int]$MachineLearningDeviceId = 0,
    [ValidateSet('BundledValkey','External')][string]$RedisMode = 'BundledValkey',
    [string]$RedisHost = '127.0.0.1',
    [int]$RedisPort = 6379,
    [switch]$SkipPostgresExtensionInstall,
    [switch]$AllowUnqualifiedMediaStack,
    [switch]$ResumeExistingRelease,
    [switch]$ReuseServices,
    [switch]$PrepareOnly,
    [switch]$ApplicationOnly,
    [switch]$DoNotStart,
    [string]$ElevationFailureReport
)
Import-Module (Join-Path $PSScriptRoot '..\runtime\Common.psm1') -Force
$ErrorActionPreference = 'Stop'

function Start-ElevatedInstaller {
    param([System.Collections.IDictionary]$InstallerParameters)
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { return }

    $arguments = [System.Collections.Generic.List[string]]::new()
    $arguments.Add('-NoProfile')
    $arguments.Add('-ExecutionPolicy')
    $arguments.Add('Bypass')
    $arguments.Add('-File')
    $arguments.Add($PSCommandPath)
    foreach ($entry in $InstallerParameters.GetEnumerator()) {
        if ($entry.Key -eq 'Scope') { continue }
        $arguments.Add("-$($entry.Key)")
        if ($entry.Value -is [System.Management.Automation.SwitchParameter]) {
            if (-not $entry.Value.IsPresent) { $arguments.Remove("-$($entry.Key)") }
        } else {
            $arguments.Add([string]$entry.Value)
        }
    }
    $arguments.Add('-Scope')
    $arguments.Add('AllUsers')
    $hostPath = Join-Path $PSHOME 'pwsh.exe'
    $failureReport = Join-Path $env:TEMP "immich-install-$([guid]::NewGuid().ToString('N')).error.txt"
    $arguments.Add('-ElevationFailureReport')
    $arguments.Add($failureReport)
    $argumentLine = ($arguments | ForEach-Object { ConvertTo-WindowsArgument -Value $_ }) -join ' '

    Write-Host 'Requesting administrator permission to install Immich for all users.'
    try {
        $elevated = Start-Process -FilePath $hostPath -ArgumentList $argumentLine -Verb RunAs -Wait -PassThru -ErrorAction Stop
    } catch {
        Remove-Item -LiteralPath $failureReport -Force -ErrorAction SilentlyContinue
        if ($_.Exception.NativeErrorCode -eq 1223) {
            throw 'Windows administrator permission was not granted. No installation was performed.'
        }
        throw
    }
    if ($elevated.ExitCode -ne 0) {
        $detail = if (Test-Path -LiteralPath $failureReport -PathType Leaf) { Get-Content -Raw -LiteralPath $failureReport } else { 'The elevated process did not provide error details.' }
        Remove-Item -LiteralPath $failureReport -Force -ErrorAction SilentlyContinue
        throw "Elevated installation failed with exit code $($elevated.ExitCode): $detail"
    }
    Remove-Item -LiteralPath $failureReport -Force -ErrorAction SilentlyContinue
    Write-Host 'Elevated installation completed.'
    if (-not $InstallerParameters['PrepareOnly']) {
        $trayPaths=Resolve-ImmichInstallPaths -Scope AllUsers -InstallRoot ([string]$InstallerParameters['InstallRoot']) -DataRoot ([string]$InstallerParameters['DataRoot'])
        Set-ImmichTrayStartup -InstallRoot $trayPaths.InstallRoot -DataRoot $trayPaths.DataRoot -Scope AllUsers
        if (-not $InstallerParameters['DoNotStart']) { Start-ImmichTray -InstallRoot $trayPaths.InstallRoot -DataRoot $trayPaths.DataRoot -Scope AllUsers }
    }
    exit 0
}

try {
if (-not $PackageRoot) { $PackageRoot = Split-Path -Parent $PSScriptRoot }
if (-not $Scope) {
    $detected = @()
    foreach ($candidateScope in @('AllUsers','CurrentUser')) {
        try { $candidatePaths = Resolve-ImmichInstallPaths -Scope $candidateScope -InstallRoot $InstallRoot -DataRoot $DataRoot } catch { continue }
        $candidateEnv = Join-Path $candidatePaths.DataRoot 'immich.env'
        if ((Test-Path -LiteralPath (Join-Path $candidatePaths.InstallRoot 'current\manifest.json')) -and (Test-Path -LiteralPath $candidateEnv)) {
            if ((Read-EnvFile $candidateEnv)['IMMICH_WINDOWS_INSTALL_SCOPE'] -eq $candidateScope) { $detected += $candidateScope }
        }
    }
    if ($detected.Count -eq 1) { $Scope = $detected[0] }
}
if (-not $Scope) {
    Write-Host 'Install scope:'
    Write-Host '  1. AllUsers (Windows services; starts at boot; requires administrator)'
    Write-Host '  2. CurrentUser (starts at sign-in; no administrator required)'
    $scopeChoice = Read-Host 'Choose 1 or 2'
    $Scope = switch ($scopeChoice) { '1' { 'AllUsers' } '2' { 'CurrentUser' } default { throw 'Choose 1 or 2 for the install scope.' } }
}
if ($Scope -eq 'AllUsers') {
    Start-ElevatedInstaller -InstallerParameters $PSBoundParameters
}
$paths=Resolve-ImmichInstallPaths -Scope $Scope -InstallRoot $InstallRoot -DataRoot $DataRoot
$InstallRoot=$paths.InstallRoot
$DataRoot=$paths.DataRoot

$defaultEnvFile = Join-Path $DataRoot 'immich.env'
if (-not $EnvFile -and (-not $MediaRoot -or -not $DatabasePassword) -and -not (Test-Path -LiteralPath $defaultEnvFile -PathType Leaf)) {
    $EnvFile = Read-Host 'Path to an existing Immich .env file (press Enter to enter settings manually)'
}
if (-not $EnvFile) { $EnvFile = $defaultEnvFile }
$sourceEnv = [ordered]@{}
if (Test-Path -LiteralPath $EnvFile -PathType Leaf) {
    foreach ($pair in (Read-EnvFile $EnvFile).GetEnumerator()) { $sourceEnv[$pair.Key] = $pair.Value }
} elseif ($PSBoundParameters.ContainsKey('EnvFile')) {
    throw "Environment file not found: $EnvFile"
}
if (-not $MediaRoot) {
    $MediaRoot = [string]$sourceEnv['IMMICH_MEDIA_LOCATION']
    if (-not $MediaRoot) { $MediaRoot = [string]$sourceEnv['UPLOAD_LOCATION'] }
    if ($MediaRoot -match '^/mnt/([a-zA-Z])(?:/(.*))?$') {
        $MediaRoot = '{0}:\{1}' -f $Matches[1].ToUpperInvariant(), ([string]$Matches[2]).Replace('/', '\')
    }
}
if (-not $MediaRoot) { $MediaRoot = Read-Host 'Absolute Windows path to the existing Immich media root' }
elseif (-not (Test-WindowsAbsolutePath $MediaRoot)) {
    if ($PSBoundParameters.ContainsKey('MediaRoot')) { throw 'MediaRoot must be an absolute Windows drive or UNC path.' }
    $MediaRoot = Read-Host 'The env file has no Windows media path. Enter the absolute Windows media root'
}
if (-not $DatabasePassword) {
    $DatabasePassword = [string]$sourceEnv['DB_PASSWORD']
    if (-not $DatabasePassword) {
        $securePassword = Read-Host 'PostgreSQL password' -AsSecureString
        $credential = [pscredential]::new('postgres', $securePassword)
        $DatabasePassword = $credential.GetNetworkCredential().Password
    }
}
if (-not $MediaRoot) { throw 'MediaRoot was not provided by the env file or prompt.' }
if (-not $DatabasePassword) { throw 'DatabasePassword was not provided by the env file or prompt.' }
$DatabaseHost = if ($PSBoundParameters.ContainsKey('DatabaseHost')) { $DatabaseHost } elseif ($sourceEnv['DB_HOSTNAME']) { [string]$sourceEnv['DB_HOSTNAME'] } else { $DatabaseHost }
if (-not $PSBoundParameters.ContainsKey('DatabaseHost') -and $DatabaseHost -eq 'database') { $DatabaseHost = '127.0.0.1' }
$DatabasePort = if ($PSBoundParameters.ContainsKey('DatabasePort')) { $DatabasePort } elseif ($sourceEnv['DB_PORT']) { [int]$sourceEnv['DB_PORT'] } else { $DatabasePort }
$DatabaseName = if ($PSBoundParameters.ContainsKey('DatabaseName')) { $DatabaseName } elseif ($sourceEnv['DB_DATABASE_NAME']) { [string]$sourceEnv['DB_DATABASE_NAME'] } else { $DatabaseName }
$DatabaseUser = if ($PSBoundParameters.ContainsKey('DatabaseUser')) { $DatabaseUser } elseif ($sourceEnv['DB_USERNAME']) { [string]$sourceEnv['DB_USERNAME'] } else { $DatabaseUser }
$PostgresService = if ($PSBoundParameters.ContainsKey('PostgresService')) { $PostgresService } elseif ($sourceEnv['POSTGRES_SERVICE']) { [string]$sourceEnv['POSTGRES_SERVICE'] } else { $PostgresService }
$PostgresRoot = if ($PSBoundParameters.ContainsKey('PostgresRoot')) { $PostgresRoot } elseif ($sourceEnv['POSTGRES_ROOT']) { [string]$sourceEnv['POSTGRES_ROOT'] } elseif ($sourceEnv['IMMICH_POSTGRES_BIN_DIR']) { Split-Path -Parent $sourceEnv['IMMICH_POSTGRES_BIN_DIR'] } else { $PostgresRoot }
$ServerPort = if ($PSBoundParameters.ContainsKey('ServerPort')) { $ServerPort } elseif ($sourceEnv['IMMICH_PORT']) { [int]$sourceEnv['IMMICH_PORT'] } else { $ServerPort }
$MachineLearningPort = if ($PSBoundParameters.ContainsKey('MachineLearningPort')) { $MachineLearningPort } elseif ($sourceEnv['IMMICH_PORT_ML']) { [int]$sourceEnv['IMMICH_PORT_ML'] } else { $MachineLearningPort }
$MachineLearningAccelerator = if ($PSBoundParameters.ContainsKey('MachineLearningAccelerator')) { $MachineLearningAccelerator } elseif ($sourceEnv['MACHINE_LEARNING_ACCELERATOR']) { [string]$sourceEnv['MACHINE_LEARNING_ACCELERATOR'] } else { $MachineLearningAccelerator }
$MachineLearningDeviceId = if ($PSBoundParameters.ContainsKey('MachineLearningDeviceId')) { $MachineLearningDeviceId } elseif ($sourceEnv['MACHINE_LEARNING_DEVICE_ID']) { [int]$sourceEnv['MACHINE_LEARNING_DEVICE_ID'] } else { $MachineLearningDeviceId }
if ($MachineLearningAccelerator -notin @('cpu','directml')) { throw "Unknown MachineLearningAccelerator: $MachineLearningAccelerator" }
if ($MachineLearningDeviceId -lt 0) { throw 'MachineLearningDeviceId must be zero or greater.' }
$RedisPort = if ($PSBoundParameters.ContainsKey('RedisPort')) { $RedisPort } elseif ($sourceEnv['REDIS_PORT']) { [int]$sourceEnv['REDIS_PORT'] } else { $RedisPort }
$RedisMode = if ($PSBoundParameters.ContainsKey('RedisMode')) { $RedisMode } elseif ($sourceEnv['IMMICH_WINDOWS_REDIS_MODE']) { [string]$sourceEnv['IMMICH_WINDOWS_REDIS_MODE'] } else { $RedisMode }
$RedisHost = if ($PSBoundParameters.ContainsKey('RedisHost')) { $RedisHost } elseif ($sourceEnv['REDIS_HOSTNAME'] -and $sourceEnv['IMMICH_WINDOWS_REDIS_MODE'] -eq 'External') { [string]$sourceEnv['REDIS_HOSTNAME'] } else { $RedisHost }
if ($sourceEnv['DB_URL'] -or $sourceEnv['REDIS_URL']) { throw 'Use DB_HOSTNAME/DB_PORT/DB_USERNAME/DB_PASSWORD/DB_DATABASE_NAME and REDIS_HOSTNAME/REDIS_PORT/REDIS_USERNAME/REDIS_PASSWORD instead of DB_URL or REDIS_URL when installing.' }
if ($RedisMode -eq 'BundledValkey' -and $sourceEnv['REDIS_USERNAME'] -and $sourceEnv['REDIS_USERNAME'] -ne 'default') { throw 'BundledValkey uses REDIS_USERNAME=default. Use External mode for an existing Redis ACL user.' }
$MediaRoot = [IO.Path]::GetFullPath($MediaRoot)
$PackageRoot = (Resolve-Path $PackageRoot).Path
$packageManifestPath=Join-Path $PackageRoot 'manifest.json'
if(-not(Test-Path -LiteralPath $packageManifestPath -PathType Leaf)){throw "Package manifest is missing: $packageManifestPath"}
$packageManifest=Get-Content -Raw -LiteralPath $packageManifestPath|ConvertFrom-Json
if([string]$packageManifest.target -ne 'windows-x64-native'){throw "Unsupported package target: $($packageManifest.target)"}
if(-not $AllowUnqualifiedMediaStack -and -not [bool]$packageManifest.mediaStack.productionQualified){
    throw 'Package media stack is not production-qualified. Use -AllowUnqualifiedMediaStack only for isolated bring-up testing.'
}
if (-not $AllowUnqualifiedMediaStack) { & (Join-Path $PSScriptRoot 'Test-ReleasePackage.ps1') -PackageRoot $PackageRoot }
$packageVersion = 'v' + (Get-WindowsPackageVersion $packageManifest).ToString(4)
$existingRelease = Get-CurrentReleaseTarget -InstallRoot $InstallRoot
if ($existingRelease) {
    $existingManifest = Get-Content -Raw -LiteralPath (Join-Path $existingRelease 'manifest.json') | ConvertFrom-Json
    if ((Get-WindowsPackageVersion $packageManifest) -le (Get-WindowsPackageVersion $existingManifest)) {
        throw 'The candidate must have a newer Windows package version. Active releases cannot be overwritten or downgraded.'
    }
    if (-not $ReuseServices) {
        $configurationOverrides = @('MediaRoot','DatabasePassword','DatabaseHost','DatabasePort','DatabaseName','DatabaseUser','ServerPort','MachineLearningPort','MachineLearningAccelerator','MachineLearningDeviceId','RedisMode','RedisHost','RedisPort')
        if (@($configurationOverrides | Where-Object { $PSBoundParameters.ContainsKey($_) }).Count) { throw 'An existing installation is updated using its saved immich.env. Edit that file before updating instead of passing configuration overrides.' }
        & (Join-Path $PSScriptRoot 'Update.ps1') -PackageRoot $PackageRoot -Scope $Scope -InstallRoot $InstallRoot -DataRoot $DataRoot -PostgresRoot $PostgresRoot -PostgresService $PostgresService
        return
    }
}
$postgresExe=Join-Path $PostgresRoot 'bin\postgres.exe'
$psqlExe=Join-Path $PostgresRoot 'bin\psql.exe'
$pgDumpExe=Join-Path $PostgresRoot 'bin\pg_dump.exe'
$pgRestoreExe=Join-Path $PostgresRoot 'bin\pg_restore.exe'
foreach($required in @($postgresExe,$psqlExe,$pgDumpExe,$pgRestoreExe)){
    if(-not(Test-Path -LiteralPath $required -PathType Leaf)){throw "Required PostgreSQL 18 runtime file is missing: $required"}
}
$postgresVersion=(& $postgresExe --version) -join "`n"
if($LASTEXITCODE -ne 0 -or $postgresVersion -notmatch 'PostgreSQL\) 18\.'){
    throw "PostgreSQL 18.x is required; detected: $postgresVersion"
}
$postgresServiceObject=Get-Service -Name $PostgresService -ErrorAction SilentlyContinue
if(-not $postgresServiceObject){throw "PostgreSQL Windows service was not found: $PostgresService"}
if($postgresServiceObject.Status -ne 'Running'){throw "PostgreSQL Windows service must be Running before installation: $PostgresService (current: $($postgresServiceObject.Status))"}
if (-not (Test-WindowsAbsolutePath $MediaRoot)) { throw 'MediaRoot must be an absolute Windows drive or UNC path.' }
if (-not (Test-Path -LiteralPath $MediaRoot)) { throw "MediaRoot does not exist: $MediaRoot" }
if (-not $PrepareOnly -and (Test-Path -LiteralPath (Join-Path $InstallRoot 'current'))) {
    $stopScript = Join-Path $PSScriptRoot '..\runtime\launchers\Stop-Immich.ps1'
    if (-not (Test-Path -LiteralPath $stopScript -PathType Leaf)) {
        throw "Cannot safely replace the existing Immich installation because its stop script is missing: $stopScript"
    }
    $installedEnv = Read-EnvFile $defaultEnvFile
    if ($installedEnv.IMMICH_WINDOWS_INSTALL_SCOPE -ne $Scope) { throw 'The selected scope does not match the installed environment.' }
    & $stopScript -EnvFile $defaultEnvFile -DataRoot $DataRoot -InstallRoot $InstallRoot
}
New-Item -ItemType Directory -Path $InstallRoot,$DataRoot -Force | Out-Null
$release = $null
if ($ResumeExistingRelease) {
    $release = Join-Path $InstallRoot "releases\$packageVersion"
    $installedManifestPath = Join-Path $release 'manifest.json'
    if (-not (Test-Path -LiteralPath $installedManifestPath -PathType Leaf)) { throw "Cannot resume; installed release manifest is missing: $installedManifestPath" }
    $installedManifest = Get-Content -Raw -LiteralPath $installedManifestPath | ConvertFrom-Json
    foreach ($field in @('packageVersion','sourceCommit','upstreamCommit','builtAtUtc')) {
        if ([string]$installedManifest.$field -ne [string]$packageManifest.$field) { throw "Cannot resume; installed package does not match the selected package ($field differs)." }
    }
    Write-Host "Resuming installation from $release"
} else {
    $release = Install-ReleaseDirectory -PackageRoot $PackageRoot -InstallRoot $InstallRoot
}
& (Join-Path $release 'installer\Install-RuntimeDependencies.ps1') -ReleaseRoot $release -InstallRoot $InstallRoot
& (Join-Path $PackageRoot 'runtime\launchers\Install-NodeDependencies.ps1') -ReleaseRoot $release -InstallRoot $InstallRoot
& (Join-Path $release 'installer\Install-MachineLearningDependencies.ps1') -ReleaseRoot $release -InstallRoot $InstallRoot
if ($PrepareOnly) { Write-Host "Candidate dependencies prepared: $release"; return }
$current = Join-Path $InstallRoot 'current'
if ($ApplicationOnly -and (-not $existingRelease -or -not (Test-ImmichDatabasePayloadEqual -PreviousRelease $existingRelease -CandidateRelease $release))) {
    throw 'Application-only update requires identical database-facing payloads.'
}
if (-not $ApplicationOnly) {
if (-not $SkipPostgresExtensionInstall -and $Scope -eq 'AllUsers') {
    & (Join-Path $PSScriptRoot 'Install-PostgresExtensions.ps1') -PackageRoot $release -PostgresRoot $PostgresRoot -PostgresService $PostgresService -AdminUser $DatabaseUser -DatabaseName $DatabaseName -AdminPassword $DatabasePassword -DatabaseHost $DatabaseHost -DatabasePort $DatabasePort
}
# A fresh native installation may not have the Immich database yet. Create only
# the empty database; upstream Immich remains authoritative for every schema
# object and migration. Migration restores may drop/recreate this database later.
$env:PGPASSWORD=$DatabasePassword
try {
    $databaseLiteral=$DatabaseName.Replace("'", "''")
    $databaseIdentifier=$DatabaseName.Replace('"','""')
    $userIdentifier=$DatabaseUser.Replace('"','""')
    $existsOutput=& $psqlExe -h $DatabaseHost -p $DatabasePort -U $DatabaseUser -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname='$databaseLiteral'"
    if($LASTEXITCODE -ne 0){throw 'Could not query PostgreSQL before native Immich database initialization.'}
    $exists=ConvertTo-TrimmedOutput -Output $existsOutput
    if($exists -ne '1'){
        & $psqlExe -h $DatabaseHost -p $DatabasePort -U $DatabaseUser -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE `"$databaseIdentifier`" OWNER `"$userIdentifier`";"
        if($LASTEXITCODE -ne 0){throw "Could not create native Immich database: $DatabaseName"}
        Write-Host "Created empty database $DatabaseName; upstream Immich migrations will initialize its schema."
    }
} finally {
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
}
if ($Scope -eq 'CurrentUser' -or $SkipPostgresExtensionInstall) {
    $env:PGPASSWORD = $DatabasePassword
    try {
        if ($Scope -eq 'CurrentUser') {
            & $psqlExe -h $DatabaseHost -p $DatabasePort -U $DatabaseUser -d $DatabaseName -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION IF NOT EXISTS vector; CREATE EXTENSION IF NOT EXISTS vchord;'
            if ($LASTEXITCODE -ne 0) { throw 'Could not initialize pgvector and VectorChord in the Immich database.' }
        }
        $preload = & $psqlExe -h $DatabaseHost -p $DatabasePort -U $DatabaseUser -d postgres -Atqc 'SHOW shared_preload_libraries'
        if ($LASTEXITCODE -ne 0 -or (ConvertTo-TrimmedOutput -Output $preload) -notmatch '(^|,)\s*vchord\s*(,|$)') {
            throw 'PostgreSQL must already load VectorChord in shared_preload_libraries.'
        }
        foreach ($extension in @('vector','vchord')) {
            $control = Join-Path $release "dependencies\postgres-extensions\$extension\$extension.control"
            $versionLine = Select-String -LiteralPath $control -Pattern "default_version\s*=\s*'([^']+)'" | Select-Object -First 1
            if (-not $versionLine) { throw "Could not read packaged $extension version." }
            $expected = $versionLine.Matches[0].Groups[1].Value
            $available = & $psqlExe -h $DatabaseHost -p $DatabasePort -U $DatabaseUser -d postgres -Atqc "SELECT default_version FROM pg_available_extensions WHERE name='$extension'"
            $installed = & $psqlExe -h $DatabaseHost -p $DatabasePort -U $DatabaseUser -d $DatabaseName -Atqc "SELECT extversion FROM pg_extension WHERE extname='$extension'"
            if ($LASTEXITCODE -ne 0 -or (ConvertTo-TrimmedOutput -Output $available) -ne $expected -or (ConvertTo-TrimmedOutput -Output $installed) -ne $expected) {
                throw "PostgreSQL $extension must be available and installed at version $expected."
            }
        }
    } finally { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue }
}
} # Database initialization/extensions are unnecessary for an identical server payload.
$cache = Join-Path $DataRoot 'cache'
$logs = Join-Path $DataRoot 'logs'
$valkeyData = Join-Path $DataRoot 'valkey'
$services = Join-Path $DataRoot 'services'
New-Item -ItemType Directory -Path $cache,$logs,$valkeyData,$services -Force | Out-Null
$managedEnvValues = [ordered]@{
    IMMICH_HOST = $(if ($sourceEnv['IMMICH_HOST']) { $sourceEnv['IMMICH_HOST'] } else { '0.0.0.0' })
    IMMICH_PORT = [string]$ServerPort
    IMMICH_MEDIA_LOCATION = $MediaRoot
    IMMICH_BUILD_DATA = (Join-Path $current 'build')
    IMMICH_MACHINE_LEARNING_URL = "http://127.0.0.1:$MachineLearningPort"
    IMMICH_ENV = 'production'
    IMMICH_SOURCE_REF = $packageManifest.immichVersion
    DB_HOSTNAME = $DatabaseHost
    DB_PORT = [string]$DatabasePort
    DB_DATABASE_NAME = $DatabaseName
    DB_USERNAME = $DatabaseUser
    DB_PASSWORD = $DatabasePassword
    DB_VECTOR_EXTENSION = 'vectorchord'
    POSTGRES_ROOT = $PostgresRoot
    POSTGRES_SERVICE = $PostgresService
    IMMICH_POSTGRES_BIN_DIR = (Join-Path $PostgresRoot 'bin')
    REDIS_HOSTNAME = $RedisHost
    REDIS_PORT = [string]$RedisPort
    IMMICH_WINDOWS_REDIS_MODE = $RedisMode
    IMMICH_WINDOWS_INSTALL_SCOPE = $Scope
    MACHINE_LEARNING_CACHE_FOLDER = $(if ($sourceEnv['MACHINE_LEARNING_CACHE_FOLDER']) { $sourceEnv['MACHINE_LEARNING_CACHE_FOLDER'] } else { $cache })
    MACHINE_LEARNING_WORKERS = $(if ($sourceEnv['MACHINE_LEARNING_WORKERS']) { $sourceEnv['MACHINE_LEARNING_WORKERS'] } else { '1' })
    MACHINE_LEARNING_ACCELERATOR = $MachineLearningAccelerator
    MACHINE_LEARNING_DEVICE_ID = [string]$MachineLearningDeviceId
    IMMICH_HOST_ML = $(if ($sourceEnv['IMMICH_HOST_ML']) { $sourceEnv['IMMICH_HOST_ML'] } else { '127.0.0.1' })
    IMMICH_PORT_ML = [string]$MachineLearningPort
    NO_COLOR = 'true'
}
$envFile = Join-Path $DataRoot 'immich.env'
$envValues = [ordered]@{}
foreach ($pair in $sourceEnv.GetEnumerator()) { $envValues[$pair.Key] = $pair.Value }
foreach ($pair in $managedEnvValues.GetEnumerator()) { $envValues[$pair.Key] = $pair.Value }
Write-EnvFile -Path $envFile -Values $envValues
Write-ImmichTrayConnectionHint -InstallRoot $InstallRoot -DataRoot $DataRoot
if ($Scope -eq 'AllUsers') { Protect-ImmichDataRoot -Path $DataRoot }
Set-CurrentReleaseJunction -InstallRoot $InstallRoot -ReleasePath $release
$valkeyConfig = Join-Path $DataRoot 'valkey.conf'
$valkeyServiceExe = Join-Path $current 'dependencies\valkey\ValkeyService.exe'
$serviceRestartDelays = @(5,15)
if ($Scope -eq 'AllUsers' -and (Get-Service -Name ImmichValkey -ErrorAction SilentlyContinue)) {
    Stop-Service -Name ImmichValkey -ErrorAction SilentlyContinue
    if (-not $ReuseServices -or $RedisMode -ne 'BundledValkey') {
        & $valkeyServiceExe uninstall --service-name ImmichValkey
        if ($LASTEXITCODE -ne 0) { throw 'Existing ImmichValkey service could not be removed for reconciliation.' }
    }
}
if ($RedisMode -eq 'BundledValkey') {
    if ($RedisHost -notin @('127.0.0.1','localhost','::1')) { throw 'BundledValkey requires a loopback RedisHost.' }
    $valkeyDataPath = if ($Scope -eq 'CurrentUser') { ConvertTo-MsysPath $valkeyData } else { $valkeyData.Replace('\','/') }
    $valkeyLogFile = Join-Path $logs 'valkey.log'
    $valkeyLogPath = if ($Scope -eq 'CurrentUser') { ConvertTo-MsysPath $valkeyLogFile } else { $valkeyLogFile.Replace('\','/') }
    Write-ImmichValkeyConfig -Path $valkeyConfig -DataPath $valkeyDataPath -LogPath $valkeyLogPath -Port $RedisPort -Password ([string]$envValues['REDIS_PASSWORD'])
    if ($Scope -eq 'AllUsers' -and (-not $ReuseServices -or -not (Get-Service -Name ImmichValkey -ErrorAction SilentlyContinue))) {
        & $valkeyServiceExe install -c $valkeyConfig --dir $valkeyData --port $RedisPort --service-name ImmichValkey --start-mode auto
        if ($LASTEXITCODE -ne 0) { throw 'Valkey service installation failed.' }
    }
    if ($Scope -eq 'AllUsers') {
        $valkeyRecoveryActions = (@($serviceRestartDelays | ForEach-Object { "restart/$($_ * 1000)" }) + 'run/0') -join '/'
        & sc.exe failure ImmichValkey reset= 86400 actions= $valkeyRecoveryActions command= "$env:SystemRoot\System32\cmd.exe /c exit 0"
        if ($LASTEXITCODE -ne 0) { throw 'Could not configure automatic Valkey service recovery.' }
        & sc.exe failureflag ImmichValkey flag=1
        if ($LASTEXITCODE -ne 0) { throw 'Could not configure Valkey recovery for nonzero service exits.' }
    }
} else {
    Write-Host "Using external Redis-compatible service at ${RedisHost}:$RedisPort; bundled ImmichValkey service is disabled."
}
if ($Scope -eq 'AllUsers') {
$machinePath = [Environment]::GetEnvironmentVariable('Path','Machine')
$sharpLibPath = Join-Path $current 'server\node_modules\@img\sharp-win32-x64\lib'
if (-not (Test-Path -LiteralPath $sharpLibPath -PathType Container)) { throw "Sharp runtime is missing: $sharpLibPath" }
$servicePath = (@($sharpLibPath,(Join-Path $current 'runtime\vc-runtime'),(Join-Path $current 'runtime\node'),(Join-Path $current 'runtime\ffmpeg'),$machinePath) | Where-Object { $_ }) -join ';'
function New-WinSWServiceXml {
    param(
        [string]$Id,
        [string]$Name,
        [string]$Executable,
        [string]$Arguments,
        [hashtable]$ExtraEnv,
        [string[]]$Depends = @()
    )
    $merged = [ordered]@{}

    foreach ($pair in $ExtraEnv.GetEnumerator()) { $merged[$pair.Key] = [string]$pair.Value }
    $xml = @(
        '<service>',
        ("  <id>{0}</id>" -f (ConvertTo-XmlValue $Id)),
        ("  <name>{0}</name>" -f (ConvertTo-XmlValue $Name)),
        '  <description>Native Windows Immich service managed by immich-windows.</description>',
        ("  <executable>{0}</executable>" -f (ConvertTo-XmlValue $Executable)),
        ("  <arguments>{0}</arguments>" -f (ConvertTo-XmlValue $Arguments)),
        ("  <workingdirectory>{0}</workingdirectory>" -f (ConvertTo-XmlValue $current)),
        '  <startmode>Automatic</startmode>',
        '  <stoptimeout>30 sec</stoptimeout>',
        ("  <logpath>{0}</logpath>" -f (ConvertTo-XmlValue $logs)),
        '  <log mode="roll-by-size"><sizeThreshold>10240</sizeThreshold><keepFiles>5</keepFiles></log>'
    )
    foreach ($delay in $serviceRestartDelays) { $xml += ('  <onfailure action="restart" delay="{0} sec"/>' -f $delay) }
    $xml += '  <onfailure action="none"/>'
    $xml += '  <resetfailure>1 day</resetfailure>'
    foreach ($dependency in $Depends) { $xml += ('  <depend>{0}</depend>' -f (ConvertTo-XmlValue $dependency)) }
    foreach ($pair in $merged.GetEnumerator()) {
        $xml += ('  <env name="{0}" value="{1}"/>' -f (ConvertTo-XmlValue $pair.Key), (ConvertTo-XmlValue ([string]$pair.Value)))
    }
    $xml += ('  <env name="PATH" value="{0}"/>' -f (ConvertTo-XmlValue $servicePath))
    $xml += '</service>'
    return $xml -join "`r`n"
}
$winswSource = Join-Path $current 'runtime\winsw\WinSW-x64.exe'
$serverExe = Join-Path $services 'ImmichServer.exe'; Copy-Item $winswSource $serverExe -Force
$serverXml = Join-Path $services 'ImmichServer.xml'
$previousServerConfiguration=if (Test-Path -LiteralPath $serverXml -PathType Leaf) { Get-Content -Raw -LiteralPath $serverXml } else { $null }
$serverDepends=@($PostgresService)
if($RedisMode -eq 'BundledValkey'){$serverDepends += 'ImmichValkey'}
$serviceHost = Join-Path $PSHOME 'pwsh.exe'
$loader = Join-Path $current 'runtime\launchers\Load-ImmichEnv.ps1'
New-WinSWServiceXml -Id 'ImmichServer' -Name 'Immich Server' -Executable $serviceHost -Arguments ("-NoProfile -File `"{0}`" -EnvFile `"{1}`" -ServiceRole Server" -f $loader,$envFile) -ExtraEnv @{} -Depends $serverDepends | Set-Content -Encoding utf8 -LiteralPath $serverXml
$mlExe = Join-Path $services 'ImmichMachineLearning.exe'; Copy-Item $winswSource $mlExe -Force
$mlXml = Join-Path $services 'ImmichMachineLearning.xml'
New-WinSWServiceXml -Id 'ImmichMachineLearning' -Name 'Immich Machine Learning' -Executable $serviceHost -Arguments ("-NoProfile -File `"{0}`" -EnvFile `"{1}`" -ServiceRole MachineLearning" -f $loader,$envFile) -ExtraEnv @{} | Set-Content -Encoding utf8 -LiteralPath $mlXml
foreach ($svc in @(@($serverExe,$serverXml),@($mlExe,$mlXml))) {
    $name = [IO.Path]::GetFileNameWithoutExtension($svc[0])
    $existingService=Get-Service -Name $name -ErrorAction SilentlyContinue
    if ($existingService -and -not $ReuseServices) { & $svc[0] stop 2>$null; & $svc[0] uninstall }
    if (-not $existingService -or -not $ReuseServices) {
        & $svc[0] install
        if ($LASTEXITCODE -ne 0) { throw "Failed to install $name" }
    } elseif ($name -eq 'ImmichServer') {
        Set-ImmichServerDependencies -Configuration (Get-Content -Raw -LiteralPath $serverXml) -PreviousConfiguration $previousServerConfiguration
    }
}
}
if (-not $DoNotStart) {
    & (Join-Path $current 'runtime\launchers\Start-Immich.ps1') -EnvFile $envFile -InstallRoot $InstallRoot -DataRoot $DataRoot
}
if ($Scope -eq 'CurrentUser') { Set-ImmichUserStartup -InstallRoot $InstallRoot -DataRoot $DataRoot -Enabled $true }
Remove-ImmichLegacyStartMenu -Scope $Scope
Set-ImmichTrayStartup -InstallRoot $InstallRoot -DataRoot $DataRoot -Scope $Scope
if (-not $DoNotStart) { Start-ImmichTray -InstallRoot $InstallRoot -DataRoot $DataRoot -Scope $Scope }
Write-Host 'For daily controls, use the Immich icon in the Windows notification area (including the hidden-icons arrow).'
Write-Host "Installed native Immich for $Scope from $release"
Write-Host "Persistent config: $envFile"
} catch {
    if ($ElevationFailureReport) {
        [IO.File]::WriteAllText($ElevationFailureReport, ($_ | Out-String).Trim())
    }
    throw
}
