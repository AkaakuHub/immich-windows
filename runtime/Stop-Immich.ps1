[CmdletBinding()]
param(
    [switch]$IncludeValkey,
    [string]$EnvFile = 'C:\ProgramData\Immich\immich.env'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($name in @('ImmichServer', 'ImmichMachineLearning')) {
    if (Get-Service $name -ErrorAction SilentlyContinue) {
        Stop-Service $name -Force -ErrorAction SilentlyContinue
    }
}

$redisMode = $null
if (Test-Path -LiteralPath $EnvFile) {
    . (Join-Path $PSScriptRoot 'Load-ImmichEnv.ps1') -EnvFile $EnvFile
    $redisMode = $env:IMMICH_WINDOWS_REDIS_MODE
}

$shouldStopValkey = $IncludeValkey -or $redisMode -eq 'BundledValkey'
if ($shouldStopValkey -and (Get-Service ImmichValkey -ErrorAction SilentlyContinue)) {
    Stop-Service ImmichValkey -Force -ErrorAction SilentlyContinue
}
