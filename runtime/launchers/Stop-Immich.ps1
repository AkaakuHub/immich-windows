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
    $processRoots=@((Join-Path $InstallRoot 'current'),(Resolve-Path -LiteralPath (Join-Path $InstallRoot 'current')).Path)
    $processNames = @('ImmichServer','ImmichMachineLearning')
    if ($shouldStopValkey) {
        $processNames += 'ImmichValkey'
    }
    foreach ($name in $processNames) {
        if ($name -eq 'ImmichValkey') {
            $valkeyCli = Join-Path $processRoots[-1] 'dependencies\valkey\valkey-cli.exe'
            & $valkeyCli -h $env:REDIS_HOSTNAME -p $env:REDIS_PORT shutdown save | Out-Null
        }
        $pidFile = Join-Path $DataRoot "services\$name.pid"
        if (-not (Test-Path -LiteralPath $pidFile)) { continue }
        $processId = [int](Get-Content -Raw -LiteralPath $pidFile)
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($process -and $process.Path -and @($processRoots|Where-Object{$process.Path.StartsWith($_,[StringComparison]::OrdinalIgnoreCase)}).Count -gt 0) {
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
