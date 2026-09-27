[CmdletBinding()]
param([string]$ToolRoot)
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
Assert-WindowsX64
$root = Get-RepositoryRoot
$versions = Read-JsonFile (Join-Path $root 'dependencies\versions.json')
if (-not $ToolRoot) { $ToolRoot = Join-Path $root '.tools' }
New-Item -ItemType Directory -Path $ToolRoot -Force | Out-Null

# Use the exact Node release pinned by upstream Immich. The same runtime is later
# copied into the installable package, so the build and production Node versions
# cannot drift independently.
$nodeRoot = Join-Path $ToolRoot 'node'
$nodeExe = Join-Path $nodeRoot 'node.exe'
$nodeVersion = if (Test-Path -LiteralPath $nodeExe -PathType Leaf) { (& $nodeExe --version).Trim().TrimStart('v') } else { '' }
if ($nodeVersion -ne $versions.node.version) {
    & (Join-Path $PSScriptRoot 'Fetch-NodeRuntime.ps1') -Destination $nodeRoot
}
$node = Assert-FileExists $nodeExe
$nodeVersion = (& $node --version).Trim().TrimStart('v')
if ($nodeVersion -ne $versions.node.version) { throw "Unexpected bootstrapped Node version: $nodeVersion" }
$env:PATH = "$nodeRoot;$env:PATH"

$corepack = Join-Path $nodeRoot 'corepack.cmd'
if (-not (Test-Path -LiteralPath $corepack)) { throw "Node archive did not include corepack.cmd: $corepack" }
$existingPnpm=Get-Command pnpm -ErrorAction SilentlyContinue
$existingPnpmVersion=if($existingPnpm){(& $existingPnpm.Source --version).Trim()}else{''}
if($existingPnpmVersion -ne $versions.pnpm.version){
    Invoke-Native $corepack @('enable','--install-directory',$nodeRoot)
    Invoke-Native $corepack @('prepare',"pnpm@$($versions.pnpm.version)",'--activate')
}
$pnpm = Assert-Command 'pnpm'
$pnpmVersion = (& $pnpm --version).Trim()
if ($pnpmVersion -ne $versions.pnpm.version) { throw "Unexpected bootstrapped pnpm version: $pnpmVersion" }

# Machine-learning uses the pinned uv release so it can install CPython 3.11.14.
$uvRoot = Join-Path $ToolRoot 'uv'
$uvExe = Join-Path $uvRoot 'uv.exe'
$uvVersion = if (Test-Path -LiteralPath $uvExe) { (& $uvExe --version).Trim() } else { '' }
if ($uvVersion -notmatch "^uv $([regex]::Escape($versions.uv.version))(\s|$)") {
    $asset = $versions.uv.asset
    $archive = Join-Path $root ".cache\uv-$($versions.uv.version)-$asset"
    $url = "https://github.com/astral-sh/uv/releases/download/$($versions.uv.version)/$asset"
    Get-CachedDownload -Uri $url -Destination $archive | Out-Null
    $temp = Expand-ZipClean $archive (Join-Path $root '.work\uv')
    $candidate = Get-ChildItem -LiteralPath $temp -Filter uv.exe -File -Recurse | Select-Object -First 1
    if (-not $candidate) { throw 'uv Windows archive did not contain uv.exe.' }
    $uvRoot = New-CleanDirectory $uvRoot
    Copy-Directory $candidate.Directory.FullName $uvRoot
}
Assert-FileExists $uvExe | Out-Null
$env:PATH = "$uvRoot;$env:PATH"
$uvVersion = (& $uvExe --version).Trim()
if ($uvVersion -notmatch "^uv $([regex]::Escape($versions.uv.version))(\s|$)") { throw "Unexpected uv version: $uvVersion" }

# Immich's plugin-core build invokes extism-js. extism-js publishes a native
# Windows executable compressed as a single gzip file.
$extismRoot = Join-Path $ToolRoot 'extism-js'
$extismExe = Join-Path $extismRoot 'extism-js.exe'
$extismMarker = Join-Path $extismRoot 'source-version.txt'
$extismVersion = if (Test-Path -LiteralPath $extismMarker -PathType Leaf) { (Get-Content -Raw -LiteralPath $extismMarker).Trim() } else { '' }
if (-not (Test-Path -LiteralPath $extismExe -PathType Leaf) -or $extismVersion -ne $versions.extismJs.version) {
    New-Item -ItemType Directory -Path $extismRoot -Force | Out-Null
    $asset = $versions.extismJs.asset
    $archive = Join-Path $root ".cache\$asset"
    $url = "https://github.com/extism/js-pdk/releases/download/v$($versions.extismJs.version)/$asset"
    Get-CachedDownload -Uri $url -Destination $archive | Out-Null
    $input = [IO.File]::OpenRead($archive)
    try {
        $gzip = [IO.Compression.GZipStream]::new($input, [IO.Compression.CompressionMode]::Decompress)
        try {
            $output = [IO.File]::Create($extismExe)
            try { $gzip.CopyTo($output) } finally { $output.Dispose() }
        } finally { $gzip.Dispose() }
    } finally { $input.Dispose() }
    $versions.extismJs.version | Set-Content -Encoding ascii -LiteralPath $extismMarker
}
Assert-FileExists $extismExe | Out-Null
$env:PATH = "$extismRoot;$env:PATH"

# Binaryen provides wasm-opt/wasm-merge, both used by plugin-core's release
# build. Its Windows release is a tar.gz, which Windows 10/11's bsdtar can read.
$binaryenRoot = Join-Path $ToolRoot 'binaryen'
$wasmOpt = Join-Path $binaryenRoot 'bin\wasm-opt.exe'
$binaryenVersion = if (Test-Path -LiteralPath $wasmOpt) { (& $wasmOpt --version).Trim() } else { '' }
if ($binaryenVersion -notmatch "\bversion_$([regex]::Escape($versions.binaryen.version))\b") {
    $asset = $versions.binaryen.asset
    $archive = Join-Path $root ".cache\$asset"
    $url = "https://github.com/WebAssembly/binaryen/releases/download/version_$($versions.binaryen.version)/$asset"
    Get-CachedDownload -Uri $url -Destination $archive | Out-Null
    $temp = New-CleanDirectory (Join-Path $root '.work\binaryen')
    $tar = Assert-Command 'tar.exe'
    Invoke-Native $tar @('-xzf',$archive,'-C',$temp)
    $inner = Get-ChildItem -LiteralPath $temp -Directory | Select-Object -First 1
    if (-not $inner) { throw 'Unexpected Binaryen archive layout.' }
    $binaryenRoot = New-CleanDirectory $binaryenRoot
    Copy-Directory $inner.FullName $binaryenRoot
}
Assert-FileExists (Join-Path $binaryenRoot 'bin\wasm-opt.exe') | Out-Null
Assert-FileExists (Join-Path $binaryenRoot 'bin\wasm-merge.exe') | Out-Null
$env:PATH = "$(Join-Path $binaryenRoot 'bin');$env:PATH"

foreach ($name in @('node','pnpm','uv','extism-js','wasm-opt','wasm-merge')) { Assert-Command $name | Out-Null }
Write-Host "Pinned build tools are ready in $ToolRoot"
Write-Output $ToolRoot
