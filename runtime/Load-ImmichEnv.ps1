param([string]$EnvFile = 'C:\ProgramData\Immich\immich.env')
if (-not (Test-Path -LiteralPath $EnvFile)) { throw "Immich env file not found: $EnvFile" }
foreach ($line in Get-Content -LiteralPath $EnvFile) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    if ($line.TrimStart().StartsWith('#')) { continue }
    $i = $line.IndexOf('=')
    if ($i -lt 1) { throw "Invalid env line: $line" }
    [Environment]::SetEnvironmentVariable($line.Substring(0,$i).Trim(), $line.Substring($i+1), 'Process')
}

# Keep the portable native runtime self-contained. This is deliberately process-
# local; the installer does not modify the machine PATH.
$release = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$vcRuntime = Join-Path $release 'runtime\vc-runtime'
if (Test-Path -LiteralPath $vcRuntime -PathType Container) {
    $env:PATH = "$vcRuntime;$env:PATH"
}
