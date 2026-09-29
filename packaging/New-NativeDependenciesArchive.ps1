[CmdletBinding()]
param([string]$Destination)

Import-Module (Join-Path $PSScriptRoot '..\build\Common.psm1') -Force
$root = Get-RepositoryRoot
$upstream = Read-JsonFile (Join-Path $root 'upstream.json')
$native = Join-Path $root 'artifacts\native'
foreach ($required in @('vc-runtime','postgres-extensions\vector','postgres-extensions\vchord')) {
    if (-not (Test-Path -LiteralPath (Join-Path $native $required) -PathType Container)) { throw "Native dependency build output is missing: $required" }
}
$versions = Read-JsonFile (Join-Path $root 'dependencies\versions.json')
$postgresMetadataPath = Join-Path $native 'postgres-extensions\build-inputs.json'
if (-not (Test-Path -LiteralPath $postgresMetadataPath -PathType Leaf)) { throw 'PostgreSQL extension build metadata is missing.' }
$postgresMetadata = Read-JsonFile $postgresMetadataPath
$postgresInputs = @{
    postgresql = $versions.postgresql.version
    pgvector = $versions.pgvector.commit
    vectorchord = $versions.vectorchord.commit
    pgrx = $versions.vectorchord.pgrx
    rustToolchain = $versions.vectorchord.rustToolchain
}
foreach ($field in $postgresInputs.Keys) {
    if ([string]$postgresMetadata.$field -ne [string]$postgresInputs[$field]) { throw "PostgreSQL extension artifact does not match the pinned $field." }
}
$application = Join-Path $root 'artifacts\application'
$sharpPackages = @(Get-ChildItem -LiteralPath (Join-Path $application 'server\node_modules\.pnpm') -Directory -Filter '@img+sharp-win32-x64@*' -ErrorAction SilentlyContinue)
if ($sharpPackages.Count -ne 1) { throw "Expected one tested Sharp runtime package; found $($sharpPackages.Count)." }
$sharpSourceLib = Join-Path $sharpPackages[0].FullName 'node_modules\@img\sharp-win32-x64\lib'
foreach ($required in @('sharp-libvips-injection.json','sharp-libvips-qualification.json')) {
    if (-not (Test-Path -LiteralPath (Join-Path $application $required) -PathType Leaf)) { throw "Qualified Sharp build output is missing: $required" }
}
if (-not (Test-Path -LiteralPath $sharpSourceLib -PathType Container)) { throw "Tested Sharp runtime output is missing: $sharpSourceLib" }
if (-not $Destination) { $Destination = Join-Path $root "dist\immich-windows-$($upstream.version)-native-dependencies.zip" }
$stage = New-CleanDirectory (Join-Path $root 'dist\native-dependencies')
$sharpOutput = Join-Path $stage 'dependencies\sharp\lib'
Get-ChildItem -LiteralPath $sharpSourceLib -Filter '*.dll' -File -Recurse | ForEach-Object {
    $relative = $_.FullName.Substring($sharpSourceLib.Length).TrimStart('\')
    $target = Join-Path $sharpOutput $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    Copy-Item -LiteralPath $_.FullName -Destination $target -Force
}
foreach ($required in @('libvips-core.dll','libvips-42.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $sharpOutput $required) -PathType Leaf)) { throw "Tested Sharp DLL payload is incomplete: $required" }
}
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
