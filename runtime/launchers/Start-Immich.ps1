#requires -Version 7.0
[CmdletBinding()]
param(
    [int]$TimeoutSeconds = 120,
    [string]$EnvFile = (Join-Path $env:LOCALAPPDATA 'Immich\immich.env'),
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\Immich'),
    [string]$DataRoot = (Join-Path $env:LOCALAPPDATA 'Immich'),
    [switch]$UpgradeInProgress
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Load-ImmichEnv.ps1') -EnvFile $EnvFile
Assert-ImmichStartupAllowed -EnvFile $EnvFile -InstallRoot $InstallRoot -UpgradeInProgress:$UpgradeInProgress

$redisMode = if ($env:IMMICH_WINDOWS_REDIS_MODE) { $env:IMMICH_WINDOWS_REDIS_MODE } else { 'BundledValkey' }
$startupProcesses = [ordered]@{}
$startupLogs = [ordered]@{}
try {
    if ($env:IMMICH_WINDOWS_INSTALL_SCOPE -eq 'CurrentUser') {
        $current = (Resolve-Path -LiteralPath (Join-Path $InstallRoot 'current')).Path
        $services = Join-Path $DataRoot 'services'
        New-Item -ItemType Directory -Path $services -Force | Out-Null
        $logs = Join-Path $DataRoot 'logs'
        New-Item -ItemType Directory -Path $logs -Force | Out-Null
        function Start-UserProcess([string]$Name,[string]$Executable,[string]$Arguments,[string]$WorkingDirectory) {
            # PID files are untrusted until the existing process passes the ownership guard.
            $process = Get-ImmichUserProcess -InstallRoot $InstallRoot -DataRoot $DataRoot -Name $Name
            if ($process) {
                $startupProcesses[$Name] = $process
                return
            }
            $launchId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N')
            $stdout = Join-Path $logs "$Name-$launchId.stdout.log"
            $stderr = Join-Path $logs "$Name-$launchId.stderr.log"
            $startupLogs[$Name] = @{ Stdout = $stdout; Stderr = $stderr }
            $process = Start-Process -FilePath $Executable -ArgumentList $Arguments -WorkingDirectory $WorkingDirectory -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
            # Keep the returned Process, rather than re-querying a PID whose executable Path
            # can be temporarily unavailable while Windows is still loading the image.
            $startupProcesses[$Name] = $process
            $process.Id | Set-Content -LiteralPath (Join-Path $services "$Name.pid")
        }
        function Assert-UserProcessesRunning {
            foreach ($name in $startupProcesses.Keys) {
                $process = $startupProcesses[$name]
                $process.Refresh()
                if ($process.HasExited) {
                    $exitCode = 'unavailable'
                    try { $exitCode = [string]$process.ExitCode } catch {}
                    throw "CurrentUser process $name exited during startup (exit code: $exitCode)."
                }
            }
        }
        $sharpLib = Join-Path $current 'server\node_modules\@img\sharp-win32-x64\lib'
        if (-not (Test-Path -LiteralPath $sharpLib -PathType Container)) { throw "Sharp runtime is missing: $sharpLib" }
        if ($redisMode -eq 'BundledValkey') {
            $valkey = Join-Path $current 'dependencies\valkey\valkey-server.exe'
            $valkeyConfig = Join-Path $DataRoot 'valkey.conf'
            if ($valkeyConfig -notmatch '^([A-Za-z]):[\\/](.*)$') { throw "Valkey requires a drive path for its config: $valkeyConfig" }
            $valkeyConfigPath = '/cygdrive/' + $Matches[1].ToLowerInvariant() + '/' + $Matches[2].Replace('\','/')
            Start-UserProcess 'ImmichValkey' $valkey ('"{0}"' -f $valkeyConfigPath) (Split-Path $valkey)
        }
        $node = Join-Path $current 'runtime\node\node.exe'
        $serverEntry = Join-Path $current 'server\dist\main.js'
        Start-UserProcess 'ImmichServer' $node ('"{0}"' -f $serverEntry) $current
        $python = Get-ImmichPythonExecutable -ReleaseRoot $current
        $serverPort = $env:IMMICH_PORT
        $serverHost = $env:IMMICH_HOST
        $pythonPath = $env:PYTHONPATH
        try {
            $env:IMMICH_HOST = if ($env:IMMICH_HOST_ML) { $env:IMMICH_HOST_ML } else { '127.0.0.1' }
            $env:IMMICH_PORT = if ($env:IMMICH_PORT_ML) { $env:IMMICH_PORT_ML } else { '3003' }
            $env:PYTHONPATH = Join-Path $current 'machine-learning\app'
            Start-UserProcess 'ImmichMachineLearning' $python.FullName '-m immich_ml' (Join-Path $current 'machine-learning')
        } finally {
            $env:IMMICH_PORT = $serverPort
            $env:IMMICH_HOST = $serverHost
            $env:PYTHONPATH = $pythonPath
        }
    } elseif ($env:IMMICH_WINDOWS_INSTALL_SCOPE -eq 'AllUsers') {
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
    } else {
        throw "Unsupported IMMICH_WINDOWS_INSTALL_SCOPE: $($env:IMMICH_WINDOWS_INSTALL_SCOPE)"
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $serverPort = if ($env:IMMICH_PORT) { [int]$env:IMMICH_PORT } else { 2283 }
    $mlPort = if ($env:IMMICH_PORT_ML) { [int]$env:IMMICH_PORT_ML } else { 3003 }
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($env:IMMICH_WINDOWS_INSTALL_SCOPE -eq 'CurrentUser') {
            Assert-UserProcessesRunning
        }
        $healthy = $false
        try {
            $ml = Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:$mlPort/ping" -TimeoutSec 3
            $server = Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:$serverPort/api/server/ping" -TimeoutSec 3
            $healthy = $ml.StatusCode -eq 200 -and $server.StatusCode -eq 200
        } catch {}
        # A process may exit while an HTTP probe is pending. Do not swallow that failure
        # in the probe catch or report healthy based on a response from an exited process.
        if ($env:IMMICH_WINDOWS_INSTALL_SCOPE -eq 'CurrentUser') { Assert-UserProcessesRunning }
        if ($healthy) {
            Write-Host "Immich Server and ML are healthy (Redis mode: $redisMode)."
            exit 0
        }
        Start-Sleep 2
    }

    throw "Immich health checks did not become ready within $TimeoutSeconds seconds (Redis mode: $redisMode)."
} catch {
    foreach ($name in $startupLogs.Keys) {
        $paths = $startupLogs[$name]
        Write-Warning "CurrentUser startup logs for ${name}: stdout='$($paths.Stdout)'; stderr='$($paths.Stderr)'"
    }
    $logRoot = Join-Path $DataRoot 'logs'
    if (Test-Path -LiteralPath $logRoot) {
        Get-ChildItem -LiteralPath $logRoot -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 6 |
            ForEach-Object {
                Write-Warning "Recent Immich log: $($_.FullName)"
                Get-Content -LiteralPath $_.FullName -Tail 40 -ErrorAction SilentlyContinue
            }
    }
    throw
}
