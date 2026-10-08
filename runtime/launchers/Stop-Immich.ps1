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

function Stop-ImmichMachineLearningProcesses {
    $roots = @(
        (Join-Path $InstallRoot 'current'),
        (Join-Path $InstallRoot 'releases')
    )
    $pythonProcesses = Get-CimInstance Win32_Process -Filter "Name='python.exe'" | Where-Object {
        $path = [string]$_.ExecutablePath
        $commandLine = [string]$_.CommandLine
        $packagedPath = $path -and ($roots | Where-Object { $path.StartsWith($_.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) }) -and
            $path -match '\\machine-learning\\python-runtime\\'
        $mlSupervisor = $commandLine -match '\s-m\s+immich_ml(?:\s|$)'
        $packagedPath -or $mlSupervisor
    }
    foreach ($process in $pythonProcesses) {
        & taskkill.exe /PID $process.ProcessId /T /F | Out-Host
        if ($LASTEXITCODE -ne 0 -and (Get-Process -Id $process.ProcessId -ErrorAction SilentlyContinue)) {
            throw "Could not stop Immich Machine Learning process tree $($process.ProcessId)."
        }
    }
}

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
                if (-not $process.WaitForExit(30000)) { throw 'Valkey did not finish its graceful save and shutdown.' }
            }
        }
        $pidFile = Join-Path $DataRoot "services\$name.pid"
        if (-not (Test-Path -LiteralPath $pidFile)) { continue }
        if ($process -and -not $process.HasExited) {
            & taskkill.exe /PID $process.Id /T /F | Out-Host
            if ($LASTEXITCODE -ne 0 -and -not $process.HasExited) { throw "Could not stop process tree $name." }
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

Stop-ImmichMachineLearningProcesses

# Native process races that are verified as already exited are successful stops.
exit 0
