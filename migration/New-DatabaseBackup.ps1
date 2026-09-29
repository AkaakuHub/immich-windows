#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$EnvFile='C:\ProgramData\Immich\immich.env',
    [string]$PostgresRoot='C:\Program Files\PostgreSQL\18',
    [string]$DestinationDirectory
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\runtime\Common.psm1') -Force
$envs=Read-EnvFile $EnvFile
if (-not $DestinationDirectory) { $DestinationDirectory=Join-Path (Split-Path -Parent (Resolve-Path -LiteralPath $EnvFile).Path) 'database-backups' }
New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
$pgDump=Join-Path $PostgresRoot 'bin\pg_dump.exe'
if(-not(Test-Path $pgDump)){throw "pg_dump.exe not found: $pgDump"}
$file=Join-Path $DestinationDirectory ("immich-native-{0}.dump" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$env:PGPASSWORD=[string]$envs.DB_PASSWORD
try {
    & $pgDump -h $envs.DB_HOSTNAME -p $envs.DB_PORT -U $envs.DB_USERNAME -d $envs.DB_DATABASE_NAME -Fc --no-owner --file $file
    if($LASTEXITCODE -ne 0){throw 'pg_dump failed.'}
} finally { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue }
if((Get-Item $file).Length -eq 0){throw 'Backup is empty.'}
Write-Output $file
