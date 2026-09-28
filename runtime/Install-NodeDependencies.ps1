[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReleaseRoot,
    [Parameter(Mandatory)][string]$InstallRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$nodeRoot = Join-Path $ReleaseRoot 'runtime\node'
$node = Join-Path $nodeRoot 'node.exe'
$corepack = Join-Path $ReleaseRoot 'runtime\corepack\dist\corepack.js'
foreach ($required in @($node,$corepack)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Node package manager runtime is missing: $required" }
}

$oldCorepackHome = $env:COREPACK_HOME
$oldDownloadPrompt = $env:COREPACK_ENABLE_DOWNLOAD_PROMPT
$oldSharpIgnoreGlobal = $env:SHARP_IGNORE_GLOBAL_LIBVIPS
$oldNodePath = $env:NODE_PATH
$env:COREPACK_HOME = Join-Path $InstallRoot 'cache\corepack'
$env:COREPACK_ENABLE_DOWNLOAD_PROMPT = '0'
$env:SHARP_IGNORE_GLOBAL_LIBVIPS = 'true'
$env:NODE_PATH = Join-Path $ReleaseRoot 'runtime'
New-Item -ItemType Directory -Path $env:COREPACK_HOME -Force | Out-Null
$store = Join-Path $InstallRoot 'cache\pnpm-store'
function Install-ProjectDependencies([string]$Project) {
    $arguments = @(
        $corepack,'pnpm','install','--prod','--frozen-lockfile',
        '--config.node-linker=hoisted','--store-dir',$store
    )
    Push-Location -LiteralPath $Project
    try {
        & $node @arguments
        if ($LASTEXITCODE -ne 0) { throw "pnpm install failed in $Project (exit code $LASTEXITCODE)." }
    } finally {
        Pop-Location
    }
}
try {
    foreach ($projectName in @('server','cli')) {
        $project = Join-Path $ReleaseRoot $projectName
        foreach ($name in @('package.json','pnpm-lock.yaml','pnpm-workspace.yaml')) {
            if (-not (Test-Path -LiteralPath (Join-Path $project $name) -PathType Leaf)) {
                throw "Portable $projectName dependency metadata is missing: $name"
            }
        }
        Install-ProjectDependencies $project
    }

    $customSharp = Join-Path $ReleaseRoot 'dependencies\sharp\lib'
    if (Test-Path -LiteralPath $customSharp -PathType Container) {
        $sharpLib = Join-Path $ReleaseRoot 'server\node_modules\@img\sharp-win32-x64\lib'
        if (-not (Test-Path -LiteralPath $sharpLib -PathType Container)) { throw "Installed Sharp runtime is missing: $sharpLib" }
        $stockDlls = @(Get-ChildItem -LiteralPath $sharpLib -Filter '*.dll' -File -Recurse)
        $stockDlls | Remove-Item -Force
        $customDlls = @(Get-ChildItem -LiteralPath $customSharp -Filter '*.dll' -File -Recurse)
        if (-not $customDlls.Count) { throw 'Custom Sharp payload contains no DLLs.' }
        foreach ($dll in $customDlls) {
            $relative = $dll.FullName.Substring($customSharp.Length).TrimStart('\')
            $target = Join-Path $sharpLib $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            Move-Item -LiteralPath $dll.FullName -Destination $target -Force
        }
        Remove-Item -LiteralPath $customSharp -Recurse -Force
    } else {
        $manifest = Get-Content -Raw -LiteralPath (Join-Path $ReleaseRoot 'manifest.json') | ConvertFrom-Json
        if ($manifest.mediaStack.sharpLibvips -eq 'custom-immich-compatible' -and
            -not (Test-Path -LiteralPath (Join-Path $ReleaseRoot 'server\node_modules\@img\sharp-win32-x64\lib\libvips-core.dll') -PathType Leaf)) {
            throw 'Custom Sharp DLLs are missing; reinstall this release from its original package.'
        }
    }
} finally {
    $env:COREPACK_HOME = $oldCorepackHome
    $env:COREPACK_ENABLE_DOWNLOAD_PROMPT = $oldDownloadPrompt
    $env:SHARP_IGNORE_GLOBAL_LIBVIPS = $oldSharpIgnoreGlobal
    $env:NODE_PATH = $oldNodePath
}
