[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackageRoot,
    [Parameter(Mandatory)][string]$MediaRoot,
    [Parameter(Mandatory)][string]$DatabasePassword,
    [string]$InstallRoot = 'C:\Program Files\Immich',
    [string]$DataRoot = 'C:\ProgramData\Immich',
    [string]$PostgresRoot = 'C:\Program Files\PostgreSQL\18',
    [string]$PostgresService = 'postgresql-x64-18',
    [string]$DatabaseName = 'immich',
    [string]$DatabaseUser = 'postgres',
    [string]$DatabaseHost = '127.0.0.1',
    [ValidateRange(1,65535)][int]$DatabasePort = 5432,
    [ValidateSet('BundledValkey','External')][string]$RedisMode = 'BundledValkey',
    [string]$RedisHost = '127.0.0.1',
    [int]$RedisPort = 6379,
    [switch]$SkipPostgresExtensionInstall,
    [switch]$AllowUnqualifiedMediaStack,
    [switch]$ResumeExistingRelease,
    [switch]$PreserveExistingEnv,
    [switch]$ReuseServices,
    [switch]$DoNotStart
)
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
Assert-Administrator
$PackageRoot = (Resolve-Path $PackageRoot).Path
$packageManifestPath=Join-Path $PackageRoot 'manifest.json'
if(-not(Test-Path -LiteralPath $packageManifestPath -PathType Leaf)){throw "Package manifest is missing: $packageManifestPath"}
$packageManifest=Get-Content -Raw -LiteralPath $packageManifestPath|ConvertFrom-Json
if([string]$packageManifest.target -ne 'windows-x64-native'){throw "Unsupported package target: $($packageManifest.target)"}
if(-not $AllowUnqualifiedMediaStack -and -not [bool]$packageManifest.mediaStack.productionQualified){
    throw 'Package media stack is not production-qualified. Use -AllowUnqualifiedMediaStack only for isolated bring-up testing.'
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
New-Item -ItemType Directory -Path $InstallRoot,$DataRoot -Force | Out-Null
$release = $null
if ($ResumeExistingRelease) {
    $release = Join-Path $InstallRoot "releases\$($packageManifest.immichVersion)"
    $installedManifestPath = Join-Path $release 'manifest.json'
    if (-not (Test-Path -LiteralPath $installedManifestPath -PathType Leaf)) { throw "Cannot resume; installed release manifest is missing: $installedManifestPath" }
    $installedManifest = Get-Content -Raw -LiteralPath $installedManifestPath | ConvertFrom-Json
    foreach ($field in @('immichVersion','upstreamCommit','builtAtUtc')) {
        if ([string]$installedManifest.$field -ne [string]$packageManifest.$field) { throw "Cannot resume; installed package does not match the selected package ($field differs)." }
    }
    Write-Host "Resuming installation from $release"
} else {
    $release = Install-ReleaseDirectory -PackageRoot $PackageRoot -InstallRoot $InstallRoot
}
Set-CurrentReleaseJunction -InstallRoot $InstallRoot -ReleasePath $release
$current = Join-Path $InstallRoot 'current'
if (-not $SkipPostgresExtensionInstall) {
    & (Join-Path $PSScriptRoot 'Install-PostgresExtensions.ps1') -PackageRoot $current -PostgresRoot $PostgresRoot -PostgresService $PostgresService -AdminUser $DatabaseUser -DatabaseName $DatabaseName -AdminPassword $DatabasePassword -DatabaseHost $DatabaseHost -DatabasePort $DatabasePort
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
$cache = Join-Path $DataRoot 'cache'
$logs = Join-Path $DataRoot 'logs'
$valkeyData = Join-Path $DataRoot 'valkey'
$services = Join-Path $DataRoot 'services'
New-Item -ItemType Directory -Path $cache,$logs,$valkeyData,$services -Force | Out-Null
$managedEnvValues = [ordered]@{
    IMMICH_HOST = '0.0.0.0'
    IMMICH_PORT = '2283'
    IMMICH_MEDIA_LOCATION = $MediaRoot
    IMMICH_BUILD_DATA = (Join-Path $current 'build')
    IMMICH_MACHINE_LEARNING_URL = 'http://127.0.0.1:3003'
    IMMICH_ENV = 'production'
    IMMICH_SOURCE_REF = (Get-Content -Raw (Join-Path $current 'manifest.json') | ConvertFrom-Json).immichVersion
    DB_HOSTNAME = $DatabaseHost
    DB_PORT = [string]$DatabasePort
    DB_DATABASE_NAME = $DatabaseName
    DB_USERNAME = $DatabaseUser
    DB_PASSWORD = $DatabasePassword
    DB_VECTOR_EXTENSION = 'vectorchord'
    IMMICH_POSTGRES_BIN_DIR = (Join-Path $PostgresRoot 'bin')
    REDIS_HOSTNAME = $RedisHost
    REDIS_PORT = [string]$RedisPort
    IMMICH_WINDOWS_REDIS_MODE = $RedisMode
    MACHINE_LEARNING_CACHE_FOLDER = $cache
    MACHINE_LEARNING_WORKERS = '1'
    IMMICH_HOST_ML = '127.0.0.1'
    IMMICH_PORT_ML = '3003'
    NO_COLOR = 'true'
}
$envFile = Join-Path $DataRoot 'immich.env'
$envValues = [ordered]@{}
if ($PreserveExistingEnv) {
    foreach ($pair in (Read-EnvFile $envFile).GetEnumerator()) { $envValues[$pair.Key] = $pair.Value }
}
foreach ($pair in $managedEnvValues.GetEnumerator()) { $envValues[$pair.Key] = $pair.Value }
Write-EnvFile -Path $envFile -Values $envValues
Protect-ImmichDataRoot -Path $DataRoot
$valkeyConfig = Join-Path $DataRoot 'valkey.conf'
$valkeyServiceExe = Join-Path $current 'dependencies\valkey\ValkeyService.exe'
if (Get-Service -Name ImmichValkey -ErrorAction SilentlyContinue) {
    Stop-Service -Name ImmichValkey -ErrorAction SilentlyContinue
    if (-not $ReuseServices -or $RedisMode -ne 'BundledValkey') {
        & $valkeyServiceExe uninstall --service-name ImmichValkey
        if ($LASTEXITCODE -ne 0) { throw 'Existing ImmichValkey service could not be removed for reconciliation.' }
    }
}
if ($RedisMode -eq 'BundledValkey') {
    if ($RedisHost -notin @('127.0.0.1','localhost','::1')) { throw 'BundledValkey requires a loopback RedisHost.' }
    @("bind 127.0.0.1 ::1","protected-mode yes","port $RedisPort","dir $($valkeyData.Replace('\','/'))","dbfilename dump.rdb","save 900 1","save 300 10","save 60 10000","logfile $((Join-Path $logs 'valkey.log').Replace('\','/'))") | Set-Content -Encoding ascii -LiteralPath $valkeyConfig
    if (-not $ReuseServices -or -not (Get-Service -Name ImmichValkey -ErrorAction SilentlyContinue)) {
        & $valkeyServiceExe install -c $valkeyConfig --dir $valkeyData --port $RedisPort --service-name ImmichValkey --start-mode auto
        if ($LASTEXITCODE -ne 0) { throw 'Valkey service installation failed.' }
    }
} else {
    Write-Host "Using external Redis-compatible service at ${RedisHost}:$RedisPort; bundled ImmichValkey service is disabled."
}
$machinePath = [Environment]::GetEnvironmentVariable('Path','Machine')
$sharpPackage = Get-ChildItem -LiteralPath (Join-Path $current 'server\node_modules\.pnpm') -Directory -Filter '@img+sharp-win32-x64@*' -ErrorAction SilentlyContinue | Select-Object -First 1
$sharpLibPath = if ($sharpPackage) { Join-Path $sharpPackage.FullName 'node_modules\@img\sharp-win32-x64\lib' }
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
    foreach ($pair in $envValues.GetEnumerator()) { $merged[$pair.Key] = [string]$pair.Value }
    foreach ($pair in $ExtraEnv.GetEnumerator()) { $merged[$pair.Key] = [string]$pair.Value }
    $xml = @(
        '<service>',
        ("  <id>{0}</id>" -f (Escape-XmlValue $Id)),
        ("  <name>{0}</name>" -f (Escape-XmlValue $Name)),
        '  <description>Native Windows Immich service managed by immich-windows.</description>',
        ("  <executable>{0}</executable>" -f (Escape-XmlValue $Executable)),
        ("  <arguments>{0}</arguments>" -f (Escape-XmlValue $Arguments)),
        ("  <workingdirectory>{0}</workingdirectory>" -f (Escape-XmlValue $current)),
        '  <startmode>Automatic</startmode>',
        '  <onfailure action="restart" delay="5 sec"/>',
        '  <stoptimeout>30 sec</stoptimeout>',
        ("  <logpath>{0}</logpath>" -f (Escape-XmlValue $logs)),
        '  <log mode="roll-by-size"><sizeThreshold>10240</sizeThreshold><keepFiles>5</keepFiles></log>'
    )
    foreach ($dependency in $Depends) { $xml += ('  <depend>{0}</depend>' -f (Escape-XmlValue $dependency)) }
    foreach ($pair in $merged.GetEnumerator()) {
        $xml += ('  <env name="{0}" value="{1}"/>' -f (Escape-XmlValue $pair.Key), (Escape-XmlValue ([string]$pair.Value)))
    }
    $xml += ('  <env name="PATH" value="{0}"/>' -f (Escape-XmlValue $servicePath))
    $xml += '</service>'
    return $xml -join "`r`n"
}
$winswSource = Join-Path $current 'runtime\winsw\WinSW-x64.exe'
$serverExe = Join-Path $services 'ImmichServer.exe'; Copy-Item $winswSource $serverExe -Force
$serverXml = Join-Path $services 'ImmichServer.xml'
$serverDepends=@($PostgresService)
if($RedisMode -eq 'BundledValkey'){$serverDepends += 'ImmichValkey'}
New-WinSWServiceXml -Id 'ImmichServer' -Name 'Immich Server' -Executable (Join-Path $current 'runtime\node\node.exe') -Arguments ("`"{0}`"" -f (Join-Path $current 'server\dist\main.js')) -ExtraEnv @{
    FFMPEG_PATH = Join-Path $current 'runtime\ffmpeg\ffmpeg.exe'
    FFPROBE_PATH = Join-Path $current 'runtime\ffmpeg\ffprobe.exe'
} -Depends $serverDepends | Set-Content -Encoding utf8 -LiteralPath $serverXml
$python = Get-ChildItem (Join-Path $current 'machine-learning\python-runtime') -Filter python.exe -File -Recurse | Where-Object { $_.FullName -notmatch '\\Scripts\\' } | Select-Object -First 1
if (-not $python) { throw 'Packaged machine-learning Python runtime not found.' }
$mlExe = Join-Path $services 'ImmichMachineLearning.exe'; Copy-Item $winswSource $mlExe -Force
$mlXml = Join-Path $services 'ImmichMachineLearning.xml'
New-WinSWServiceXml -Id 'ImmichMachineLearning' -Name 'Immich Machine Learning' -Executable $python.FullName -Arguments '-m immich_ml' -ExtraEnv @{ IMMICH_HOST='127.0.0.1'; IMMICH_PORT='3003' } | Set-Content -Encoding utf8 -LiteralPath $mlXml
foreach ($svc in @(@($serverExe,$serverXml),@($mlExe,$mlXml))) {
    $name = [IO.Path]::GetFileNameWithoutExtension($svc[0])
    $existingService=Get-Service -Name $name -ErrorAction SilentlyContinue
    if ($existingService -and -not $ReuseServices) { & $svc[0] stop 2>$null; & $svc[0] uninstall }
    if (-not $existingService -or -not $ReuseServices) {
        & $svc[0] install
        if ($LASTEXITCODE -ne 0) { throw "Failed to install $name" }
    }
}
if (-not $DoNotStart) {
    if($RedisMode -eq 'BundledValkey'){Start-Service ImmichValkey}
    Start-Service ImmichMachineLearning
    Start-Service ImmichServer
    Wait-HttpOk 'http://127.0.0.1:3003/ping' 120
    Wait-HttpOk 'http://127.0.0.1:2283/api/server/ping' 120
}
Write-Host "Installed native Immich from $release"
Write-Host "Persistent config: $envFile"
