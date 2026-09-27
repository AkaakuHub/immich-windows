[CmdletBinding()]
param(
    [int]$TimeoutSeconds = 120,
    [string]$EnvFile = 'C:\ProgramData\Immich\immich.env'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$loader = Join-Path $PSScriptRoot 'Load-ImmichEnv.ps1'
if (Test-Path -LiteralPath $EnvFile) {
    . $loader -EnvFile $EnvFile
}

$redisMode = if ($env:IMMICH_WINDOWS_REDIS_MODE) { $env:IMMICH_WINDOWS_REDIS_MODE } else { 'BundledValkey' }
if ($redisMode -eq 'BundledValkey') {
    if (-not (Get-Service -Name ImmichValkey -ErrorAction SilentlyContinue)) {
        throw 'IMMICH_WINDOWS_REDIS_MODE=BundledValkey but the ImmichValkey service is not installed.'
    }
    Start-Service ImmichValkey
} elseif ($redisMode -ne 'External') {
    throw "Unsupported IMMICH_WINDOWS_REDIS_MODE: $redisMode"
}

foreach ($serviceName in @('ImmichMachineLearning', 'ImmichServer')) {
    if (-not (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)) {
        throw "Required Windows service is not installed: $serviceName"
    }
    Start-Service $serviceName
}

$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
while ([DateTime]::UtcNow -lt $deadline) {
    try {
        $ml = Invoke-WebRequest -UseBasicParsing http://127.0.0.1:3003/ping -TimeoutSec 3
        $server = Invoke-WebRequest -UseBasicParsing http://127.0.0.1:2283/api/server-info/ping -TimeoutSec 3
        if ($ml.StatusCode -eq 200 -and $server.StatusCode -eq 200) {
            Write-Host "Immich Server and ML are healthy (Redis mode: $redisMode)."
            exit 0
        }
    } catch {}
    Start-Sleep 2
}

throw "Immich health checks did not become ready within $TimeoutSeconds seconds (Redis mode: $redisMode)."
