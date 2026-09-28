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
    'runtime\corepack\package.json',
    'runtime\corepack\LICENSE.md',
    'runtime\corepack\dist\corepack.js',
    'runtime\corepack\dist\lib\corepack.cjs',
    'runtime\ffmpeg\ffmpeg.exe',
    'machine-learning\python-runtime\python.exe',
    'dependencies\valkey\ValkeyService.exe',
    'dependencies\postgres-extensions\vector\vector.dll',
    'dependencies\postgres-extensions\vchord\vchord.dll',
    'sharp-libvips-qualification.json',
    'Install.cmd',
    'installer\Update.ps1'
)){
    if(-not(Test-Path -LiteralPath (Join-Path $PackageRoot $required) -PathType Leaf)){
        throw "Release package is incomplete: $required"
    }
}
foreach($project in @('server','cli','runtime')){
    if(Test-Path -LiteralPath (Join-Path $PackageRoot "$project\node_modules")){
        throw "Release package must not contain $project\node_modules."
    }
}
foreach($project in @('server','cli')){
    foreach($name in @('package.json','pnpm-lock.yaml','pnpm-workspace.yaml')){
        if(-not(Test-Path -LiteralPath (Join-Path $PackageRoot "$project\$name") -PathType Leaf)){
            throw "Portable $project dependency metadata is missing: $name"
        }
    }
    $package=Get-Content -Raw -LiteralPath (Join-Path $PackageRoot "$project\package.json")|ConvertFrom-Json
    if($package.packageManager -ne "pnpm@$($manifest.dependencies.pnpm.version)"){
        throw "Portable $project package does not pin the manifest pnpm version."
    }
}
if($manifest.mediaStack.sharpLibvips -eq 'custom-immich-compatible'){
    foreach($required in @('dependencies\sharp\lib\libvips-42.dll','dependencies\sharp\lib\libvips-core.dll')){
        if(-not(Test-Path -LiteralPath (Join-Path $PackageRoot $required) -PathType Leaf)){
            throw "Custom Sharp runtime payload is missing: $required"
        }
    }
}
Write-Host "Qualified Windows native package: $($manifest.immichVersion)"
