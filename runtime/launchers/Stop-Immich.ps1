#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$EnvFile = 'C:\ProgramData\Immich\immich.env',
    [string]$DataRoot = 'C:\ProgramData\Immich',
    [string]$InstallRoot = 'C:\Program Files\Immich'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Load-ImmichEnv.ps1') -EnvFile $EnvFile
$redisMode = $env:IMMICH_WINDOWS_REDIS_MODE

$shouldStopValkey = $redisMode -eq 'BundledValkey'
if ($env:IMMICH_WINDOWS_INSTALL_SCOPE -eq 'CurrentUser') {
    $processNames = @('ImmichServer','ImmichMachineLearning')
    if ($shouldStopValkey) {
        $processNames += 'ImmichValkey'
    }
    foreach ($name in $processNames) {
        $process = Get-ImmichUserProcess -InstallRoot $InstallRoot -DataRoot $DataRoot -Name $name
        if ($name -eq 'ImmichValkey') {
            if ($process) {
                $valkeyCli = Join-Path $InstallRoot 'current\dependencies\valkey\valkey-cli.exe'
                Invoke-ImmichValkey -Executable $valkeyCli -Hostname $env:REDIS_HOSTNAME -Port $env:REDIS_PORT -Password $env:REDIS_PASSWORD -Username $env:REDIS_USERNAME -Command @('shutdown','save') | Out-Null
            }
        }
        $pidFile = Join-Path $DataRoot "services\$name.pid"
        if (-not (Test-Path -LiteralPath $pidFile)) { continue }
        if ($process -and -not $process.HasExited) {
            Stop-Process -InputObject $process -Force
            if (-not $process.WaitForExit(30000)) { throw "Process $name did not stop." }
        }
        Remove-Item -LiteralPath $pidFile -Force
    }
} elseif ($env:IMMICH_WINDOWS_INSTALL_SCOPE -eq 'AllUsers') {
    $names=@('ImmichServer','ImmichMachineLearning')
    if ($shouldStopValkey) { $names += 'ImmichValkey' }
    foreach ($name in $names) {
        $service=Get-Service $name -ErrorAction SilentlyContinue
        if ($service -and $service.Status -ne 'Stopped') {
            Stop-Service $name -Force
            $service.WaitForStatus('Stopped',[TimeSpan]::FromSeconds(60))
        }
    }
} else {
    throw "Unsupported IMMICH_WINDOWS_INSTALL_SCOPE: $($env:IMMICH_WINDOWS_INSTALL_SCOPE)"
}
