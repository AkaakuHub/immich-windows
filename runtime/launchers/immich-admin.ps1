#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$EnvFile = 'C:\ProgramData\Immich\immich.env',
    [Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments
)
. (Join-Path $PSScriptRoot 'Load-ImmichEnv.ps1') -EnvFile $EnvFile
$release = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$node = Join-Path $release 'runtime\node\node.exe'
$main = Join-Path $release 'server\dist\main.js'
& $node --no-warnings $main immich-admin @Arguments
exit $LASTEXITCODE
