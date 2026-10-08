#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackageRoot,[string]$Version)

$ErrorActionPreference = 'Stop'
$PackageRoot = (Resolve-Path -LiteralPath $PackageRoot).Path
$manifestPath = Join-Path $PackageRoot 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Package manifest is missing: $manifestPath" }
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
Import-Module (Join-Path $PSScriptRoot '..\runtime\Common.psm1') -Force
$packageVersion = 'v' + (Get-WindowsPackageVersion $manifest).ToString(4)
if ($manifest.schemaVersion -ne 2 -or $manifest.sourceCommit -notmatch '^[0-9a-f]{40}$' -or
    -not @($manifest.dependencyPayloads.PSObject.Properties).Count) { throw 'Invalid Windows package provenance.' }
if ($manifest.immichVersion -notmatch '^v\d+\.\d+\.\d+$' -or ($Version -and $packageVersion -ne $Version) -or
    $manifest.target -ne 'windows-x64-native' -or $manifest.mediaStack.sharpLibvips -ne 'custom-immich-compatible' -or
    -not $manifest.mediaStack.productionQualified) { throw 'The package is not a qualified Windows native release.' }

foreach ($required in @(
    'runtime\tray\ImmichTray.exe','build\www\favicon.ico','server\dist\main.js','server\.immich\plugin-sdk\dist\index.js','build\www\index.html','machine-learning\requirements.txt','machine-learning\wheel-requirements.txt',
    'machine-learning\app\immich_ml\__main__.py','machine-learning\ml-manifest.json','runtime\DependencyPayload.psm1',
    'installer\Install-RuntimeDependencies.ps1','installer\Install-MachineLearningDependencies.ps1',
    'sharp-libvips-qualification.json','installer\Update.ps1','runtime\Common.psm1','runtime\Native-Probe.psm1','runtime\DirectML.psm1','runtime\DirectML-Adapter.py','runtime\tray\DesktopShell.cs',
    'runtime\launchers\Start-Immich.ps1','runtime\launchers\Stop-Immich.ps1','runtime\launchers\Load-ImmichEnv.ps1',
    'runtime\metadata-date-repair\Repair-MetadataDates.cmd','runtime\metadata-date-repair\Start-MetadataDateRepair.ps1',
    'runtime\metadata-date-repair\MetadataDateRepair.Launcher.psm1','runtime\metadata-date-repair\guided.cjs',
    'runtime\metadata-date-repair\cli.cjs','runtime\metadata-date-repair\core.cjs','runtime\metadata-date-repair\runtime.cjs','runtime\metadata-date-repair\resume.cjs',
    'tests\Smoke-Windows.ps1','tests\DirectML-ProviderPolicy.py','migration\Import-Database.ps1','migration\New-DatabaseBackup.ps1',
    'README.md','docs\install.md','docs\operations.md','docs\migration.md'
)) {
    if (-not (Test-Path -LiteralPath (Join-Path $PackageRoot $required) -PathType Leaf)) { throw "Release package is incomplete: $required" }
}
if (Test-Path -LiteralPath (Join-Path $PackageRoot 'Install.cmd')) { throw 'Install.cmd must be distributed as a separate Release asset.' }

foreach ($forbidden in @(
    'server\node_modules','cli\node_modules','machine-learning\python-runtime','machine-learning\uv.exe','machine-learning\wheelhouse',
    'machine-learning\build-inputs.json','machine-learning\.build-inputs',
    'runtime\node','runtime\ffmpeg','runtime\winsw','runtime\vc-runtime','dependencies\sharp','build\geodata',
    'dependencies\valkey','dependencies\postgres-extensions'
)) {
    if (Test-Path -LiteralPath (Join-Path $PackageRoot $forbidden)) { throw "Runtime dependency must be installed separately from the application package: $forbidden" }
}
$embeddedDependencyTree = Get-ChildItem -LiteralPath $PackageRoot -Directory -Recurse -Force |
    Where-Object { $_.Name -in @('node_modules','site-packages') } | Select-Object -First 1
if ($embeddedDependencyTree) { throw "Application package contains a dependency directory: $($embeddedDependencyTree.FullName)" }
if (-not (Test-Path -LiteralPath (Join-Path $PackageRoot 'runtime\launchers\Install-NodeDependencies.ps1') -PathType Leaf)) {
    throw 'Node dependency installer is missing.'
}
foreach ($project in @('server','cli')) {
    foreach ($name in @('package.json','pnpm-lock.yaml','pnpm-workspace.yaml')) {
        if (-not (Test-Path -LiteralPath (Join-Path $PackageRoot "$project\$name") -PathType Leaf)) { throw "Portable $project dependency metadata is missing: $name" }
    }
    $package = Get-Content -Raw -LiteralPath (Join-Path $PackageRoot "$project\package.json") | ConvertFrom-Json
    if ($package.packageManager -ne "pnpm@$($manifest.dependencies.pnpm.version)") { throw "Portable $project package does not pin manifest pnpm version." }
}
$requirements = Get-Content -Raw -LiteralPath (Join-Path $PackageRoot 'machine-learning\requirements.txt')
if (-not $requirements.Trim()) { throw 'Machine Learning dependency lock export is empty.' }
Write-Host "Thin Windows application package: $packageVersion"
