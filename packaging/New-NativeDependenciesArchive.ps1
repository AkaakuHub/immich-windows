[CmdletBinding()]
param([string]$Destination)

Import-Module (Join-Path $PSScriptRoot '..\build\Common.psm1') -Force
$root = Get-RepositoryRoot
$upstream = Read-JsonFile (Join-Path $root 'upstream.json')
$native = Join-Path $root 'artifacts\native'
foreach ($required in @('sharp-libvips-custom','vc-runtime','postgres-extensions\vector','postgres-extensions\vchord')) {
    if (-not (Test-Path -LiteralPath (Join-Path $native $required) -PathType Container)) { throw "Native dependency build output is missing: $required" }
}
if (-not $Destination) { $Destination = Join-Path $root "dist\immich-windows-$($upstream.version)-native-dependencies.zip" }
$stage = New-CleanDirectory (Join-Path $root 'dist\native-dependencies')
$sharpOutput = Join-Path $stage 'dependencies\sharp\lib'
Get-ChildItem -LiteralPath (Join-Path $native 'sharp-libvips-custom') -Filter '*.dll' -File -Recurse | ForEach-Object {
    $relative = $_.FullName.Substring((Join-Path $native 'sharp-libvips-custom').Length).TrimStart('\')
    $target = Join-Path $sharpOutput $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    Copy-Item -LiteralPath $_.FullName -Destination $target -Force
}
if (-not (Test-Path -LiteralPath (Join-Path $sharpOutput 'libvips-core.dll') -PathType Leaf)) { throw 'Custom Sharp bundle is missing libvips-core.dll.' }
Copy-Directory (Join-Path $native 'vc-runtime') (Join-Path $stage 'runtime\vc-runtime')
Copy-Directory (Join-Path $native 'postgres-extensions') (Join-Path $stage 'dependencies\postgres-extensions')
foreach ($required in @(
    'runtime\vc-runtime\vcruntime140.dll','runtime\vc-runtime\msvcp140.dll',
    'dependencies\postgres-extensions\vector\vector.dll','dependencies\postgres-extensions\vector\vector.control',
    'dependencies\postgres-extensions\vchord\vchord.dll','dependencies\postgres-extensions\vchord\vchord.control'
)) {
    if (-not (Test-Path -LiteralPath (Join-Path $stage $required) -PathType Leaf)) { throw "Native dependency payload is incomplete: $required" }
}
if (Test-Path -LiteralPath $Destination -PathType Leaf) { Remove-Item -LiteralPath $Destination -Force }
New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $Destination -CompressionLevel Optimal
Write-Host "Native dependencies archive: $Destination"
