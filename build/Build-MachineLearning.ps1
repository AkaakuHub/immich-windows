[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Source,
    [string]$Destination
)
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
Assert-WindowsX64
$root = Get-RepositoryRoot
$versions = Read-JsonFile (Join-Path $root 'dependencies\versions.json')
if (-not $Destination) { $Destination = Join-Path $root 'artifacts\machine-learning' }
$Destination = New-CleanDirectory $Destination
Assert-Command uv | Out-Null
# The upstream lock is the authority for the ML dependency set. Keep the
# selected runtime interpreter consistent during uv sync on Windows.
Assert-Command cl.exe | Out-Null

Remove-Item Env:VIRTUAL_ENV -ErrorAction SilentlyContinue
$pythonInstallRoot = Join-Path $root '.tools\python'
$env:UV_PYTHON_INSTALL_DIR = $pythonInstallRoot
Invoke-Native uv @('python','install',$versions.python.version,'--install-dir',$pythonInstallRoot,'--no-registry','--no-bin')
$pythonExe = (& uv python find $versions.python.version --managed-python).Trim()
if (-not (Test-Path -LiteralPath $pythonExe)) { throw "uv did not return a valid Python executable: $pythonExe" }

# Resolve exactly from upstream uv.lock in a temporary venv, then copy the resulting
# Windows site-packages into the relocatable uv-managed CPython runtime.
$mlDir = Join-Path $Source 'machine-learning'
$venv = Join-Path $root '.work\ml-venv'
if (-not (Test-Path -LiteralPath (Join-Path $venv 'Scripts\python.exe') -PathType Leaf)) {
    Invoke-Native uv @('venv',$venv,'--python',$pythonExe)
}
$env:VIRTUAL_ENV = $venv
Invoke-Native uv @('sync','--frozen','--extra','cpu','--no-dev','--no-editable','--no-install-project','--compile-bytecode','--no-progress','--active','--python',$pythonExe,'--link-mode','copy') $mlDir
$venvPython = Join-Path $venv 'Scripts\python.exe'
$mlProbe = @'
import onnxruntime as ort
assert "CPUExecutionProvider" in ort.get_available_providers(), ort.get_available_providers()
print("onnxruntime", ort.__version__, ort.get_available_providers())
'@
& $venvPython -c $mlProbe
if ($LASTEXITCODE -ne 0) { throw 'Native Windows InsightFace/ONNX Runtime validation failed after uv sync.' }
Remove-Item Env:VIRTUAL_ENV

$sitePackages = (& $venvPython -c 'import site; print(site.getsitepackages()[0])').Trim()
$runtimePython = Get-Item -LiteralPath $pythonExe
$runtimeSite = (& $runtimePython.FullName -c 'import site; print(site.getsitepackages()[0])').Trim()
New-Item -ItemType Directory -Force -Path $runtimeSite | Out-Null
Copy-Directory $sitePackages $runtimeSite
Copy-Directory (Join-Path $mlDir 'immich_ml') (Join-Path $runtimeSite 'immich_ml')
$venvConfig = Join-Path $runtimePython.Directory.FullName 'pyvenv.cfg'
(Get-Content -LiteralPath $venvConfig) -replace '^include-system-site-packages = false$', 'include-system-site-packages = true' |
    Set-Content -Encoding ascii -LiteralPath $venvConfig

# Re-run the same native import probe from the relocatable runtime, not only the
# temporary build venv, so packaging cannot accidentally omit a .pyd or DLL.
& $runtimePython.FullName -c $mlProbe
if ($LASTEXITCODE -ne 0) { throw 'Relocatable Machine Learning runtime lost a native ONNX Runtime dependency.' }

# Keep non-Python runtime files used by the launcher/log configuration beside the package.
foreach ($name in @('log_conf.json')) {
    $candidate = Join-Path $mlDir "immich_ml\$name"
    if (Test-Path $candidate) { Copy-Item $candidate -Destination (Join-Path $runtimeSite 'immich_ml') -Force }
}

$packagedPython = Join-Path $Destination 'python-runtime'
Copy-Directory $runtimePython.Directory.FullName $packagedPython
$pythonVersion = (& $runtimePython.FullName --version).Trim()
$manifest = [ordered]@{
    python = $pythonVersion
    requestedPython = $versions.python.version
    extra = 'cpu'
    sourceLock = 'machine-learning/uv.lock'
    builtAtUtc = [DateTime]::UtcNow.ToString('o')
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 -LiteralPath (Join-Path $Destination 'ml-manifest.json')
Write-Host "Machine Learning runtime staged at $Destination"
