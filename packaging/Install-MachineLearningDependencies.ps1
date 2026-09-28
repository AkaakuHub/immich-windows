[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReleaseRoot,
    [Parameter(Mandatory)][string]$InstallRoot
)

$ErrorActionPreference = 'Stop'
$mlRoot = Join-Path $ReleaseRoot 'machine-learning'
$python = Get-ChildItem (Join-Path $mlRoot 'python-runtime') -Filter python.exe -File -Recurse | Where-Object { $_.FullName -notmatch '\\Scripts\\' } | Select-Object -First 1
$uv = Join-Path $mlRoot 'uv.exe'
$requirements = Join-Path $mlRoot 'requirements.txt'
foreach ($path in @($(if ($python) { $python.FullName }),$uv,$requirements)) {
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Machine Learning runtime input is missing: $path" }
}
$cache = Join-Path $InstallRoot 'cache\uv'
New-Item -ItemType Directory -Path $cache -Force | Out-Null
& $uv pip sync $requirements --python $python.FullName --system --cache-dir $cache
if ($LASTEXITCODE -ne 0) { throw "Could not install Machine Learning dependencies (uv exit code $LASTEXITCODE)." }
Write-Host 'Machine Learning dependencies installed for this release.'
