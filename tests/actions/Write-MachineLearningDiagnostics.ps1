#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstallRoot,
    [Parameter(Mandatory)][string]$DataRoot,
    [string]$OutputPath
)

# CI failure evidence only. Never upload raw env files, process command lines or logs.
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'ML diagnostics are restricted to disposable CI installations.' }
Import-Module (Join-Path $PSScriptRoot '..\..\runtime\Common.psm1') -Force
$secretPattern = '(?i)password|passwd|secret|token|credential|api[_-]?key'
$secrets = [Collections.Generic.List[string]]::new()
foreach ($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()) {
    if ([string]$entry.Key -match $secretPattern -and [string]$entry.Value) { $secrets.Add([string]$entry.Value) }
}
$settings = @{}
try {
    $settings = Read-EnvFile (Join-Path $DataRoot 'immich.env')
    foreach ($entry in $settings.GetEnumerator()) {
        if ([string]$entry.Key -match $secretPattern -and [string]$entry.Value) { $secrets.Add([string]$entry.Value) }
    }
} catch {} # Logs can explain a failure that happened before the env file existed.

function Protect-DiagnosticText([string]$Text) {
    foreach ($secret in ($secrets | Select-Object -Unique | Sort-Object Length -Descending)) {
        $Text = $Text.Replace($secret, '[REDACTED]').Replace([uri]::EscapeDataString($secret), '[REDACTED]')
    }
    $Text = $Text -replace '(?i)\b([a-z][a-z0-9+.-]*://)[^/\s@]+@', '$1[REDACTED]@'
    $Text = $Text -replace '(?im)((?:password|passwd|secret|token|api[_-]?key|credential)\s*["'']?\s*[:=]\s*)[^\r\n]+', '$1[REDACTED]'
    $Text = $Text -replace '\x1B\[[0-?]*[ -/]*[@-~]', ''
    $Text = $Text -replace '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', ''
    # Prevent a captured child log from emitting GitHub Actions workflow commands.
    return $Text.Replace('::', ': :')
}

$lines = [Collections.Generic.List[string]]::new()
$lines.Add("ML diagnostic snapshot: $([DateTime]::UtcNow.ToString('o'))")
$lines.Add("Install root: $InstallRoot")
$lines.Add("Data root: $DataRoot")
$logRoot = Join-Path $DataRoot 'logs'
foreach ($stream in @('stdout','stderr')) {
    # CurrentUser uses per-launch names; WinSW uses ImmichMachineLearning.out/err.log.
    $serviceStream = if ($stream -eq 'stdout') { 'out' } else { 'err' }
    $file = Get-ChildItem -LiteralPath $logRoot -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "ImmichMachineLearning-*.$stream.log" -or $_.Name -eq "ImmichMachineLearning.$serviceStream.log" } |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if (-not $file) { $lines.Add("No ML $stream log found."); continue }
    $lines.Add("ML ${stream}: $($file.Name) (last 80 lines, maximum 16000 characters)")
    try {
        $text = Protect-DiagnosticText ((Get-Content -LiteralPath $file.FullName -Tail 80) -join "`n")
        if ($text.Length -gt 16000) { $text = $text.Substring($text.Length - 16000) }
        $lines.Add($text)
    } catch { $lines.Add("Could not read ML $stream log.") }
}
if ($IsWindows) {
    try {
        # Include both scopes' Python processes so a previous scope's orphan is visible.
        foreach ($process in Get-CimInstance Win32_Process -Filter "Name='python.exe'") {
            $lines.Add("Python process: pid=$($process.ProcessId); parent=$($process.ParentProcessId); executable=$($process.ExecutablePath)")
        }
        $port = if ($settings['IMMICH_PORT_ML']) { [int]$settings['IMMICH_PORT_ML'] } else { 3003 }
        $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)
        if (-not $listeners.Count) { $lines.Add("No listener on ML port $port.") }
        foreach ($listener in $listeners) {
            $lines.Add("ML listener: $($listener.LocalAddress):$($listener.LocalPort); owner=$($listener.OwningProcess)")
        }
    } catch { $lines.Add('Process/listener lookup was unavailable.') }
}
$report = Protect-DiagnosticText ($lines -join "`n")
foreach ($line in $report -split '\r?\n') { Write-Host "[ML diagnostic] $line" }
if ($OutputPath) { Add-Content -LiteralPath $OutputPath -Value $report -Encoding utf8 }
