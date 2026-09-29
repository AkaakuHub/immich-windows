#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$InstallRoot='C:\Program Files\Immich',
    [string]$DataRoot='C:\ProgramData\Immich',
    [string]$PostgresRoot='C:\Program Files\PostgreSQL\18',
    [Parameter(Mandatory)][string]$MediaRoot,
    [string[]]$SharpFixture
)
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'Static-RepositoryAudit.ps1')
& (Join-Path $PSScriptRoot 'Smoke-Windows.ps1') -InstallRoot $InstallRoot -DataRoot $DataRoot -PostgresRoot $PostgresRoot -SharpFixture $SharpFixture
& (Join-Path $PSScriptRoot '..\migration\Verify-Migration.ps1') -MediaRoot $MediaRoot -EnvFile (Join-Path $DataRoot 'immich.env') -PostgresRoot $PostgresRoot
Write-Host 'Release qualification checks passed.'
