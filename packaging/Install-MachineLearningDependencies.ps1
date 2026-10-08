#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReleaseRoot,
    [Parameter(Mandatory)][string]$InstallRoot,
    [Collections.Generic.List[object]]$DependencyReusePlan
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\runtime\Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\runtime\DependencyPayload.psm1') -Force
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
    $state=[ordered]@{immichVersion=$manifest.immichVersion;python=$manifest.dependencies.python.version;requirementsSha256=[string]$deferred[0].requirementsSha256;payloadsSha256=[string]$deferred[0].payloadsSha256}
    $state | ConvertTo-Json | Set-Content -Encoding utf8 -LiteralPath $statePath
    Write-Host 'Keeping unchanged Machine Learning packages; imports will be checked after shutdown.'
    return
}
$python = Get-ImmichPythonExecutable -ReleaseRoot $ReleaseRoot
foreach ($path in @($(if ($python) { $python.FullName }),$uv,$requirements)) {
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Machine Learning runtime input is missing: $path" }
}
$expectedState = [ordered]@{
    immichVersion = $manifest.immichVersion
    python = $manifest.dependencies.python.version
    payloadsSha256 = Get-ImmichMachineLearningDependencyHash $manifest
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
        [string]$installedState.requirementsSha256 -cne [string]$expectedState.requirementsSha256 -or
        -not $installedState.PSObject.Properties['payloadsSha256'] -or [string]$installedState.payloadsSha256 -cne [string]$expectedState.payloadsSha256) { continue }
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
New-Item -ItemType Directory -Path $wheelhouse -Force | Out-Null
$packageVersion = 'v' + (Get-WindowsPackageVersion $manifest).ToString(4)
$wheelPayloads = @($manifest.dependencyPayloads.PSObject.Properties | Where-Object { $_.Name.StartsWith('machine-learning/wheelhouse/') })
if (-not $wheelPayloads.Count) { throw 'Machine Learning dependency payload inventory is empty.' }
$previousRelease = Get-ImmichDependencySource -InstallRoot $InstallRoot -ReleaseRoot $ReleaseRoot
foreach ($entry in $wheelPayloads) {
    $name = [IO.Path]::GetFileName($entry.Name)
    if (-not $name.EndsWith('.whl') -or $entry.Name -cne "machine-learning/wheelhouse/$name") { throw 'Invalid Machine Learning wheel path.' }
    $source = Get-ImmichDependencyPayload -Payload $entry.Value -Version $packageVersion -CacheRoot (Join-Path $InstallRoot 'cache/downloads') -InstalledPath $(if ($previousRelease) { Join-Path $previousRelease $entry.Name })
    Copy-Item -LiteralPath $source -Destination (Join-Path $wheelhouse $name) -Force
}
$cache = Join-Path $InstallRoot 'cache\uv'
New-Item -ItemType Directory -Path $cache -Force | Out-Null
$syncProgress=Start-ImmichProgress -Key ml
& $uv pip sync (Join-Path $mlRoot 'wheel-requirements.txt') --python $python.FullName --system --break-system-packages --cache-dir $cache --find-links $wheelhouse --no-index --no-build
if ($LASTEXITCODE -ne 0) { Update-ImmichProgress -State $syncProgress -Failed; throw "Could not install Machine Learning dependencies (uv exit code $LASTEXITCODE)." }
Update-ImmichProgress -State $syncProgress -Finished
$expectedState | ConvertTo-Json | Set-Content -Encoding utf8 -LiteralPath $statePath
Write-Host 'Machine Learning dependencies installed for this release.'
