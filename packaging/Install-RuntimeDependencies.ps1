#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReleaseRoot,
    [Parameter(Mandatory)][string]$InstallRoot,
    [Collections.Generic.List[object]]$DependencyReusePlan
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$manifest = Get-Content -Raw -LiteralPath (Join-Path $ReleaseRoot 'manifest.json') | ConvertFrom-Json
Import-Module (Join-Path $PSScriptRoot '..\runtime\Common.psm1') -Force
$packageVersion = 'v' + (Get-WindowsPackageVersion $manifest).ToString(4)
$versions = $manifest.dependencies
$reuseSource = Get-ImmichDependencySource -InstallRoot $InstallRoot -ReleaseRoot $ReleaseRoot
$reuseManifest = if ($reuseSource) { Get-Content -Raw -LiteralPath (Join-Path $reuseSource 'manifest.json') | ConvertFrom-Json } else { $null }

function Reuse-Runtime([string]$Name,[string]$RelativePath,[string[]]$Required) {
    if ($null -eq $DependencyReusePlan) { return }
    if (-not $reuseSource -or -not (Test-ImmichDependencyPinEqual -Previous $reuseManifest -Candidate $manifest -Name $Name)) { return }
    $source = Join-Path $reuseSource $RelativePath
    $destination = Join-Path $ReleaseRoot $RelativePath
    if (Test-Path -LiteralPath $destination) { return }
    foreach ($file in $Required) { if (-not (Test-Path -LiteralPath (Join-Path $source $file) -PathType Leaf)) { return } }
    if ($Name -eq 'node') {
        $actual = & (Join-Path $source 'node.exe') --version
        if ($LASTEXITCODE -ne 0 -or ([string]$actual).Trim().TrimStart('v') -ne $versions.node.version) { return }
    }
    Add-ImmichDependencyReuse -Plan $DependencyReusePlan -PreviousRelease $reuseSource -CandidateRelease $ReleaseRoot -RelativePath $RelativePath -Label $Name
}

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

function Expand-CachedZip([string]$Name,[string]$Uri,[string]$Sha256) {
    $archive = Get-CachedArchive $Name $Uri $Sha256
    $destination = Join-Path $stageRoot ([IO.Path]::GetFileNameWithoutExtension($Name))
    if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Recurse -Force }
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    $extractProgress=Start-ImmichProgress -Key extract -Detail $Name
    Expand-Archive -LiteralPath $archive -DestinationPath $destination -Force
    Update-ImmichProgress -State $extractProgress -Finished
    return $destination
}

function Copy-DirectoryContents([string]$Source,[string]$Destination) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | Copy-Item -Destination $Destination -Recurse -Force
}

function Move-ExtractedDirectory([string]$Source,[string]$Destination) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
    try { Move-Item -LiteralPath $Source -Destination $Destination }
    catch {
        $cause=$_.Exception
        while ($cause.InnerException) { $cause=$cause.InnerException }
        # A junction can hide a volume boundary from Move-Item's root check.
        # Only ERROR_NOT_SAME_DEVICE gets an explicit copy fallback; permission,
        # sharing, missing-file and other errors remain failures.
        if (-not $IsWindows -or $cause -isnot [IO.IOException] -or ($cause.HResult -band 0xffff) -ne 17) { throw }
        Copy-DirectoryContents $Source $Destination
        Remove-Item -LiteralPath $Source -Recurse -Force
    }
}

Reuse-Runtime 'node' 'runtime\node' @('node.exe','npm.cmd','node_modules\npm\bin\npm-cli.js')
Reuse-Runtime 'ffmpeg' 'runtime\ffmpeg' @('ffmpeg.exe','ffprobe.exe')
Reuse-Runtime 'valkey' 'dependencies\valkey' @('ValkeyService.exe','valkey-server.exe','valkey-cli.exe')
Reuse-Runtime 'winsw' 'runtime\winsw' @($versions.winsw.asset)

$nodeRoot = Get-ImmichDependencyReadPath -Path (Join-Path $ReleaseRoot 'runtime\node') -DependencyReusePlan $DependencyReusePlan
$nodeExe = Join-Path $nodeRoot 'node.exe'
if (-not (Test-Path -LiteralPath $nodeExe -PathType Leaf) -or -not (Test-Path -LiteralPath (Join-Path $nodeRoot 'npm.cmd') -PathType Leaf)) {
    if (Test-Path -LiteralPath $nodeRoot) { Remove-Item -LiteralPath $nodeRoot -Recurse -Force }
    $nodeStage = Expand-CachedZip $versions.node.asset "https://nodejs.org/dist/v$($versions.node.version)/$($versions.node.asset)"
    $nodeFolder = Get-ChildItem -LiteralPath $nodeStage -Directory | Select-Object -First 1
    if (-not $nodeFolder) { throw 'Node archive has an unexpected layout.' }
    # Promote disposable extraction instead of copying it before cleanup.
    # Move-Item provides its own cross-volume fallback for redirected caches.
    Move-ExtractedDirectory $nodeFolder.FullName $nodeRoot
}
if (((& $nodeExe --version).Trim().TrimStart('v')) -ne $versions.node.version) { throw 'Installed Node version does not match manifest.' }

$ffmpegRoot = Get-ImmichDependencyReadPath -Path (Join-Path $ReleaseRoot 'runtime\ffmpeg') -DependencyReusePlan $DependencyReusePlan
if (-not (Test-Path -LiteralPath (Join-Path $ffmpegRoot 'ffmpeg.exe') -PathType Leaf) -or -not (Test-Path -LiteralPath (Join-Path $ffmpegRoot 'ffprobe.exe') -PathType Leaf)) {
    if (Test-Path -LiteralPath $ffmpegRoot) { Remove-Item -LiteralPath $ffmpegRoot -Recurse -Force }
    $ffmpegChecksum = if ($versions.ffmpeg.PSObject.Properties['sha256']) { [string]$versions.ffmpeg.sha256 } else { $null }
    $ffmpegStage = Expand-CachedZip $versions.ffmpeg.asset "https://github.com/jellyfin/jellyfin-ffmpeg/releases/download/v$($versions.ffmpeg.version)/$($versions.ffmpeg.asset)" $ffmpegChecksum
    $ffmpegExe = Get-ChildItem -LiteralPath $ffmpegStage -Filter ffmpeg.exe -File -Recurse | Select-Object -First 1
    if (-not $ffmpegExe) { throw 'FFmpeg archive does not contain ffmpeg.exe.' }
    Move-ExtractedDirectory $ffmpegExe.Directory.FullName $ffmpegRoot
}
if (-not (Test-Path -LiteralPath (Join-Path $ffmpegRoot 'ffprobe.exe') -PathType Leaf)) { throw 'FFmpeg runtime is missing ffprobe.exe.' }

$valkeyRoot = Get-ImmichDependencyReadPath -Path (Join-Path $ReleaseRoot 'dependencies\valkey') -DependencyReusePlan $DependencyReusePlan
if (-not (Test-Path -LiteralPath (Join-Path $valkeyRoot 'ValkeyService.exe') -PathType Leaf)) {
    $valkeyStage = Expand-CachedZip $versions.valkey.asset "https://github.com/valkey-windows/valkey-windows/releases/download/$($versions.valkey.version)/$($versions.valkey.asset)"
    $valkeyExe = Get-ChildItem -LiteralPath $valkeyStage -Filter ValkeyService.exe -File -Recurse | Select-Object -First 1
    if (-not $valkeyExe) { throw 'Valkey archive does not contain ValkeyService.exe.' }
    if (Test-Path -LiteralPath $valkeyRoot) { Copy-DirectoryContents $valkeyExe.Directory.FullName $valkeyRoot }
    else { Move-ExtractedDirectory $valkeyExe.Directory.FullName $valkeyRoot }
}

$winswRoot = Get-ImmichDependencyReadPath -Path (Join-Path $ReleaseRoot 'runtime\winsw') -DependencyReusePlan $DependencyReusePlan
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
    [IO.File]::Move($uvFile.FullName,$uvExe,$true)
}
$pythonRoot = Join-Path $ReleaseRoot 'machine-learning\python-runtime'
$deferredPython=$null
$pythonInputs=@{}
# The controlled updater transfers only the exact unchanged package set. Changed
# requirements use uv's existing cache in an independent environment.
if ($null -ne $DependencyReusePlan -and -not (Test-Path -LiteralPath $pythonRoot) -and $reuseSource -and
    (Test-ImmichPythonDependencyReusable -PreviousRelease $reuseSource -CandidateRelease $ReleaseRoot -Inputs $pythonInputs)) {
    $deferredPython=Get-ImmichPythonExecutable -ReleaseRoot $reuseSource
    $relative='machine-learning/python-runtime/'+$deferredPython.Directory.Name
    Add-ImmichDependencyReuse -Plan $DependencyReusePlan -PreviousRelease $reuseSource -CandidateRelease $ReleaseRoot -RelativePath $relative -Label 'Python runtime and packages'
    $DependencyReusePlan[$DependencyReusePlan.Count-1] | Add-Member -NotePropertyName requirementsSha256 -NotePropertyValue $pythonInputs.requirementsSha256
}
$pythonExe = if ($deferredPython) { $deferredPython } else { Get-ImmichPythonExecutable -ReleaseRoot $ReleaseRoot -AllowMissing }
if (-not $pythonExe) {
    $env:UV_CACHE_DIR = Join-Path $InstallRoot 'cache\uv'
    $env:UV_PYTHON_INSTALL_DIR = $pythonRoot
    $pythonInstallProgress=Start-ImmichProgress -Key ml -Detail 'Python runtime'
    & $uvExe python install $versions.python.version --no-bin
    if ($LASTEXITCODE -ne 0) { Update-ImmichProgress -State $pythonInstallProgress -Failed; throw 'Could not install pinned CPython runtime with uv.' }
    Update-ImmichProgress -State $pythonInstallProgress -Finished
    $pythonExe = Get-ImmichPythonExecutable -ReleaseRoot $ReleaseRoot
}
if (-not $pythonExe) { throw 'Pinned CPython installation did not produce python.exe.' }
$pythonVersion = & $pythonExe.FullName -I -c 'import platform; print(platform.python_version())'
if ($LASTEXITCODE -ne 0 -or ([string]$pythonVersion).Trim() -ne $versions.python.version) { throw 'Installed Python version does not match manifest.' }

$nativeZipName = "immich-windows-$packageVersion-native-dependencies.zip"
$inventoryProperty = $manifest.PSObject.Properties['nativeDependencyFiles']
if (-not $inventoryProperty -or -not @($inventoryProperty.Value.PSObject.Properties).Count) { throw 'Native dependency file inventory is missing.' }
# Decide the server tree before native staging so unchanged Sharp is never copied
# out of the old modules only to be copied into the new modules again.
$serverDeferred=$false
$nodeInputs=@{}
if ($null -ne $DependencyReusePlan -and $reuseSource -and
    -not (Test-Path -LiteralPath (Join-Path $ReleaseRoot 'server/node_modules')) -and
    (Test-ImmichNodeProjectReusable -PreviousRelease $reuseSource -CandidateRelease $ReleaseRoot -Project server -Inputs $nodeInputs)) {
    Add-ImmichDependencyReuse -Plan $DependencyReusePlan -PreviousRelease $reuseSource -CandidateRelease $ReleaseRoot -RelativePath 'server/node_modules' -Label 'server Node packages'
    $DependencyReusePlan[$DependencyReusePlan.Count-1] | Add-Member -NotePropertyName dependencyInputHash -NotePropertyValue $nodeInputs.server
    $serverDeferred=$true
}
$nativeProgress=Start-ImmichProgress -Key native
$nativeChecked=0
$nativeTotal=@($inventoryProperty.Value.PSObject.Properties).Count
$missing = [System.Collections.Generic.List[string]]::new()
$reused = 0
# Only share results across the two read-only checks in this invocation. Later
# installation phases still verify their own inputs; no persistent hash cache.
$checkedNativeHashes=@{}
function Get-CheckedNativeHash([string]$Path) {
    $key=[IO.Path]::GetFullPath($Path)
    if (-not $checkedNativeHashes.ContainsKey($key)) { $checkedNativeHashes[$key]=(Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash }
    return $checkedNativeHashes[$key]
}
# Sharp injection replaces a complete DLL set, so staging must never contain only a changed subset.
$sharpNeedsStage = Test-Path -LiteralPath (Join-Path $ReleaseRoot 'dependencies\sharp\lib')
foreach ($entry in ($inventoryProperty.Value.PSObject.Properties | Where-Object { -not $serverDeferred -and $_.Name.StartsWith('dependencies/sharp/') })) {
    $path = Join-Path $ReleaseRoot $entry.Name.Replace('dependencies/sharp/','server/node_modules/@img/sharp-win32-x64/')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
        (Get-CheckedNativeHash $path) -ine $entry.Value) { $sharpNeedsStage=$true }
}
foreach ($entry in $inventoryProperty.Value.PSObject.Properties) {
    Update-ImmichProgress -State $nativeProgress -Completed $nativeChecked -Total $nativeTotal
    $nativeChecked++
    $relative = [string]$entry.Name
    if ($serverDeferred -and $relative.StartsWith('dependencies/sharp/') -and
        $reuseManifest.nativeDependencyFiles.PSObject.Properties[$relative] -and
        [string]$reuseManifest.nativeDependencyFiles.PSObject.Properties[$relative].Value -ieq [string]$entry.Value -and
        (Test-Path -LiteralPath (Join-Path $reuseSource $relative.Replace('dependencies/sharp/','server/node_modules/@img/sharp-win32-x64/')) -PathType Leaf)) { continue }
    if ($relative -match '(^/|^[A-Za-z]:|(^|/)\.\.(/|$))' -or $relative.Contains('\')) { throw "Invalid native payload path: $relative" }
    $installedRelative = $relative.Replace('dependencies/sharp/','server/node_modules/@img/sharp-win32-x64/')
    $target = Join-Path $ReleaseRoot $relative
    $candidatePaths = @($target,(Join-Path $ReleaseRoot $installedRelative)) | Select-Object -Unique
    $ready = $false
    foreach ($path in $candidatePaths) {
        if ((Test-Path -LiteralPath $path -PathType Leaf) -and (Get-CheckedNativeHash $path) -ieq $entry.Value) { $ready=$true; break }
    }
    if ($ready) {
        if ($sharpNeedsStage -and $relative.StartsWith('dependencies/sharp/') -and $path -ne $target) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            Copy-Item -LiteralPath $path -Destination $target -Force
        }
        continue
    }
    $metadataProperty=$manifest.PSObject.Properties['nativeDependencyMetadata']
    if ($metadataProperty -and $metadataProperty.Value.PSObject.Properties[$relative]) {
        $bytes=[Convert]::FromBase64String([string]$metadataProperty.Value.PSObject.Properties[$relative].Value)
        if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) -ine $entry.Value) { throw "Invalid embedded native metadata: $relative" }
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        [IO.File]::WriteAllBytes($target,$bytes)
        continue
    }
    $source = if ($reuseSource) { Join-Path $reuseSource $installedRelative } else { $null }
    if ($source -and (Test-Path -LiteralPath $source -PathType Leaf) -and
        (Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash -ieq $entry.Value) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $target -Force
        $reused++
    } else { $missing.Add($relative) }
}
Update-ImmichProgress -State $nativeProgress -Completed $nativeChecked -Total $nativeTotal -Finished
if ($reused) { Write-Host "Reused $reused matching native payload files (SHA256 verified)." }
if ($missing.Count) {
    Write-Host ("{0}: {1}" -f (Get-ImmichProgressText downloadNeeded),$missing.Count)
    $missing | Select-Object -First 10 | ForEach-Object { Write-Host "  $_" }
    if ($missing.Count -gt 10) { Write-Host ("  ... +{0}" -f ($missing.Count-10)) }
    $nativeUri = "https://github.com/AkaakuHub/immich-windows/releases/download/$packageVersion/$nativeZipName"
    $nativeZip = Get-CachedArchive $nativeZipName $nativeUri $manifest.nativeDependenciesSha256
    $nativeStage = Join-Path $stageRoot 'native-dependencies'
    if (Test-Path -LiteralPath $nativeStage) { Remove-Item -LiteralPath $nativeStage -Recurse -Force }
    New-Item -ItemType Directory -Path $nativeStage -Force | Out-Null
    $nativeExtractProgress=Start-ImmichProgress -Key extract -Detail $nativeZipName
    Expand-ImmichNativePayload -Archive $nativeZip -Destination $nativeStage -RelativePath $missing.ToArray()
    Update-ImmichProgress -State $nativeExtractProgress -Finished
    foreach ($relative in $missing) {
        $source = Join-Path $nativeStage $relative
        $expected = $inventoryProperty.Value.PSObject.Properties[$relative].Value
        if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or (Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash -ine $expected) { throw "Native payload content mismatch: $relative" }
        $target = Join-Path $ReleaseRoot $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        # Only the verified disposable extraction is consumed; the archive stays cached.
        [IO.File]::Move($source,$target,$true)
    }
}

$cleanupProgress=Start-ImmichProgress -Key cleanup
Get-ChildItem -LiteralPath $stageRoot -Directory | Remove-Item -Recurse -Force
Update-ImmichProgress -State $cleanupProgress -Finished
Write-Host 'Runtime tools and native payloads are installed outside the application ZIP.'
