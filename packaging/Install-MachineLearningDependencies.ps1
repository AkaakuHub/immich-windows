#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReleaseRoot,
    [Parameter(Mandatory)][string]$InstallRoot
)

$ErrorActionPreference = 'Stop'
$mlRoot = Join-Path $ReleaseRoot 'machine-learning'
$python = Get-ChildItem (Join-Path $mlRoot 'python-runtime') -Filter python.exe -File -Recurse | Where-Object { $_.FullName -notmatch '\\Scripts\\' } | Select-Object -First 1
$requirements = Join-Path $mlRoot 'requirements.txt'
$mlManifest = Join-Path $mlRoot 'ml-manifest.json'
$manifest = Get-Content -Raw -LiteralPath (Join-Path $ReleaseRoot 'manifest.json') | ConvertFrom-Json
$uv = Join-Path $InstallRoot "tools\uv\$($manifest.dependencies.uv.version)\uv.exe"
$statePath = Join-Path $mlRoot '.dependencies-installed.json'
foreach ($path in @($(if ($python) { $python.FullName }),$uv,$requirements,$mlManifest)) {
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Machine Learning runtime input is missing: $path" }
}
$expectedState = [ordered]@{
    immichVersion = $manifest.immichVersion
    python = $manifest.dependencies.python.version
    requirementsSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $requirements).Hash.ToLowerInvariant()
    mlManifestSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $mlManifest).Hash.ToLowerInvariant()
}
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    $installedState = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
    if (
        $python -and
        [string]$installedState.immichVersion -eq [string]$expectedState.immichVersion -and
        [string]$installedState.python -eq [string]$expectedState.python -and
        [string]$installedState.requirementsSha256 -eq [string]$expectedState.requirementsSha256 -and
        [string]$installedState.mlManifestSha256 -eq [string]$expectedState.mlManifestSha256
    ) {
        Write-Host 'Pinned Machine Learning dependencies are already installed for this release.'
        return
    }
}
$cache = Join-Path $InstallRoot 'cache\uv'
New-Item -ItemType Directory -Path $cache -Force | Out-Null
& $uv pip sync $requirements --python $python.FullName --system --break-system-packages --cache-dir $cache
if ($LASTEXITCODE -ne 0) { throw "Could not install Machine Learning dependencies (uv exit code $LASTEXITCODE)." }
$expectedState | ConvertTo-Json | Set-Content -Encoding utf8 -LiteralPath $statePath
Write-Host 'Machine Learning dependencies installed for this release.'
