#requires -Version 7.0
# Isolated startup tests: native processes, HTTP probes and polling waits are stubs.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$base = Join-Path ([IO.Path]::GetTempPath()) ('immich-startup-tests-' + [guid]::NewGuid().ToString('N'))
$driveName = $null
$previousState = Get-Variable -Name ImmichStartupTest -Scope Global -ErrorAction SilentlyContinue
$environmentNames = @('IMMICH_WINDOWS_INSTALL_SCOPE','IMMICH_WINDOWS_REDIS_MODE','IMMICH_PORT','IMMICH_HOST','IMMICH_PORT_ML','IMMICH_HOST_ML','PYTHONPATH','DB_PASSWORD')
$previousEnvironment = @{}
foreach ($name in $environmentNames) { $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }

function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function New-TestProcess([string]$Name, [int]$ProcessId, [string]$PathValue = '') {
    $process = [pscustomobject]@{
        Name = $Name; Id = $ProcessId; PathValue = $PathValue; PathReads = 0
        Refreshes = 0; HasExited = $false; ExitCode = 27
    }
    $process | Add-Member -MemberType ScriptProperty -Name Path -Value { $this.PathReads++; return $this.PathValue }
    $process | Add-Member -MemberType ScriptMethod -Name Refresh -Value { $this.Refreshes++ }
    return $process
}

$loaderStub = @'
param($EnvFile)
function Get-Process {
    [CmdletBinding()]
    param([int]$Id)
    $global:ImmichStartupTest.ProcessQueries.Add($Id)
    return $global:ImmichStartupTest.Processes[$Id]
}
function Get-CurrentReleaseTarget {
    param($InstallRoot)
    return Join-Path $InstallRoot 'releases/test'
}
function Get-ImmichUserProcess {
    param($InstallRoot,$DataRoot,$Name)
    $state = $global:ImmichStartupTest
    $state.OwnershipQueries.Add($Name)
    $process = Get-TestOwnedProcess -InstallRoot $InstallRoot -DataRoot $DataRoot -Name $Name
    if ($process -and $state.Mode -eq 'reuse') {
        # Ownership was verified; losing Path afterwards must not look like an exit.
        $process.PathValue = ''
    }
    return $process
}
function Start-Process {
    [CmdletBinding()]
    param($FilePath,$ArgumentList,$WorkingDirectory,[switch]$PassThru,$WindowStyle,$RedirectStandardOutput,$RedirectStandardError)
    $state = $global:ImmichStartupTest
    $name = if ($FilePath -like '*valkey-server.exe') { 'ImmichValkey' } elseif ($FilePath -like '*node.exe') { 'ImmichServer' } else { 'ImmichMachineLearning' }
    Check ($PassThru -and $WindowStyle -eq 'Hidden') 'Startup lost its retained, hidden process.'
    Check ([bool]$RedirectStandardOutput -and [bool]$RedirectStandardError) 'Startup did not redirect both output streams.'
    $state.NextId++
    $process = New-TestProcess $name $state.NextId
    $state.Processes[$process.Id] = $process
    $state.Started.Add([pscustomobject]@{ Name = $name; Process = $process; Stdout = $RedirectStandardOutput; Stderr = $RedirectStandardError })
    if ($state.Mode -eq 'launch-failure' -and $name -eq $state.Target) { throw 'Injected Start-Process failure.' }
    Set-Content -LiteralPath $RedirectStandardOutput -Value 'stdout fixture'
    Set-Content -LiteralPath $RedirectStandardError -Value 'stderr fixture'
    if ($state.Mode -eq 'immediate-exit' -and $name -eq $state.Target) { $process.HasExited = $true }
    return $process
}
function Invoke-WebRequest {
    [CmdletBinding()]
    param([Parameter(Position=0)][string]$Uri,[switch]$UseBasicParsing,[int]$TimeoutSec)
    $state = $global:ImmichStartupTest
    Check ($TimeoutSec -eq 3) 'HTTP probe timeout changed.'
    Check ($Uri -in @('http://127.0.0.1:2283/api/server/ping','http://127.0.0.1:3003/ping')) 'Unexpected HTTP health endpoint.'
    $state.Probes++
    if ($state.Mode -in @('exit-during-probe','exit-during-failed-probe')) {
        ($state.Started | Where-Object Name -eq $state.Target).Process.HasExited = $true
        if ($state.Mode -eq 'exit-during-failed-probe') { throw 'Injected transient HTTP failure.' }
    }
    $status = if ($state.Mode -in @('timeout','exit-during-wait') -or ($state.Mode -in @('delayed','reuse') -and $state.Probes -le 4)) { 503 } else { 200 }
    return [pscustomobject]@{ StatusCode = $status }
}
function Start-Sleep {
    param([int]$Seconds)
    $state = $global:ImmichStartupTest
    Check ($Seconds -eq 2) 'Startup introduced a different polling delay.'
    $state.Sleeps++
    Check ($state.Sleeps -le 10) 'Startup failed to finish the isolated polling fixture.'
    if ($state.Mode -eq 'exit-during-wait') { ($state.Started | Where-Object Name -eq $state.Target).Process.HasExited = $true }
    if ($state.Mode -eq 'timeout') { Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds 1100 }
}
function Stop-Process {
    param($Id,[switch]$Force)
    $global:ImmichStartupTest.Killed.Add([int]$Id)
    throw 'Startup or cleanup tried to kill an unrelated process.'
}
function taskkill.exe {
    $global:ImmichStartupTest.Killed.Add(-1)
    throw 'Startup or cleanup tried to kill an unrelated process tree.'
}
'@

try {
    New-Item -ItemType Directory -Path $base | Out-Null
    # A temporary drive lets the bundled Valkey path validation run on Linux as well.
    $usedDrives = @((Get-PSDrive).Name)
    $driveName = @([char[]](90..68) | ForEach-Object { [string]$_ } | Where-Object { $_ -notin $usedDrives })[0]
    New-PSDrive -Name $driveName -PSProvider FileSystem -Root $base | Out-Null
    $fixtureRoot = "${driveName}:/"
    $launchers = Join-Path $fixtureRoot 'launchers'
    New-Item -ItemType Directory -Path $launchers | Out-Null
    foreach ($launcher in @('Start-Immich.ps1','Stop-Immich.ps1')) { Copy-Item (Join-Path $repo "runtime/launchers/$launcher") (Join-Path $launchers $launcher) }
    # Exercise the production ownership guard unchanged, with only OS lookup/target stubs.
    $tokens = $null; $parseErrors = $null
    $common = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'runtime/Common.psm1'), [ref]$tokens, [ref]$parseErrors)
    Check ($parseErrors.Count -eq 0) 'Common.psm1 does not parse.'
    $guard = $common.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ImmichUserProcess' }, $true)
    Check ($null -ne $guard) 'Production ownership guard was not found.'
    $guardText = $guard.Extent.Text.Replace('function Get-ImmichUserProcess', 'function Get-TestOwnedProcess')
    Set-Content -LiteralPath (Join-Path $launchers 'Load-ImmichEnv.ps1') -Value ($loaderStub + "`n" + $guardText)

    $cases = @(
        @{ Name = 'live-path-unavailable-delayed-health'; Mode = 'delayed'; Redis = 'External'; Target = '' },
        @{ Name = 'bundled-valkey-live-path-unavailable'; Mode = 'delayed'; Redis = 'BundledValkey'; Target = '' },
        @{ Name = 'machine-learning-exits-immediately'; Mode = 'immediate-exit'; Redis = 'External'; Target = 'ImmichMachineLearning' },
        @{ Name = 'server-exits-immediately'; Mode = 'immediate-exit'; Redis = 'External'; Target = 'ImmichServer' },
        @{ Name = 'valkey-exits-immediately'; Mode = 'immediate-exit'; Redis = 'BundledValkey'; Target = 'ImmichValkey' },
        @{ Name = 'exit-during-successful-probe'; Mode = 'exit-during-probe'; Redis = 'External'; Target = 'ImmichMachineLearning' },
        @{ Name = 'exit-during-failed-probe'; Mode = 'exit-during-failed-probe'; Redis = 'External'; Target = 'ImmichMachineLearning' },
        @{ Name = 'exit-between-polls'; Mode = 'exit-during-wait'; Redis = 'External'; Target = 'ImmichServer' },
        @{ Name = 'live-unhealthy-timeout'; Mode = 'timeout'; Redis = 'External'; Target = '' },
        @{ Name = 'verified-existing-processes-reused'; Mode = 'reuse'; Redis = 'External'; Target = '' },
        @{ Name = 'unrelated-pids-never-adopted-or-killed'; Mode = 'unrelated'; Redis = 'External'; Target = '' },
        @{ Name = 'launch-failure-reports-log-paths'; Mode = 'launch-failure'; Redis = 'External'; Target = 'ImmichMachineLearning' },
        @{ Name = 'repeat-launch-keeps-distinct-logs'; Mode = 'immediate-exit'; Redis = 'External'; Target = 'ImmichMachineLearning'; Repeat = $true }
    )
    foreach ($case in $cases) {
        $root = Join-Path $fixtureRoot ($case.Name + '/install')
        $data = Join-Path $fixtureRoot ($case.Name + '/data')
        foreach ($directory in @('current/server/node_modules/@img/sharp-win32-x64/lib','current/machine-learning/python-runtime')) { New-Item -ItemType Directory -Path (Join-Path $root $directory) -Force | Out-Null }
        New-Item -ItemType Directory -Path (Join-Path $data 'services') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'current/machine-learning/python-runtime/python.exe') -Value 'fixture'
        $state = @{
            Mode = $case.Mode; Target = $case.Target; NextId = 4000; Processes = @{}; Probes = 0; Sleeps = 0
            Started = [Collections.Generic.List[object]]::new(); OwnershipQueries = [Collections.Generic.List[string]]::new()
            ProcessQueries = [Collections.Generic.List[int]]::new(); Killed = [Collections.Generic.List[int]]::new()
        }
        $global:ImmichStartupTest = $state
        $env:IMMICH_WINDOWS_INSTALL_SCOPE = 'CurrentUser'
        $env:IMMICH_WINDOWS_REDIS_MODE = $case.Redis
        $env:IMMICH_PORT = '2283'; $env:IMMICH_HOST = '127.0.0.1'
        $env:IMMICH_PORT_ML = '3003'; $env:IMMICH_HOST_ML = '127.0.0.1'
        $env:PYTHONPATH = 'original-python-path'
        $env:DB_PASSWORD = 'secret-that-must-not-appear-in-diagnostics'
        $names = @('ImmichServer','ImmichMachineLearning')
        if ($case.Redis -eq 'BundledValkey') { $names += 'ImmichValkey' }
        $existing = @()
        if ($case.Mode -in @('reuse','unrelated')) {
            foreach ($name in $names) {
                $path = if ($case.Mode -eq 'reuse') { (Join-Path $root 'current') + '\runtime\owned.exe' } else { 'C:\Unrelated\other.exe' }
                $process = New-TestProcess $name (1000 + $existing.Count) $path
                $existing += $process
                $state.Processes[$process.Id] = $process
                $process.Id | Set-Content -LiteralPath (Join-Path $data "services/$name.pid")
            }
        }
        $attempts = if ($case.ContainsKey('Repeat')) { 2 } else { 1 }
        $allLogPaths = @()
        for ($attempt = 0; $attempt -lt $attempts; $attempt++) {
            $state.Probes = 0; $state.Sleeps = 0
            $errorText = $null
            $warnings = @()
            $timeout = if ($case.Mode -eq 'timeout') { 1 } else { 30 }
            try { & (Join-Path $launchers 'Start-Immich.ps1') -InstallRoot $root -DataRoot $data -EnvFile (Join-Path $data 'immich.env') -TimeoutSeconds $timeout -WarningVariable warnings 3>$null 6>$null }
            catch { $errorText = $_.Exception.Message }
            $diagnostics = (@($warnings | ForEach-Object { [string]$_ }) + @($errorText)) -join "`n"
            Check (-not $diagnostics.Contains($env:DB_PASSWORD)) "$($case.Name): diagnostics leaked environment data."
            Check ($env:IMMICH_PORT -eq '2283' -and $env:IMMICH_HOST -eq '127.0.0.1' -and $env:PYTHONPATH -eq 'original-python-path') "$($case.Name): ML environment was not restored."
            $fails = $case.Mode -in @('immediate-exit','exit-during-probe','exit-during-failed-probe','exit-during-wait','timeout','launch-failure')
            Check (($null -ne $errorText) -eq $fails) "$($case.Name): unexpected startup outcome: $errorText"
            if ($case.Mode -in @('immediate-exit','exit-during-probe','exit-during-failed-probe','exit-during-wait')) {
                Check ($errorText -like "*process $($case.Target) exited during startup*exit code: 27*") "$($case.Name): genuine exit lacked process name/exit code: $errorText"
                if ($case.Mode -eq 'immediate-exit') { Check ($state.Probes -eq 0 -and $state.Sleeps -eq 0) 'Immediate exit was not reported promptly.' }
                elseif ($case.Mode -eq 'exit-during-wait') { Check ($state.Sleeps -eq 1 -and $state.Probes -eq 2) 'Exit between polls was not reported before another HTTP probe.' }
                else { Check ($state.Sleeps -eq 0) 'Exit during HTTP probe was hidden until the next poll.' }
            } elseif ($case.Mode -eq 'timeout') {
                Check ($errorText -like '*health checks did not become ready within 1 seconds*') "Live processes were mislabeled as exited: $errorText"
                Check ($state.Sleeps -eq 1 -and $state.Probes -eq 2) 'Unhealthy process timeout did not exercise polling.'
            } elseif ($case.Mode -eq 'launch-failure') {
                Check ($errorText -eq 'Injected Start-Process failure.') 'Original launch failure was lost.'
            } elseif ($case.Mode -in @('delayed','reuse')) {
                Check ($state.Probes -eq 6 -and $state.Sleeps -eq 2) 'Delayed health readiness was not awaited.'
            }
            $latest = @($state.Started | Select-Object -Skip ($attempt * $names.Count))
            Check ($latest.Count -eq $(if ($case.Mode -eq 'reuse') { 0 } else { $names.Count })) "$($case.Name): unexpected launches or retries."
            foreach ($launch in $latest) {
                Check ($launch.Process.PathReads -eq 0) "$($case.Name): startup re-queried a newly launched process Path."
                foreach ($path in @($launch.Stdout,$launch.Stderr)) {
                    Check ((Split-Path $path) -eq (Join-Path $data 'logs')) 'Output log escaped DataRoot/logs.'
                    Check ($path -notin $allLogPaths) 'A launch reused an output log path.'
                    $allLogPaths += $path
                    if ($fails) { Check ($diagnostics.Contains($path)) "$($case.Name): failure did not report log path $path" }
                }
                if ($case.Mode -ne 'launch-failure') { Check (Test-Path -LiteralPath $launch.Stdout) 'stdout was not redirected.'; Check (Test-Path -LiteralPath $launch.Stderr) 'stderr was not redirected.' }
            }
            Check ($state.OwnershipQueries.Count -eq (($attempt + 1) * $names.Count)) "$($case.Name): ownership was incorrectly re-queried during health polling."
            foreach ($launch in $latest) { $launch.Process.HasExited = $true }
        }
        if ($case.Mode -eq 'reuse') {
            foreach ($process in $existing) { Check ($process.Refreshes -gt 0 -and $process.PathReads -gt 0) 'Existing process was not ownership-verified and checked for liveness.' }
            Check (-not (Get-ChildItem -LiteralPath (Join-Path $data 'logs'))) 'Reusing processes created new launch logs.'
        } elseif ($case.Mode -eq 'unrelated') {
            foreach ($process in $existing) {
                Check ($process.Refreshes -eq 0 -and -not $process.HasExited) 'An unrelated process was adopted or changed.'
                $pidPath = Join-Path $data "services/$($process.Name).pid"
                Check ([int](Get-Content -Raw -LiteralPath $pidPath) -ne $process.Id) 'An unrelated PID was retained.'
                # Exercise cleanup against stale PID files using the same production guard.
                $process.Id | Set-Content -LiteralPath $pidPath
            }
            & (Join-Path $launchers 'Stop-Immich.ps1') -InstallRoot $root -DataRoot $data -EnvFile (Join-Path $data 'immich.env')
            foreach ($process in $existing) { Check (-not $process.HasExited) 'Cleanup killed an unrelated process.' }
        }
        if ($attempts -eq 2) {
            Check ($allLogPaths.Count -eq 8) 'Repeated launch lost output logs.'
            foreach ($path in $allLogPaths) { Check (Test-Path -LiteralPath $path) 'Repeated launch removed a previous log.' }
        }
        Check ($state.Killed.Count -eq 0) "$($case.Name): startup killed a process."
        Write-Host "PASS startup workflow: $($case.Name)"
    }
} finally {
    foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process') }
    if ($previousState) { Set-Variable -Name ImmichStartupTest -Scope Global -Value $previousState.Value }
    else { Remove-Variable -Name ImmichStartupTest -Scope Global -ErrorAction SilentlyContinue }
    if ($driveName) { Remove-PSDrive -Name $driveName -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
}
