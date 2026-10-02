#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstallRoot,
    [Parameter(Mandatory)][string]$DataRoot,
    [ValidateRange(10,180)][int]$TimeoutSeconds = 60,
    [switch]$LeaveStopped
)

# Exercise the real installed launch/stop paths, with no model downloads or 300s wait.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or $env:GITHUB_ACTIONS -ne 'true') {
    throw 'This lifecycle fixture is restricted to disposable Windows CI installations.'
}
Import-Module (Join-Path $PSScriptRoot '..\..\runtime\Common.psm1') -Force
$current = Join-Path $InstallRoot 'current'
$release = Get-CurrentReleaseTarget $InstallRoot
$envFile = Join-Path $DataRoot 'immich.env'
$originalEnv = [IO.File]::ReadAllBytes($envFile)
$settings = Read-EnvFile $envFile
$scope = [string]$settings['IMMICH_WINDOWS_INSTALL_SCOPE']
if ($scope -notin @('CurrentUser','AllUsers')) { throw "Invalid install scope: $scope" }
$port = if ($settings['IMMICH_PORT_ML']) { [int]$settings['IMMICH_PORT_ML'] } else { 3003 }
$url = "http://127.0.0.1:$port"
$launchArgs = @{ InstallRoot=$InstallRoot; DataRoot=$DataRoot; EnvFile=$envFile }
$start = Join-Path $current 'runtime\launchers\Start-Immich.ps1'
$stop = Join-Path $current 'runtime\launchers\Stop-Immich.ps1'
$pythonPaths = @(foreach ($root in @($current,$release)) {
    Get-ChildItem (Join-Path $root 'machine-learning\python-runtime') -Filter python.exe -File -Recurse |
        Where-Object { $_.FullName -notmatch '\\Scripts\\' } | Select-Object -ExpandProperty FullName
})
$testEnv = @{ MACHINE_LEARNING_MODEL_TTL='1'; MACHINE_LEARNING_MODEL_TTL_POLL_S='1'; MACHINE_LEARNING_WORKERS='1' }
$previousProcessEnv = @{}
foreach ($key in $testEnv.Keys) { $previousProcessEnv[$key] = [Environment]::GetEnvironmentVariable($key, 'Process') }

function Get-MlSupervisor {
    $matches = @(Get-CimInstance Win32_Process -Filter "Name='python.exe'" | Where-Object {
        $_.ExecutablePath -in $pythonPaths -and $_.CommandLine -match '\s-m\s+immich_ml(?:\s|$)'
    })
    if ($matches.Count -ne 1) { throw "Expected one installed ML supervisor, found $($matches.Count)." }
    Get-Process -Id $matches[0].ProcessId
}

function Get-MlWorker([int]$SupervisorId) {
    $matches = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$SupervisorId" | Where-Object {
        $_.ExecutablePath -in $pythonPaths
    })
    if ($matches.Count -eq 0) { return $null } # Normal between worker exit and respawn.
    if ($matches.Count -ne 1) { throw "Expected one ML worker, found $($matches.Count)." }
    Get-Process -Id $matches[0].ProcessId -ErrorAction SilentlyContinue
}

function Assert-SupervisorStable {
    $supervisor.Refresh()
    if ($supervisor.HasExited) { throw 'ML supervisor exited instead of recycling only the idle worker.' }
    if ($scope -eq 'CurrentUser') {
        $owned = Get-ImmichUserProcess -InstallRoot $InstallRoot -DataRoot $DataRoot -Name ImmichMachineLearning
        if (-not $owned -or $owned.Id -ne $supervisor.Id) { throw 'CurrentUser ML PID ownership changed during idle recycling.' }
    } else {
        $service = Get-CimInstance Win32_Service -Filter "Name='ImmichMachineLearning'"
        if ($service.State -ne 'Running' -or $service.ProcessId -ne $serviceProcessId) {
            throw 'Idle worker recycling restarted or stopped the Windows service.'
        }
    }
}

$stopped = $false
try {
    & $stop @launchArgs
    foreach ($key in $testEnv.Keys) { $settings[$key] = $testEnv[$key] }
    Write-EnvFile -Path $envFile -Values $settings
    & $start @launchArgs
    $supervisor = Get-MlSupervisor
    $serviceProcessId = if ($scope -eq 'AllUsers') {
        (Get-CimInstance Win32_Service -Filter "Name='ImmichMachineLearning'").ProcessId
    } else { 0 }
    Assert-SupervisorStable
    $worker = Get-MlWorker $supervisor.Id
    if (-not $worker) { throw 'Healthy ML supervisor has no worker.' }

    # Health probes alone must not mark this fresh worker used or keep models warm.
    $deadline = [DateTime]::UtcNow.AddSeconds(4)
    while ([DateTime]::UtcNow -lt $deadline) {
        Invoke-WebRequest "$url/ping" -TimeoutSec 3 | Out-Null
        Assert-SupervisorStable
        $worker.Refresh()
        if ($worker.HasExited) { throw 'A /ping-only worker recycled before any prediction.' }
        Start-Sleep -Milliseconds 250
    }

    # Three cycles also exceed WinSW's two-restart budget, without consuming it.
    foreach ($cycle in 1..3) {
        $oldWorker = $worker
        $response = Invoke-WebRequest "$url/predict" -Method Post -ContentType 'application/x-www-form-urlencoded' `
            -Body @{ entries='{}'; text='lifecycle smoke test' } -TimeoutSec 10
        if ($response.StatusCode -ne 200 -or $response.Content.Trim() -ne '{}') {
            throw 'Empty prediction failed; the real /predict state dependency was not exercised.'
        }
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        $recycled = $false
        while ([DateTime]::UtcNow -lt $deadline) {
            Assert-SupervisorStable
            $oldWorker.Refresh()
            $candidate = Get-MlWorker $supervisor.Id
            if ($oldWorker.HasExited -and $candidate -and $candidate.Id -ne $oldWorker.Id) {
                try {
                    $ping = Invoke-WebRequest "$url/ping" -TimeoutSec 2
                    if ($ping.StatusCode -eq 200) { $worker = $candidate; $recycled = $true; break }
                } catch {} # The replacement may still be importing the ML app.
            }
            Start-Sleep -Milliseconds 200
        }
        if (-not $recycled) { throw "ML worker did not recycle and recover within ${TimeoutSeconds}s (cycle $cycle)." }
        Write-Host "${scope}: idle cycle $cycle released worker $($oldWorker.Id), replacement $($worker.Id) is healthy; supervisor $($supervisor.Id) is unchanged."
    }

    & $stop @launchArgs
    $stopped = $true
    foreach ($process in @($worker,$supervisor)) {
        if (-not $process.WaitForExit(10000)) { throw "ML process $($process.Id) survived the installed stop path." }
    }
    $remaining = @(Get-CimInstance Win32_Process -Filter "Name='python.exe'" | Where-Object {
        $_.ExecutablePath -in $pythonPaths
    })
    if ($remaining.Count) { throw 'Stop left an orphaned or respawned packaged ML Python process.' }
    if ($scope -eq 'CurrentUser') {
        if (Test-Path (Join-Path $DataRoot 'services\ImmichMachineLearning.pid')) { throw 'Stop left a stale ML PID file.' }
    } elseif ((Get-Service ImmichMachineLearning).Status -ne 'Stopped') { throw 'Stop left the ML service running.' }
    if (@(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue).Count) {
        throw "ML port $port is still held after the installed stop path."
    }
    Write-Host "${scope}: ML supervisor and replacement worker both stopped successfully."
} finally {
    try {
        if (-not $stopped) { & $stop @launchArgs }
    } finally {
        [IO.File]::WriteAllBytes($envFile, $originalEnv)
        foreach ($key in $previousProcessEnv.Keys) {
            [Environment]::SetEnvironmentVariable($key, $previousProcessEnv[$key], 'Process')
        }
        if (-not $LeaveStopped) { & $start @launchArgs }
    }
}
