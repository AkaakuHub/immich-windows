#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReleaseRoot,
    [Parameter(Mandatory)][string]$InstallRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$manifest = Get-Content -Raw -LiteralPath (Join-Path $ReleaseRoot 'manifest.json') | ConvertFrom-Json
Import-Module (Join-Path $PSScriptRoot '..\runtime\Common.psm1') -Force
$packageVersion = 'v' + (Get-WindowsPackageVersion $manifest).ToString(4)
$versions = $manifest.dependencies
$cache = Join-Path $InstallRoot 'cache\downloads'
$stageRoot = Join-Path $InstallRoot 'cache\runtime-extract'
New-Item -ItemType Directory -Path $cache,$stageRoot -Force | Out-Null

function Get-CachedArchive([string]$Name,[string]$Uri,[string]$Sha256) {
    $path = Join-Path $cache $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $partial = "$path.download"
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        Write-Host "Downloading $Name"
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $partial
            Move-Item -LiteralPath $partial -Destination $path
        } catch {
            Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
            throw
        }
    }
    if ($Sha256 -and (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash -ine $Sha256) {
        throw "Cached/downloaded archive checksum mismatch: $path. Remove this archive and retry."
    }
    return $path
}

function Expand-CachedZip([string]$Name,[string]$Uri) {
    $archive = Get-CachedArchive $Name $Uri
    $destination = Join-Path $stageRoot ([IO.Path]::GetFileNameWithoutExtension($Name))
    if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Recurse -Force }
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    Expand-Archive -LiteralPath $archive -DestinationPath $destination -Force
    return $destination
}

function Copy-DirectoryContents([string]$Source,[string]$Destination) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | Copy-Item -Destination $Destination -Recurse -Force
}

$nodeRoot = Join-Path $ReleaseRoot 'runtime\node'
$nodeExe = Join-Path $nodeRoot 'node.exe'
if (-not (Test-Path -LiteralPath $nodeExe -PathType Leaf) -or -not (Test-Path -LiteralPath (Join-Path $nodeRoot 'npm.cmd') -PathType Leaf)) {
    if (Test-Path -LiteralPath $nodeRoot) { Remove-Item -LiteralPath $nodeRoot -Recurse -Force }
    $nodeStage = Expand-CachedZip $versions.node.asset "https://nodejs.org/dist/v$($versions.node.version)/$($versions.node.asset)"
    $nodeFolder = Get-ChildItem -LiteralPath $nodeStage -Directory | Select-Object -First 1
    if (-not $nodeFolder) { throw 'Node archive has an unexpected layout.' }
    Copy-DirectoryContents $nodeFolder.FullName $nodeRoot
}
if (((& $nodeExe --version).Trim().TrimStart('v')) -ne $versions.node.version) { throw 'Installed Node version does not match manifest.' }

$ffmpegRoot = Join-Path $ReleaseRoot 'runtime\ffmpeg'
if (-not (Test-Path -LiteralPath (Join-Path $ffmpegRoot 'ffmpeg.exe') -PathType Leaf) -or -not (Test-Path -LiteralPath (Join-Path $ffmpegRoot 'ffprobe.exe') -PathType Leaf)) {
    if (Test-Path -LiteralPath $ffmpegRoot) { Remove-Item -LiteralPath $ffmpegRoot -Recurse -Force }
    $ffmpegStage = Expand-CachedZip $versions.ffmpeg.asset "https://github.com/jellyfin/jellyfin-ffmpeg/releases/download/v$($versions.ffmpeg.version)/$($versions.ffmpeg.asset)"
    $ffmpegExe = Get-ChildItem -LiteralPath $ffmpegStage -Filter ffmpeg.exe -File -Recurse | Select-Object -First 1
    if (-not $ffmpegExe) { throw 'FFmpeg archive does not contain ffmpeg.exe.' }
    Copy-DirectoryContents $ffmpegExe.Directory.FullName $ffmpegRoot
}
if (-not (Test-Path -LiteralPath (Join-Path $ffmpegRoot 'ffprobe.exe') -PathType Leaf)) { throw 'FFmpeg runtime is missing ffprobe.exe.' }

$valkeyRoot = Join-Path $ReleaseRoot 'dependencies\valkey'
if (-not (Test-Path -LiteralPath (Join-Path $valkeyRoot 'ValkeyService.exe') -PathType Leaf)) {
    $valkeyStage = Expand-CachedZip $versions.valkey.asset "https://github.com/valkey-windows/valkey-windows/releases/download/$($versions.valkey.version)/$($versions.valkey.asset)"
    $valkeyExe = Get-ChildItem -LiteralPath $valkeyStage -Filter ValkeyService.exe -File -Recurse | Select-Object -First 1
    if (-not $valkeyExe) { throw 'Valkey archive does not contain ValkeyService.exe.' }
    Copy-DirectoryContents $valkeyExe.Directory.FullName $valkeyRoot
}

$winswRoot = Join-Path $ReleaseRoot 'runtime\winsw'
$winswExe = Join-Path $winswRoot $versions.winsw.asset
if (-not (Test-Path -LiteralPath $winswExe -PathType Leaf)) {
    $winswUri = "https://github.com/winsw/winsw/releases/download/v$($versions.winsw.version)/$($versions.winsw.asset)"
    $winswDownload = Get-CachedArchive "winsw-$($versions.winsw.version)-$($versions.winsw.asset)" $winswUri
    New-Item -ItemType Directory -Path $winswRoot -Force | Out-Null
    Copy-Item -LiteralPath $winswDownload -Destination $winswExe -Force
}

$uvRoot = Join-Path $InstallRoot "tools\uv\$($versions.uv.version)"
$uvExe = Join-Path $uvRoot 'uv.exe'
if (-not (Test-Path -LiteralPath $uvExe -PathType Leaf)) {
    $uvArchiveName = "uv-$($versions.uv.version)-$($versions.uv.asset)"
    $uvStage = Expand-CachedZip $uvArchiveName "https://github.com/astral-sh/uv/releases/download/$($versions.uv.version)/$($versions.uv.asset)"
    $uvFile = Get-ChildItem -LiteralPath $uvStage -Filter uv.exe -File -Recurse | Select-Object -First 1
    if (-not $uvFile) { throw 'uv archive does not contain uv.exe.' }
    New-Item -ItemType Directory -Path $uvRoot -Force | Out-Null
    Copy-Item -LiteralPath $uvFile.FullName -Destination $uvExe -Force
}
$pythonRoot = Join-Path $ReleaseRoot 'machine-learning\python-runtime'
$pythonExe = Get-ChildItem -LiteralPath $pythonRoot -Filter python.exe -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\Scripts\\' } | Select-Object -First 1
if (-not $pythonExe) {
    $env:UV_CACHE_DIR = Join-Path $InstallRoot 'cache\uv'
    $env:UV_PYTHON_INSTALL_DIR = $pythonRoot
    & $uvExe python install $versions.python.version --no-bin
    if ($LASTEXITCODE -ne 0) { throw 'Could not install pinned CPython runtime with uv.' }
    $pythonExe = Get-ChildItem -LiteralPath $pythonRoot -Filter python.exe -File -Recurse | Where-Object { $_.FullName -notmatch '\\Scripts\\' } | Select-Object -First 1
}
if (-not $pythonExe) { throw 'Pinned CPython installation did not produce python.exe.' }

$nativeZipName = "immich-windows-$packageVersion-native-dependencies.zip"
$nativeReady = (Test-Path -LiteralPath (Join-Path $ReleaseRoot 'server\node_modules\@img\sharp-win32-x64\lib\libvips-core.dll') -PathType Leaf) -and
    (Test-Path -LiteralPath (Join-Path $ReleaseRoot 'dependencies\postgres-extensions\vector\vector.dll') -PathType Leaf) -and
    (Test-Path -LiteralPath (Join-Path $ReleaseRoot 'dependencies\postgres-extensions\vchord\vchord.dll') -PathType Leaf) -and
    (Test-Path -LiteralPath (Join-Path $ReleaseRoot 'runtime\vc-runtime\vcruntime140.dll') -PathType Leaf)
if (-not $nativeReady) {
    $nativeUri = "https://github.com/AkaakuHub/immich-windows/releases/download/$packageVersion/$nativeZipName"
    $nativeZip = Get-CachedArchive $nativeZipName $nativeUri $manifest.nativeDependenciesSha256
    $nativeStage = Join-Path $stageRoot 'native-dependencies'
    if (Test-Path -LiteralPath $nativeStage) { Remove-Item -LiteralPath $nativeStage -Recurse -Force }
    New-Item -ItemType Directory -Path $nativeStage -Force | Out-Null
    Expand-Archive -LiteralPath $nativeZip -DestinationPath $nativeStage -Force
    Copy-DirectoryContents $nativeStage $ReleaseRoot
}

Get-ChildItem -LiteralPath $stageRoot -Directory | Remove-Item -Recurse -Force
Write-Host 'Runtime tools and native payloads are installed outside the application ZIP.'
