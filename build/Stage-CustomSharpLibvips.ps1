[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ApplicationRoot,
    [Parameter(Mandatory)][string]$BundleRoot
)
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
Assert-WindowsX64
$ApplicationRoot = (Resolve-Path -LiteralPath $ApplicationRoot).Path
$BundleRoot = (Resolve-Path -LiteralPath $BundleRoot).Path
$root = Get-RepositoryRoot
$versions = Read-JsonFile (Join-Path $root 'dependencies\versions.json')
$expected = $versions.sharpLibvips
$metadataPath = Join-Path $BundleRoot 'immich-windows-libvips.json'
if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) { throw 'Custom Sharp/libvips bundle metadata is missing.' }
$metadata = Read-JsonFile $metadataPath
$fields = @{
    libvips = $expected.version
    sharp = $versions.sharp.version
    sourceCommit = $expected.commit
    target = $expected.target
    variant = $expected.variant
    jpeg = $expected.jpeg
    libvipsRevision = $expected.libvipsRevision
    immichBaseImagesCommit = $expected.immichBaseImagesCommit
    immichLoaderPatch = $expected.immichLoaderPatch
    hevc = $expected.hevc
}
foreach ($field in $fields.Keys) {
    if ([string]$metadata.$field -ne [string]$fields[$field]) { throw "Custom Sharp/libvips bundle does not match the pinned $field." }
}
$bundleLib = Join-Path $BundleRoot 'lib'
if (-not (Test-Path -LiteralPath $bundleLib -PathType Container)) {
    throw "Custom sharp-libvips bundle must mirror @img/sharp-libvips-win32-x64 and contain a lib directory: $bundleLib"
}
$dlls = @(Get-ChildItem -LiteralPath $bundleLib -Filter '*.dll' -File -Recurse)
if (-not $dlls.Count) { throw 'Custom sharp-libvips bundle contains no Windows DLLs.' }
if (-not ($dlls.Name -contains 'libvips-42.dll')) {
    throw 'Custom libvips bundle does not contain libvips-42.dll.'
}
$pnpmRoot = Join-Path $ApplicationRoot 'server\node_modules\.pnpm'
$packages = @(Get-ChildItem -LiteralPath $pnpmRoot -Directory -Filter '@img+sharp-win32-x64@*' -ErrorAction SilentlyContinue | ForEach-Object { Get-Item -LiteralPath (Join-Path $_.FullName 'node_modules\@img\sharp-win32-x64') -ErrorAction SilentlyContinue })
if ($packages.Count -ne 1) { throw "Expected one deployed @img/sharp-win32-x64 package; found $($packages.Count)." }
$package = $packages[0]
$targetLib = Join-Path $package.FullName 'lib'
if (-not (Test-Path -LiteralPath $targetLib -PathType Container)) { throw "Sharp lib directory is missing: $targetLib" }
$cppRuntime = @(Get-ChildItem -LiteralPath $targetLib -Filter 'libvips-cpp-*.dll' -File | Where-Object Name -ne 'libvips-cpp-42.dll')
if ($cppRuntime.Count -ne 1) { throw "Expected one Sharp MSVC libvips C++ runtime in $targetLib; found $($cppRuntime.Count)." }
$sharpAddon = @(Get-ChildItem -LiteralPath $targetLib -Filter 'sharp-win32-x64-*.node' -File)
if ($sharpAddon.Count -ne 1) { throw "Expected one Sharp Windows x64 native addon in $targetLib; found $($sharpAddon.Count)." }
$enterVs = Join-Path $PSScriptRoot 'Enter-VsDevEnvironment.ps1'
& $enterVs -RequireLlvm:$false | Out-Host
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vsInstall = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
$msvcRoot = Join-Path $vsInstall 'VC\Tools\MSVC'
$msvcVersion = Get-ChildItem -LiteralPath $msvcRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1
$msvcTools = Join-Path $msvcVersion.FullName 'bin\Hostx64\x64'
$dumpbin = Join-Path $msvcTools 'dumpbin.exe'
$link = Join-Path $msvcTools 'link.exe'
$cl = Join-Path $msvcTools 'cl.exe'
$lib = Join-Path $msvcTools 'lib.exe'
foreach ($tool in @($dumpbin,$link,$cl,$lib)) { if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw "Visual Studio tool is missing: $tool" } }
function Get-DllExports([string]$Path) {
    $lines = @(& $dumpbin /nologo /exports $Path 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "dumpbin could not read exports from $Path" }
    @($lines | ForEach-Object { if ($_ -match '^\s+\d+\s+[0-9A-F]+\s+[0-9A-F]+\s+(\S+)\s*$') { $Matches[1] } })
}
function Get-LibvipsImports([string]$Path) {
    $lines = @(& $dumpbin /nologo /imports $Path 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "dumpbin could not read imports from $Path" }
    $inLibvips = $false
    foreach ($line in $lines) {
        if ($line -match '^\s+([A-Za-z0-9_.+-]+\.dll)\s*$') {
            $inLibvips = $Matches[1] -ieq 'libvips-42.dll'
            continue
        }
        if ($inLibvips -and $line -match '^\s+\d+\s+([A-Za-z_?@][^\s]*)\s*$') { $Matches[1] }
    }
}
$coreDll = Join-Path $bundleLib 'libvips-42.dll'
$coreExports = @(Get-DllExports $coreDll | Sort-Object -Unique)
$glibExports = @(Get-DllExports (Join-Path $bundleLib 'libglib-2.0-0.dll'))
$gobjectExports = @(Get-DllExports (Join-Path $bundleLib 'libgobject-2.0-0.dll'))
$externalProviders = @{}
foreach ($name in $glibExports) { $externalProviders[$name] = 'libglib-2.0-0.dll' }
foreach ($name in $gobjectExports) { if (-not $externalProviders.ContainsKey($name)) { $externalProviders[$name] = 'libgobject-2.0-0.dll' } }
$importFiles = @($cppRuntime[0].FullName,$sharpAddon[0].FullName) + @((Get-ChildItem -LiteralPath $targetLib -Filter '*.dll' -File -Recurse | ForEach-Object FullName)) + @($dlls | ForEach-Object FullName)
$libvipsImports = @($importFiles | ForEach-Object { Get-LibvipsImports $_ } | Sort-Object -Unique)
$missingExports = @($libvipsImports | Where-Object { $_ -notin $coreExports })
$unmappedExports = @($missingExports | Where-Object { -not $externalProviders.ContainsKey($_) })
if ($unmappedExports.Count) { throw "Custom libvips proxy cannot forward imports: $($unmappedExports -join ', ')" }
$forwarderRoot = Join-Path (Get-RepositoryRoot) '.work\sharp-libvips-forwarder'
if (Test-Path -LiteralPath $forwarderRoot) { Remove-Item -LiteralPath $forwarderRoot -Recurse -Force }
New-Item -ItemType Directory -Path $forwarderRoot -Force | Out-Null
$proxyLines = [System.Collections.Generic.List[string]]::new()
$proxyLines.Add('LIBRARY libvips-42.dll')
$proxyLines.Add('EXPORTS')
foreach ($name in $coreExports) { $proxyLines.Add("  $name=libvips-core.dll.$name") }
foreach ($name in $missingExports) { $proxyLines.Add("  $name=$($externalProviders[$name]).$name") }
$proxyDef = Join-Path $forwarderRoot 'libvips-42.def'
[System.IO.File]::WriteAllLines($proxyDef,$proxyLines,[System.Text.Encoding]::ASCII)
$importLibraries = [System.Collections.Generic.List[string]]::new()
$importDefs = @(
    @{ Module='libvips-core.dll'; Names=$coreExports },
    @{ Module='libglib-2.0-0.dll'; Names=@($missingExports | Where-Object { $externalProviders[$_] -eq 'libglib-2.0-0.dll' }) },
    @{ Module='libgobject-2.0-0.dll'; Names=@($missingExports | Where-Object { $externalProviders[$_] -eq 'libgobject-2.0-0.dll' }) }
)
foreach ($item in $importDefs) {
    if (-not $item.Names.Count) { continue }
    $stem = [IO.Path]::GetFileNameWithoutExtension($item.Module)
    $defPath = Join-Path $forwarderRoot "$stem-import.def"
    $libPath = Join-Path $forwarderRoot "$stem-import.lib"
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("LIBRARY $($item.Module)")
    $lines.Add('EXPORTS')
    foreach ($name in $item.Names) { $lines.Add("  $name") }
    [System.IO.File]::WriteAllLines($defPath,$lines,[System.Text.Encoding]::ASCII)
    & $lib /nologo "/def:$defPath" "/out:$libPath" /machine:x64
    if ($LASTEXITCODE -ne 0) { throw "MSVC could not create the $($item.Module) import library." }
    $importLibraries.Add($libPath)
}
$emptySource = Join-Path $forwarderRoot 'empty.c'
$emptyObject = Join-Path $forwarderRoot 'empty.obj'
Set-Content -LiteralPath $emptySource -Encoding ascii -Value 'int immich_vips_forwarder_anchor(void) { return 0; }'
& $cl /nologo /c /TC "/Fo$emptyObject" $emptySource
if ($LASTEXITCODE -ne 0) { throw 'MSVC could not compile the libvips forwarder anchor.' }
$proxyDll = Join-Path $forwarderRoot 'libvips-42.dll'
& $link /nologo /dll /noentry /machine:x64 "/def:$proxyDef" "/out:$proxyDll" $emptyObject @($importLibraries)
if ($LASTEXITCODE -ne 0) { throw 'MSVC could not link the libvips Windows ABI forwarder.' }
foreach ($package in $packages) {
    $targetLib = Join-Path $package.FullName 'lib'
    Get-ChildItem -LiteralPath $targetLib -Filter '*.dll' -File -Recurse | Where-Object FullName -ne $cppRuntime[0].FullName | Remove-Item -Force
    Copy-Directory $bundleLib $targetLib
    Move-Item -LiteralPath (Join-Path $targetLib 'libvips-42.dll') -Destination (Join-Path $targetLib 'libvips-core.dll') -Force
    Copy-Item -LiteralPath $proxyDll -Destination (Join-Path $targetLib 'libvips-42.dll') -Force
    Remove-Item -LiteralPath (Join-Path $targetLib 'libvips-cpp-42.dll') -Force -ErrorAction SilentlyContinue
    foreach ($name in @('versions.json')) {
        $sourceFile = Join-Path $BundleRoot $name
        if (Test-Path -LiteralPath $sourceFile) { Copy-Item -LiteralPath $sourceFile -Destination (Join-Path $package.FullName $name) -Force }
    }
    Write-Host "Injected custom libvips bundle into $($package.FullName)"
}
$marker = [ordered]@{
    injectedAtUtc = [DateTime]::UtcNow.ToString('o')
    source = $BundleRoot
    dllCount = $dlls.Count
}
$marker | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 -LiteralPath (Join-Path $ApplicationRoot 'sharp-libvips-injection.json')
$noticeRoot = Join-Path $ApplicationRoot 'media-stack\sharp-libvips'
New-Item -ItemType Directory -Path $noticeRoot -Force | Out-Null
foreach ($name in @('immich-windows-libvips.json','LICENSE','README.md','ChangeLog')) {
    $candidate = Join-Path $BundleRoot $name
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { Copy-Item -LiteralPath $candidate -Destination (Join-Path $noticeRoot $name) -Force }
}
