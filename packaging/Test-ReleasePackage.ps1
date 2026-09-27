[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackageRoot,
    [string]$Version
)

$ErrorActionPreference='Stop'
$PackageRoot=(Resolve-Path -LiteralPath $PackageRoot).Path
$manifestPath=Join-Path $PackageRoot 'manifest.json'
if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){throw "Package manifest is missing: $manifestPath"}
$manifest=Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json
if($manifest.immichVersion -notmatch '^v\d+\.\d+\.\d+$' -or
    ($Version -and $manifest.immichVersion -ne $Version) -or
    $manifest.target -ne 'windows-x64-native' -or
    $manifest.mediaStack.sharpLibvips -ne 'custom-immich-compatible' -or
    -not $manifest.mediaStack.productionQualified){
    throw 'The package is not a qualified Windows native release.'
}
foreach($required in @(
    'server\dist\main.js',
    'build\www\index.html',
    'runtime\node\node.exe',
    'runtime\ffmpeg\ffmpeg.exe',
    'machine-learning\python-runtime\python.exe',
    'dependencies\valkey\ValkeyService.exe',
    'dependencies\postgres-extensions\vector\vector.dll',
    'dependencies\postgres-extensions\vchord\vchord.dll',
    'sharp-libvips-qualification.json',
    'installer\Update.ps1'
)){
    if(-not(Test-Path -LiteralPath (Join-Path $PackageRoot $required) -PathType Leaf)){
        throw "Release package is incomplete: $required"
    }
}
Write-Host "Qualified Windows native package: $($manifest.immichVersion)"
