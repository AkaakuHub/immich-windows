[CmdletBinding()]
param(
    [string]$EnvFile = 'C:\ProgramData\Immich\immich.env',
    [string]$DataRoot = 'C:\ProgramData\Immich',
    [string]$InstallRoot = 'C:\Program Files\Immich'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$redisMode = $null
if (Test-Path -LiteralPath $EnvFile) {
    . (Join-Path $PSScriptRoot 'Load-ImmichEnv.ps1') -EnvFile $EnvFile
    $redisMode = $env:IMMICH_WINDOWS_REDIS_MODE
}

$shouldStopValkey = $redisMode -eq 'BundledValkey'
if ($env:IMMICH_WINDOWS_INSTALL_SCOPE -eq 'CurrentUser') {
    $processNames = @('ImmichServer','ImmichMachineLearning')
    if ($shouldStopValkey) {
        $valkeyCli = Join-Path (Resolve-Path -LiteralPath (Join-Path $InstallRoot 'current')).Path 'dependencies\valkey\valkey-cli.exe'
        & $valkeyCli -h $env:REDIS_HOSTNAME -p $env:REDIS_PORT shutdown save | Out-Null
        $processNames += 'ImmichValkey'
    }
    foreach ($name in $processNames) {
        $pidFile = Join-Path $DataRoot "services\$name.pid"
        if (-not (Test-Path -LiteralPath $pidFile)) { continue }
        $processId = [int](Get-Content -Raw -LiteralPath $pidFile)
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($process -and $process.Path -and $process.Path.StartsWith((Resolve-Path -LiteralPath $InstallRoot).Path,[StringComparison]::OrdinalIgnoreCase)) {
            Stop-Process -Id $processId -Force
        }
        Remove-Item -LiteralPath $pidFile -Force
    }
} else {
    foreach ($name in @('ImmichServer', 'ImmichMachineLearning')) {
        if (Get-Service $name -ErrorAction SilentlyContinue) { Stop-Service $name -Force -ErrorAction SilentlyContinue }
    }
    if ($shouldStopValkey -and (Get-Service ImmichValkey -ErrorAction SilentlyContinue)) {
        Stop-Service ImmichValkey -Force -ErrorAction SilentlyContinue
    }
}
