#requires -Version 7.0
[CmdletBinding()]
param([string]$EnvFile='C:\ProgramData\Immich\immich.env',[string]$InstallRoot='C:\Program Files\Immich')
$admin=Join-Path $InstallRoot 'current\runtime\launchers\immich-admin.ps1'
$output = @(& $admin -EnvFile $EnvFile schema-check)
$output | Out-Host
if($LASTEXITCODE -ne 0 -or ($output -match 'Detected schema drift')){throw 'Immich schema-check failed.'}
