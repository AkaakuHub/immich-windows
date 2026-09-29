#requires -Version 7.0
[CmdletBinding()]
param([string]$EnvFile='C:\ProgramData\Immich\immich.env',[string]$InstallRoot='C:\Program Files\Immich')
$admin=Join-Path $InstallRoot 'current\runtime\launchers\immich-admin.ps1'
& $admin -EnvFile $EnvFile schema-check
if($LASTEXITCODE -ne 0){throw 'Immich schema-check failed.'}
