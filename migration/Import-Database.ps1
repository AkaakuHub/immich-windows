[CmdletBinding()]
param(
    [Parameter(Mandatory)][Alias('BackupPath')][string]$Backup,
    [string]$EnvFile='C:\ProgramData\Immich\immich.env',
    [string]$PostgresRoot='C:\Program Files\PostgreSQL\18'
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\runtime\Common.psm1') -Force
$Backup=(Resolve-Path -LiteralPath $Backup).Path
$envs=Read-EnvFile $EnvFile
$psql=Join-Path $PostgresRoot 'bin\psql.exe'; $pgRestore=Join-Path $PostgresRoot 'bin\pg_restore.exe'
foreach($f in @($psql,$pgRestore)){if(-not(Test-Path $f)){throw "PostgreSQL client missing: $f"}}
if ($Backup.EndsWith('.dump',[StringComparison]::OrdinalIgnoreCase)) {
    & $pgRestore --list $Backup | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'The PostgreSQL custom-format backup cannot be read.' }
} elseif ($Backup.EndsWith('.sql',[StringComparison]::OrdinalIgnoreCase) -or
          $Backup.EndsWith('.sql.gz',[StringComparison]::OrdinalIgnoreCase) -or
          $Backup.EndsWith('.gz',[StringComparison]::OrdinalIgnoreCase)) {
    if ((Get-Item -LiteralPath $Backup).Length -eq 0) { throw 'The SQL backup is empty.' }
} else { throw 'Supported backup types are .dump, .sql, and .sql.gz.' }
$tempSql=$null
$sqlBackup=$Backup
$previousPassword=$env:PGPASSWORD
try {
if ($Backup.EndsWith('.gz',[StringComparison]::OrdinalIgnoreCase)) {
    $tempSql=Join-Path (Split-Path -Parent $Backup) ("immich-restore-"+[guid]::NewGuid().ToString('N')+".sql")
    $fs=[IO.File]::OpenRead($Backup)
    try {
        $gz=[IO.Compression.GZipStream]::new($fs,[IO.Compression.CompressionMode]::Decompress)
        try {
            $out=[IO.File]::Create($tempSql)
            try{$gz.CopyTo($out)}finally{$out.Dispose()}
        } finally {$gz.Dispose()}
    } finally {$fs.Dispose()}
    if ((Get-Item -LiteralPath $tempSql).Length -eq 0) { throw 'The decompressed SQL backup is empty.' }
    $sqlBackup=$tempSql
}
if ([string]$envs.IMMICH_WINDOWS_INSTALL_SCOPE -eq 'CurrentUser') {
    $stopScript=Join-Path $PSScriptRoot '..\runtime\launchers\Stop-Immich.ps1'
    if(-not(Test-Path -LiteralPath $stopScript -PathType Leaf)){throw 'CurrentUser Immich stop script was not found.'}
    $dataRoot=Split-Path -Parent (Resolve-Path -LiteralPath $EnvFile).Path
    $currentRoot=if($envs.IMMICH_BUILD_DATA){Split-Path -Parent ([string]$envs.IMMICH_BUILD_DATA)}else{Join-Path $env:LOCALAPPDATA 'Programs\Immich\current'}
    $installRoot=Split-Path -Parent $currentRoot
    & $stopScript -EnvFile $EnvFile -DataRoot $dataRoot -InstallRoot $installRoot
} else {
    foreach($name in @('ImmichServer','ImmichMachineLearning')){
        $service=Get-Service $name -ErrorAction SilentlyContinue
        if($service -and $service.Status -ne 'Stopped'){
            Stop-Service $name -ErrorAction Stop
            $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped,[TimeSpan]::FromSeconds(60))
        }
    }
}
$env:PGPASSWORD=[string]$envs.DB_PASSWORD
    $adminArgs=@('-h',$envs.DB_HOSTNAME,'-p',$envs.DB_PORT,'-U',$envs.DB_USERNAME,'-d','postgres','-v','ON_ERROR_STOP=1')
    $databaseLiteral=([string]$envs.DB_DATABASE_NAME).Replace("'","''")
    $databaseIdentifier=([string]$envs.DB_DATABASE_NAME).Replace('"','""')
    & $psql @adminArgs -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$databaseLiteral' AND pid <> pg_backend_pid();"
    if($LASTEXITCODE -ne 0){throw 'Could not terminate sessions connected to the target database.'}
    & $psql @adminArgs -c "DROP DATABASE IF EXISTS `"$databaseIdentifier`";"
    if($LASTEXITCODE -ne 0){throw 'Could not drop the target database.'}
    & $psql @adminArgs -c "CREATE DATABASE `"$databaseIdentifier`";"
    if($LASTEXITCODE -ne 0){throw 'Could not recreate the target database.'}
    if($Backup.EndsWith('.dump',[StringComparison]::OrdinalIgnoreCase)) {
        & $pgRestore -h $envs.DB_HOSTNAME -p $envs.DB_PORT -U $envs.DB_USERNAME -d $envs.DB_DATABASE_NAME --no-owner --exit-on-error $Backup
        if($LASTEXITCODE -ne 0){throw 'pg_restore failed.'}
    } else {
        & $psql -h $envs.DB_HOSTNAME -p $envs.DB_PORT -U $envs.DB_USERNAME -d $envs.DB_DATABASE_NAME -v ON_ERROR_STOP=1 -f $sqlBackup
        if($LASTEXITCODE -ne 0){throw 'psql restore failed.'}
    }
} finally {
    $env:PGPASSWORD=$previousPassword
    if ($tempSql) { Remove-Item -LiteralPath $tempSql -Force -ErrorAction SilentlyContinue }
}
Write-Host "Database restored from $Backup. Do not start Immich until media-path migration is complete."
