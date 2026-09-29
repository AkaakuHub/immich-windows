#requires -Version 7.0
param([string]$EnvFile = 'C:\ProgramData\Immich\immich.env')
Import-Module (Join-Path $PSScriptRoot '..\Common.psm1') -Force
foreach ($entry in (Read-EnvFile $EnvFile).GetEnumerator()) {
    [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
}

# Keep the portable native runtime self-contained. This is deliberately process-
# local; the installer does not modify the machine PATH.
$release = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$vcRuntime = Join-Path $release 'runtime\vc-runtime'
if (Test-Path -LiteralPath $vcRuntime -PathType Container) {
    $env:PATH = "$vcRuntime;$env:PATH"
}
