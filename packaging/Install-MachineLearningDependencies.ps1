#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReleaseRoot,
    [Parameter(Mandatory)][string]$InstallRoot,
    [Collections.Generic.List[object]]$DependencyReusePlan
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\runtime\Common.psm1') -Force
$mlRoot = Join-Path $ReleaseRoot 'machine-learning'
$requirements = Join-Path $mlRoot 'requirements.txt'
$wheelhouse = Join-Path $mlRoot 'wheelhouse'
$manifest = Get-Content -Raw -LiteralPath (Join-Path $ReleaseRoot 'manifest.json') | ConvertFrom-Json
$uv = Join-Path $InstallRoot "tools\uv\$($manifest.dependencies.uv.version)\uv.exe"
$statePath = Join-Path $mlRoot '.dependencies-installed.json'
$deferred=@($DependencyReusePlan | Where-Object { $_.relativePath -like 'machine-learning/python-runtime/*' })
if ($deferred.Count) {
    # Runtime planning already matched the installed marker, Python pin and
    # candidate requirements. The updater validates imports after the directory rename.
    if ($deferred.Count -ne 1) { throw 'Ambiguous deferred Python runtime.' }
    $state=[ordered]@{immichVersion=$manifest.immichVersion;python=$manifest.dependencies.python.version;requirementsSha256=[string]$deferred[0].requirementsSha256}
    $state | ConvertTo-Json | Set-Content -Encoding utf8 -LiteralPath $statePath
    Write-Host 'Keeping unchanged Machine Learning packages; imports will be checked after shutdown.'
    return
}
$python = Get-ImmichPythonExecutable -ReleaseRoot $ReleaseRoot
foreach ($path in @($(if ($python) { $python.FullName }),$uv,$requirements)) {
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Machine Learning runtime input is missing: $path" }
}
if (-not (Test-Path -LiteralPath (Join-Path $wheelhouse '.complete') -PathType Leaf)) { throw "Machine Learning wheelhouse is missing: $wheelhouse" }
$expectedState = [ordered]@{
    immichVersion = $manifest.immichVersion
    python = $manifest.dependencies.python.version
    requirementsSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $requirements).Hash.ToLowerInvariant()
}
# Only this environment's completion marker can skip uv. An old release's marker
# does not describe a new independent environment created during preparation.
$markers=@($statePath)
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
& $uv pip sync $requirements --python $python.FullName --system --break-system-packages --cache-dir $cache --find-links $wheelhouse
if ($LASTEXITCODE -ne 0) { Update-ImmichProgress -State $syncProgress -Failed; throw "Could not install Machine Learning dependencies (uv exit code $LASTEXITCODE)." }
Update-ImmichProgress -State $syncProgress -Finished
$expectedState | ConvertTo-Json | Set-Content -Encoding utf8 -LiteralPath $statePath
Write-Host 'Machine Learning dependencies installed for this release.'
