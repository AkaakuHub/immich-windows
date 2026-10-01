#requires -Version 7.0
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
$mlDir = Join-Path $Source 'machine-learning'
$app = Join-Path $Destination 'app'
Copy-Directory (Join-Path $mlDir 'immich_ml') (Join-Path $app 'immich_ml')
$uv = Assert-Command uv
$requirementsPath = Join-Path $Destination 'requirements.txt'
Push-Location -LiteralPath $mlDir
try {
    & $uv export --quiet --frozen --extra cpu --no-dev --no-emit-project --no-editable --no-hashes --format requirements-txt --output-file $requirementsPath
    if ($LASTEXITCODE -ne 0) { throw 'Could not export the pinned Machine Learning dependency list from upstream uv.lock.' }
} finally { Pop-Location }

$requirementsLines = @(Get-Content -LiteralPath $requirementsPath)
$onnxRuntimeLines = @($requirementsLines | Where-Object { $_ -match '^onnxruntime==' })
if ($onnxRuntimeLines.Count -ne 1) {
    throw "Expected exactly one onnxruntime requirement from the upstream CPU extra, found $($onnxRuntimeLines.Count)."
}
$directmlRequirement = "onnxruntime-directml==$($versions.onnxruntimeDirectml.version)"
$requirementsLines = @($requirementsLines | ForEach-Object {
    if ($_ -match '^onnxruntime==') { $directmlRequirement } else { $_ }
})
foreach ($required in @(
    "sympy==$($versions.onnxruntimeDirectml.sympy)",
    "mpmath==$($versions.onnxruntimeDirectml.mpmath)"
)) {
    $name = $required.Split('=')[0]
    if (-not ($requirementsLines -match ("^" + [regex]::Escape($name) + "=="))) {
        $requirementsLines += $required
    }
}
$requirementsLines | Set-Content -Encoding utf8 -LiteralPath $requirementsPath

$manifest = [ordered]@{
    python = $versions.python.version
    baseExtra = 'cpu'
    runtime = 'directml'
    onnxruntimeDirectml = $versions.onnxruntimeDirectml.version
    sourceLock = 'machine-learning/uv.lock'
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 -LiteralPath (Join-Path $Destination 'ml-manifest.json')
Write-Host 'Machine Learning source and locked requirements staged; runtime dependencies are installed on the target.'
