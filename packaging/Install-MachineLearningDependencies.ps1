#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReleaseRoot,
    [Parameter(Mandatory)][string]$InstallRoot
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\runtime\Common.psm1') -Force
$mlRoot = Join-Path $ReleaseRoot 'machine-learning'
$python = Get-ImmichPythonExecutable -ReleaseRoot $ReleaseRoot
$requirements = Join-Path $mlRoot 'requirements.txt'
$manifest = Get-Content -Raw -LiteralPath (Join-Path $ReleaseRoot 'manifest.json') | ConvertFrom-Json
$uv = Join-Path $InstallRoot "tools\uv\$($manifest.dependencies.uv.version)\uv.exe"
$statePath = Join-Path $mlRoot '.dependencies-installed.json'
foreach ($path in @($(if ($python) { $python.FullName }),$uv,$requirements)) {
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Machine Learning runtime input is missing: $path" }
}
$expectedState = [ordered]@{
    immichVersion = $manifest.immichVersion
    python = $manifest.dependencies.python.version
    requirementsSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $requirements).Hash.ToLowerInvariant()
}
# The runtime installer may have seeded local packages from the active release.
$source = Get-ImmichDependencySource -InstallRoot $InstallRoot -ReleaseRoot $ReleaseRoot
$markers = @($statePath)
if ($source) { $markers += (Join-Path $source 'machine-learning\.dependencies-installed.json') }
foreach ($marker in $markers) {
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { continue }
    try { $installedState = Get-Content -Raw -LiteralPath $marker | ConvertFrom-Json } catch { continue }
    if (-not $installedState -or -not $installedState.PSObject.Properties['python'] -or
        -not $installedState.PSObject.Properties['requirementsSha256']) { continue }
    if ([string]$installedState.python -ne [string]$expectedState.python -or
        [string]$installedState.requirementsSha256 -cne [string]$expectedState.requirementsSha256) { continue }
    # Isolated mode ignores PYTHONHOME/PYTHONPATH. Check actual relocated imports, not only marker existence.
    $probe = 'import sys,pathlib,numpy,onnxruntime,uvicorn; root=pathlib.Path(sys.argv[1]).resolve(); assert pathlib.Path(sys.prefix).resolve().is_relative_to(root); assert pathlib.Path(sys.executable).resolve().is_relative_to(root); assert pathlib.Path(numpy.__file__).resolve().is_relative_to(root); assert pathlib.Path(onnxruntime.__file__).resolve().is_relative_to(root)'
    $probeProgress=Start-ImmichProgress -Key verify -Detail 'Python imports'
    & $python.FullName -I -c $probe (Join-Path $mlRoot 'python-runtime')
    if ($LASTEXITCODE -ne 0) { Update-ImmichProgress -State $probeProgress -Failed; continue }
    Update-ImmichProgress -State $probeProgress -Finished
    $expectedState | ConvertTo-Json | Set-Content -Encoding utf8 -LiteralPath $statePath
    Write-Host 'Reused installed Machine Learning packages (requirements unchanged; relocated imports verified).'
    return
}
$cache = Join-Path $InstallRoot 'cache\uv'
New-Item -ItemType Directory -Path $cache -Force | Out-Null
$syncProgress=Start-ImmichProgress -Key ml
& $uv pip sync $requirements --python $python.FullName --system --break-system-packages --cache-dir $cache
if ($LASTEXITCODE -ne 0) { Update-ImmichProgress -State $syncProgress -Failed; throw "Could not install Machine Learning dependencies (uv exit code $LASTEXITCODE)." }
Update-ImmichProgress -State $syncProgress -Finished
$expectedState | ConvertTo-Json | Set-Content -Encoding utf8 -LiteralPath $statePath
Write-Host 'Machine Learning dependencies installed for this release.'
