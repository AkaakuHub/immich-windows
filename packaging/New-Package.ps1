[CmdletBinding()]
param(
    [string]$Destination,
    [switch]$AllowStockSharp
)
Import-Module (Join-Path $PSScriptRoot '..\build\Common.psm1') -Force
$root = Get-RepositoryRoot
$upstream = Read-JsonFile (Join-Path $root 'upstream.json')
$versions = Read-JsonFile (Join-Path $root 'dependencies\versions.json')
if (-not $Destination) { $Destination = Join-Path $root "dist\immich-windows-$($upstream.version)-win-x64" }
$app = Join-Path $root 'artifacts\application'
$ml = Join-Path $root 'artifacts\machine-learning'
$native = Join-Path $root 'artifacts\native'
foreach ($required in @($app,$ml,$native)) { if (-not (Test-Path $required)) { throw "Build artifact missing: $required" } }
$sharpMarker = Join-Path $app 'sharp-libvips-injection.json'
$sharpQualificationMarker = Join-Path $app 'sharp-libvips-qualification.json'
$customSharp = Test-Path -LiteralPath $sharpMarker -PathType Leaf
$mediaStackQualified = $customSharp -and (Test-Path -LiteralPath $sharpQualificationMarker -PathType Leaf)
if (-not $mediaStackQualified -and -not $AllowStockSharp) {
    throw 'The Windows media stack has not completed the required private fixture matrix. Inject custom Sharp/libvips and run Test-SharpCapabilities.ps1 with the documented JPEG/PNG/WebP/AVIF/HEIF/RAW/JXL fixtures, or use -AllowStockSharp only for isolated pre-qualification smoke builds.'
}
$Destination = New-CleanDirectory $Destination
Copy-Directory (Join-Path $app 'server') (Join-Path $Destination 'server')
Copy-Directory (Join-Path $app 'cli') (Join-Path $Destination 'cli')
Copy-Directory (Join-Path $app 'build') (Join-Path $Destination 'build')
Copy-Directory $ml (Join-Path $Destination 'machine-learning')
Copy-Directory (Join-Path $native 'node') (Join-Path $Destination 'runtime\node')
Copy-Directory (Join-Path $native 'ffmpeg') (Join-Path $Destination 'runtime\ffmpeg')
Copy-Directory (Join-Path $native 'winsw') (Join-Path $Destination 'runtime\winsw')
Copy-Directory (Join-Path $native 'vc-runtime') (Join-Path $Destination 'runtime\vc-runtime')
Copy-Directory (Join-Path $native 'valkey') (Join-Path $Destination 'dependencies\valkey')
if (Test-Path (Join-Path $native 'postgres-extensions')) {
    Copy-Directory (Join-Path $native 'postgres-extensions') (Join-Path $Destination 'dependencies\postgres-extensions')
}
Copy-Item (Join-Path $app 'LICENSE') (Join-Path $Destination 'LICENSE') -Force
if ($customSharp) {
    Copy-Item -LiteralPath $sharpMarker -Destination (Join-Path $Destination 'sharp-libvips-injection.json') -Force
    if (Test-Path -LiteralPath $sharpQualificationMarker -PathType Leaf) { Copy-Item -LiteralPath $sharpQualificationMarker -Destination (Join-Path $Destination 'sharp-libvips-qualification.json') -Force }
    $smokeMarker = Join-Path $app 'sharp-libvips-smoke.json'
    if (Test-Path -LiteralPath $smokeMarker -PathType Leaf) { Copy-Item -LiteralPath $smokeMarker -Destination (Join-Path $Destination 'sharp-libvips-smoke.json') -Force }
    if (Test-Path -LiteralPath (Join-Path $app 'media-stack')) { Copy-Directory (Join-Path $app 'media-stack') (Join-Path $Destination 'media-stack') }
}
Copy-Directory (Join-Path $root 'runtime') (Join-Path $Destination 'runtime\launchers')
Copy-Directory (Join-Path $root 'packaging') (Join-Path $Destination 'installer')
if (Test-Path (Join-Path $root 'migration')) { Copy-Directory (Join-Path $root 'migration') (Join-Path $Destination 'migration') }
if (Test-Path (Join-Path $root 'tests')) { Copy-Directory (Join-Path $root 'tests') (Join-Path $Destination 'tests') }
Copy-Item (Join-Path $root 'config\immich.env.example') (Join-Path $Destination 'immich.env.example') -Force
$manifest = [ordered]@{
    schemaVersion = 1
    immichVersion = $upstream.version
    upstreamRepository = $upstream.repository
    upstreamCommit = (Get-Content -Raw (Join-Path $app 'application-manifest.json') | ConvertFrom-Json).upstreamCommit
    target = 'windows-x64-native'
    mediaStack = [ordered]@{
        sharpLibvips = $(if ($customSharp) { 'custom-immich-compatible' } else { 'stock-sharp-windows' })
        productionQualified = [bool]$mediaStackQualified
        fixtureQualification = $(if ($mediaStackQualified) { Get-Content -Raw -LiteralPath $sharpQualificationMarker | ConvertFrom-Json } else { $null })
    }
    dependencies = $versions
    builtAtUtc = [DateTime]::UtcNow.ToString('o')
}
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Encoding utf8 -LiteralPath (Join-Path $Destination 'manifest.json')
Write-Host "Package: $Destination"
