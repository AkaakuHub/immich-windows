#requires -Version 7.0
# Explicit standalone maintenance launcher. Never starts/stops Immich services.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReleaseRoot,
    [Parameter(Mandatory)][string]$EnvFile,
    [Parameter(ValueFromRemainingArguments)][string[]]$RepairArguments
)
$ErrorActionPreference = 'Stop'
$release = (Resolve-Path -LiteralPath $ReleaseRoot).Path
$loader = Join-Path $release 'runtime\launchers\Load-ImmichEnv.ps1'
$node = Join-Path $release 'runtime\node\node.exe'
$cli = Join-Path $PSScriptRoot 'cli.cjs'
foreach ($file in @($loader, $node, $cli, $EnvFile)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw 'A required installed runtime or configuration file is missing.' }
}
$previousEnvironment = [Environment]::GetEnvironmentVariables('Process')
try {
    # No -ServiceRole: load environment/PATH only. Never start the server.
    . $loader -EnvFile $EnvFile
    Push-Location -LiteralPath $release
    try {
        & $node $cli @RepairArguments --release-root $release
        $result = $LASTEXITCODE
    } finally { Pop-Location }
} finally {
    # Restore process environment even if invoked from an existing PowerShell.
    foreach ($name in [Environment]::GetEnvironmentVariables('Process').Keys) {
        if (-not $previousEnvironment.Contains($name)) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
    }
    foreach ($name in $previousEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
    }
}
exit $result
