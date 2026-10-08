#requires -Version 7.0
[CmdletBinding()]
param([string]$LegacyGlibDll)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Import-Module (Join-Path $repo 'build/NativeMediaValidation.psm1') -Force
function Check([bool]$Value,[string]$Message){if(-not $Value){throw $Message}}
function Reject([scriptblock]$Action,[string]$Message){$failed=$false;try{& $Action}catch{$failed=$true};Check $failed $Message}
function Write-File([string]$Path,[string]$Text){[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path));[IO.File]::WriteAllText($Path,$Text)}
function Set-U16([byte[]]$Bytes,[int]$At,[uint16]$Value){[BitConverter]::GetBytes($Value).CopyTo($Bytes,$At)}
function Set-U32([byte[]]$Bytes,[int]$At,[uint32]$Value){[BitConverter]::GetBytes($Value).CopyTo($Bytes,$At)}
function Set-U64([byte[]]$Bytes,[int]$At,[uint64]$Value){[BitConverter]::GetBytes($Value).CopyTo($Bytes,$At)}
$base=Join-Path ([IO.Path]::GetTempPath()) ('native-media-tests-'+[guid]::NewGuid().ToString('N'))
try{
    [void][IO.Directory]::CreateDirectory($base)
    # A minimal file-backed PE32+ TLS directory with one nonzero callback.
    $good=[byte[]]::new(0x600)
    Set-U16 $good 0 0x5a4d;Set-U32 $good 0x3c 0x80;Set-U32 $good 0x80 0x4550
    Set-U16 $good 0x84 0x8664;Set-U16 $good 0x86 1;Set-U16 $good 0x94 240
    Set-U16 $good 0x98 0x20b;Set-U64 $good (0x98+24) 0x180000000;Set-U32 $good (0x98+108) 16
    Set-U32 $good (0x98+184) 0x1000;Set-U32 $good (0x98+188) 40
    Set-U32 $good (0x188+8) 0x400;Set-U32 $good (0x188+12) 0x1000
    Set-U32 $good (0x188+16) 0x400;Set-U32 $good (0x188+20) 0x200
    Set-U64 $good (0x200+24) 0x180001040;Set-U64 $good 0x240 0x180001080
    $dll=Join-Path $base 'glib.dll'
    [IO.File]::WriteAllBytes($dll,$good)
    Assert-WindowsPeTlsDirectory $dll
    $cases=@(
        @{Name='missing TLS directory';At=(0x98+184);Value=0;Size=32},
        @{Name='truncated TLS structure';At=(0x98+188);Value=20;Size=32},
        @{Name='unmapped TLS directory';At=(0x98+184);Value=0x7fffffff;Size=32},
        @{Name='absent callback array';At=(0x200+24);Value=0;Size=64},
        @{Name='unmapped callback array';At=(0x200+24);Value=0x180003000;Size=64},
        @{Name='empty callback array';At=0x240;Value=0;Size=64},
        @{Name='wrong architecture';At=0x84;Value=0xaa64;Size=16},
        @{Name='overflowing PE offset';At=0x3c;Value=0xffffffffL;Size=32}
    )
    foreach($case in $cases){
        $bad=[byte[]]$good.Clone()
        switch($case.Size){16{Set-U16 $bad $case.At $case.Value};32{Set-U32 $bad $case.At $case.Value};64{Set-U64 $bad $case.At $case.Value}}
        [IO.File]::WriteAllBytes($dll,$bad)
        Reject {Assert-WindowsPeTlsDirectory $dll} "Accepted $($case.Name)."
    }
    [IO.File]::WriteAllBytes($dll,[byte[]](1,2,3))
    Reject {Assert-WindowsPeTlsDirectory $dll} 'Accepted a truncated file.'
    [IO.File]::WriteAllBytes($dll,$good)

    $root=Join-Path $base 'repo'
    Write-File (Join-Path $root 'dependencies/versions.json') '{"sharpLibvips":{"version":"8.18.5","target":"x64"},"sharp":{"version":"0.35.3"},"postgresql":{"version":"18.6"}}'
    foreach($file in @('build/Build-CustomSharpLibvips.ps1','build/Common.psm1','build/NativeMediaValidation.psm1')){Write-File (Join-Path $root $file) "fixture $file"}
    $patch=Join-Path $root 'media-patches/libvips/0006-tls.patch'
    Write-File $patch 'upstream TLS anchor'
    $first=Get-NativeMediaBuildIdentity $root
    (Get-Item -LiteralPath $patch).LastWriteTimeUtc=[datetime]'2000-01-01Z'
    $retimed=Get-NativeMediaBuildIdentity $root
    Check ($first.nativeBuildInputsSha256 -ceq $retimed.nativeBuildInputsSha256) 'Identity depends on file timestamps.'
    Write-File $patch 'different patch bytes'
    (Get-Item -LiteralPath $patch).LastWriteTimeUtc=[datetime]'2000-01-01Z'
    $changed=Get-NativeMediaBuildIdentity $root
    Check ($first.mediaPatchesSha256 -cne $changed.mediaPatchesSha256 -and $first.nativeBuildInputsSha256 -cne $changed.nativeBuildInputsSha256) 'Changed patch reused native cache.'
    Write-File $patch 'upstream TLS anchor'
    Write-File (Join-Path $root 'build/Build-CustomSharpLibvips.ps1') 'changed builder'
    $builderChanged=Get-NativeMediaBuildIdentity $root
    Check ($first.mediaPatchesSha256 -ceq $builderChanged.mediaPatchesSha256 -and $first.nativeBuildInputsSha256 -cne $builderChanged.nativeBuildInputsSha256) 'Changed builder reused native cache.'
    Write-File (Join-Path $root 'dependencies/versions.json') '{"sharpLibvips":{"version":"8.18.5","target":"x64"},"sharp":{"version":"0.35.3"},"postgresql":{"version":"different"}}'
    Check ($builderChanged.nativeBuildInputsSha256 -ceq (Get-NativeMediaBuildIdentity $root).nativeBuildInputsSha256) 'Unrelated PostgreSQL version invalidated the codec cache.'

    $dependencyPath=Join-Path $root 'dependencies/versions.json'
    $pins=Get-Content -Raw $dependencyPath|ConvertFrom-Json -AsHashtable
    $pins.sharp.source='https://github.com/immich-app/immich/blob/newcommit/server/package.json'
    $pins.sharpLibvips.notes='Updated descriptive notes'
    $pins.sharpLibvips.immichBaseImagesCommit='new provenance only'
    Write-File $dependencyPath ($pins|ConvertTo-Json -Depth 10)
    Check ($builderChanged.nativeBuildInputsSha256 -ceq (Get-NativeMediaBuildIdentity $root).nativeBuildInputsSha256) 'Provenance-only metadata invalidated the codec cache.'
    $pins.sharpLibvips.libheif=@{version='1.23.3';sha256=('1' * 64);recipeSha256=('2' * 64);revision=('3' * 40);source='description'}
    Write-File $dependencyPath ($pins|ConvertTo-Json -Depth 10)
    $heifIdentity=Get-NativeMediaBuildIdentity $root
    Check ($builderChanged.nativeBuildInputsSha256 -cne $heifIdentity.nativeBuildInputsSha256) 'libheif source pin did not invalidate codec cache.'
    $pins.sharpLibvips.libheif.source='another description'
    Write-File $dependencyPath ($pins|ConvertTo-Json -Depth 10)
    Check ($heifIdentity.nativeBuildInputsSha256 -ceq (Get-NativeMediaBuildIdentity $root).nativeBuildInputsSha256) 'libheif provenance URL invalidated codec cache.'
    [void]$pins.sharpLibvips.Remove('libheif')
    Write-File $dependencyPath ($pins|ConvertTo-Json -Depth 10)
    $keyOutput=Join-Path $base 'cache-keys'
    & (Join-Path $repo 'build/Write-NativeBuildCacheKeys.ps1') -OutputPath $keyOutput
    Check ((Get-Content $keyOutput | Where-Object {$_ -like 'codec=*'}) -ceq ('codec=' + (Get-NativeMediaBuildIdentity $repo).nativeBuildInputsSha256)) 'Codec cache key and artifact identity disagree.'

    $bundle=Join-Path $base 'bundle';[void][IO.Directory]::CreateDirectory((Join-Path $bundle 'lib'))
    Copy-Item -LiteralPath $dll -Destination (Join-Path $bundle 'lib/libglib-2.0-0.dll')
    $metadata=Join-Path $bundle 'immich-windows-libvips.json'
    Write-File $metadata ($builderChanged|ConvertTo-Json)
    Assert-NativeMediaBundleIdentity $bundle $root
    Write-File $metadata '{}'
    Reject {Assert-NativeMediaBundleIdentity $bundle $root} 'Accepted a legacy bundle without input proof.'
    Write-File $metadata ($first|ConvertTo-Json)
    Reject {Assert-NativeMediaBundleIdentity $bundle $root} 'Accepted stale native input proof.'
    Write-File $metadata ($builderChanged|ConvertTo-Json)
    $bad=[byte[]]$good.Clone();Set-U32 $bad (0x98+184) 0
    [IO.File]::WriteAllBytes((Join-Path $bundle 'lib/libglib-2.0-0.dll'),$bad)
    Reject {Assert-NativeMediaBundleIdentity $bundle $root} 'Accepted missing TLS with otherwise matching metadata.'

    $builder=Get-Content -Raw -LiteralPath (Join-Path $repo 'build/Build-CustomSharpLibvips.ps1')
    # Exercise the narrow, checksum-bound libheif recipe change without a native build.
    $tokens=$null;$parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($builder,[ref]$tokens,[ref]$parseErrors)
    $recipeFunction=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Update-PinnedLibheifRecipe'},$true)
    Invoke-Expression $recipeFunction.Extent.Text
    $recipePath=Join-Path $base 'libheif.mk'
    $recipe='$(PKG)_VERSION := 1.23.1' + "`n" + '$(PKG)_CHECKSUM := ' + ('0' * 64) + "`n" + '-DENABLE_PLUGIN_LOADING=0 -DWITH_LIBDE265=0 -DWITH_X265=0' + "`n"
    Write-File $recipePath $recipe
    $pin=[pscustomobject]@{version='1.23.3';revision=('1' * 40);sha256=('2' * 64);recipeVersion='1.23.1';recipeSha256=(Get-FileHash -Algorithm SHA256 $recipePath).Hash.ToLowerInvariant()}
    Update-PinnedLibheifRecipe -Path $recipePath -Pin $pin
    $expectedRecipe=$recipe.Replace('$(PKG)_VERSION := 1.23.1','$(PKG)_VERSION  := 1.23.3').Replace(('$(PKG)_CHECKSUM := ' + ('0' * 64)),('$(PKG)_CHECKSUM := ' + ('2' * 64)))
    Check ((Get-Content -Raw $recipePath) -ceq $expectedRecipe) 'libheif recipe changed more than pinned version/checksum.'
    Reject {Update-PinnedLibheifRecipe -Path $recipePath -Pin $pin} 'Changed MXE recipe accepted a blind replacement.'
    $pin.version='1.23.3; injected'
    Reject {Update-PinnedLibheifRecipe -Path $recipePath -Pin $pin} 'Invalid libheif version accepted.'

    $stageSource=Get-Content -Raw (Join-Path $repo 'build/Stage-CustomSharpLibvips.ps1')
    $cacheStart=$stageSource.IndexOf('$forwarderCache=')
    $cacheEnd=$stageSource.IndexOf('foreach ($package in $packages)', $cacheStart)
    Check ($cacheStart -ge 0 -and $cacheEnd -gt $cacheStart) 'Missing forwarder cache stage.'
    $stageScriptPath=Join-Path $repo 'build/Stage-CustomSharpLibvips.ps1'
    $cacheCode=$stageSource.Substring($cacheStart,$cacheEnd-$cacheStart).Replace('$PSCommandPath','$stageScriptPath')
    & {
        $root=Join-Path $base 'forwarder-test'
        $bundleLib=Join-Path $root 'bundle/lib'
        foreach ($name in @('libvips-42.dll','libglib-2.0-0.dll','libgobject-2.0-0.dll')) { Write-File (Join-Path $bundleLib $name) "native $name" }
        $dlls=@(Get-ChildItem $bundleLib -File)
        $cppPath=Join-Path $root 'binding/cpp.dll';$addonPath=Join-Path $root 'binding/sharp.node'
        Write-File $cppPath cpp;Write-File $addonPath addon
        $cppRuntime=@(Get-Item $cppPath);$sharpAddon=@(Get-Item $addonPath)
        $cl=Join-Path $root 'tools/cl.exe';$lib=Join-Path $root 'tools/lib.exe';$link=Join-Path $root 'tools/link.exe'
        foreach ($tool in @($cl,$lib,$link)) { Write-File $tool 'fixture tool' }
        $state=@{Calls=0}
        $compileStub={
            $state.Calls++
            foreach ($arg in @($args | ForEach-Object { $_ })) {
                if ([string]$arg -match '^/(?:out:|Fo)(.+)$') {
                    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Matches[1]))
                    [IO.File]::WriteAllText($Matches[1],('generated '+$state.Calls))
                }
            }
            $global:LASTEXITCODE=0
        }.GetNewClosure()
        function Get-RepositoryRoot { $root }
        function Read-JsonFile([string]$Path) { Get-Content -Raw $Path | ConvertFrom-Json }
        function Get-DllExports { @('vips_fixture') }
        function Get-LibvipsImports { @('vips_fixture') }
        foreach ($tool in @($cl,$lib,$link)) { Set-Item "function:global:$tool" $compileStub }
        try {
            Invoke-Expression $cacheCode
            $firstHash=(Get-FileHash $proxyDll).Hash
            $firstCalls=$state.Calls
            Check ($firstCalls -gt 0) 'First forwarder did not build.'
            Invoke-Expression $cacheCode
            Check ($state.Calls -eq $firstCalls -and (Get-FileHash $proxyDll).Hash -ceq $firstHash) 'Unchanged forwarder was rebuilt.'
            (Get-Item $addonPath).LastWriteTimeUtc=[datetime]'2000-01-01Z'
            Invoke-Expression $cacheCode
            Check ($state.Calls -eq $firstCalls) 'File timestamps rebuilt the forwarder.'
            Write-File $addonPath 'changed addon bytes'
            Invoke-Expression $cacheCode
            Check ($state.Calls -gt $firstCalls) 'Changed addon reused the old forwarder.'
            $afterChange=$state.Calls
            Write-File $proxyDll 'corrupted cache DLL'
            Invoke-Expression $cacheCode
            Check ($state.Calls -gt $afterChange) 'Corrupted forwarder cache was reused.'
        } finally { foreach ($tool in @($cl,$lib,$link)) { Remove-Item "function:global:$tool" } }
    }
    Check ($builder.Contains('$targetCacheId="immich-mxe-$($v.target)-$($nativeIdentity.nativeBuildInputsSha256)"')) 'BuildKit installed-library cache lacks the content digest.'
    Check ($builder.Contains('Assert-WindowsPeTlsDirectory -Path')) 'Native output is not checked for a TLS directory.'
    foreach($file in @('build/Stage-CustomSharpLibvips.ps1','build/Build-Release.ps1','build/Build-All.ps1')){
        Check ((Get-Content -Raw -LiteralPath (Join-Path $repo $file)).Contains('Assert-NativeMediaBundleIdentity')) "Explicit or cached bundle identity bypass in $file."
    }
    if($LegacyGlibDll){Reject {Assert-WindowsPeTlsDirectory $LegacyGlibDll} 'Accepted the known-bad released GLib DLL.'}
    Write-Host 'PASS native media build: PE TLS directory/callback bounds, content-addressed cache, stale bundle rejection, upstream patch wiring.'
}finally{if(Test-Path -LiteralPath $base){Remove-Item -LiteralPath $base -Recurse -Force}}
