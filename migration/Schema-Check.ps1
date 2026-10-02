#requires -Version 7.0
[CmdletBinding()]
param([string]$EnvFile='C:\ProgramData\Immich\immich.env',[string]$InstallRoot='C:\Program Files\Immich')
$admin=Join-Path $InstallRoot 'current\runtime\launchers\immich-admin.ps1'
$previousOutputEncoding = [Console]::OutputEncoding
try {
    # The isolated qualification process decodes UTF-8. Windows pwsh may start
    # with an OEM code page even when its stdout/stderr handles are redirected.
    # This also makes the admin launcher's native Node output decode correctly.
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    $output = @(& $admin -EnvFile $EnvFile schema-check)
    $output | Out-Host
    if($LASTEXITCODE -ne 0 -or ($output -match 'Detected schema drift')){throw 'Immich schema-check failed.'}
} finally { [Console]::OutputEncoding = $previousOutputEncoding }
