#requires -Version 7.0
[CmdletBinding()]
param([string]$Destination)


function Update-PinnedLibheifRecipe {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object]$Pin)
    if ($Pin.version -notmatch '^\d+\.\d+\.\d+$' -or $Pin.sha256 -notmatch '^[0-9a-f]{64}$' -or
        $Pin.recipeSha256 -notmatch '^[0-9a-f]{64}$' -or $Pin.revision -notmatch '^[0-9a-f]{40}$') {
        throw 'Invalid immutable libheif source pin.'
    }
    $text = (Get-Content -Raw -LiteralPath $Path).Replace("`r`n","`n")
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text))).ToLowerInvariant()
    if ($hash -cne $Pin.recipeSha256) { throw 'The pinned MXE libheif recipe changed; refusing a blind version replacement.' }
    $versionPattern = '(?m)^\$\(PKG\)_VERSION\s*:=\s*' + [regex]::Escape($Pin.recipeVersion) + '\r?$'
    $checksumPattern = '(?m)^\$\(PKG\)_CHECKSUM\s*:=\s*[0-9a-f]{64}\r?$'
    if ([regex]::Matches($text,$versionPattern).Count -ne 1 -or [regex]::Matches($text,$checksumPattern).Count -ne 1) {
        throw 'The pinned MXE libheif recipe no longer has unique version/checksum fields.'
    }
    $text = [regex]::Replace($text,$versionPattern,('$(PKG)_VERSION  := ' + $Pin.version))
    $text = [regex]::Replace($text,$checksumPattern,('$(PKG)_CHECKSUM := ' + $Pin.sha256))
    [IO.File]::WriteAllText($Path,$text,[Text.UTF8Encoding]::new($false))
}

Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'NativeMediaValidation.psm1') -Force
if(-not [Environment]::Is64BitOperatingSystem -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64'){
    throw 'The libvips cross-build requires an x64 host.'
}
$root=Get-RepositoryRoot
$v=(Read-JsonFile (Join-Path $root 'dependencies/versions.json')).sharpLibvips
$nativeIdentity=Get-NativeMediaBuildIdentity -RepositoryRoot $root
if(-not $Destination){$Destination=Join-Path $root 'artifacts/native/sharp-libvips-custom'}

$git=Assert-Command git
$bash=if($IsWindows){
    $gitRoot=Split-Path (Split-Path $git -Parent) -Parent
    Assert-FileExists (Join-Path $gitRoot 'bin/bash.exe')
}else{Assert-Command bash}
$runtimeName=if(Get-Command podman -ErrorAction SilentlyContinue){'podman'}else{'docker'}
$runtime=Assert-Command $runtimeName
& $runtime info *> $null
if($LASTEXITCODE -ne 0){throw "$runtimeName is not reachable on the build host."}
if($IsWindows -and $runtimeName -eq 'docker'){
    $containerOs=(& $runtime info --format '{{.OSType}}').Trim()
    if($containerOs -ne 'linux'){throw "libvips/build-win64-mxe requires Linux-container mode. Docker reports OSType=$containerOs"}
}

$source=Join-Path $root '.work/build-win64-mxe'
if(Test-Path $source){Remove-Item $source -Recurse -Force}
Invoke-Native $git @('clone','--depth','1','--branch',$v.tag,$v.repository,$source)
$actual=(& $git -C $source rev-parse HEAD).Trim()
if($actual -ne $v.commit){throw "build-win64-mxe commit mismatch. Expected $($v.commit), got $actual"}

# Update only the audited libheif source/checksum in the immutable Windows recipe.
# Its HEVC and platform configuration remain unchanged.
Update-PinnedLibheifRecipe -Path (Join-Path $source 'build/libheif.mk') -Pin $v.libheif

$dockerfile=Join-Path $source 'container/Dockerfile'
$dockerfileText=Get-Content -Raw -LiteralPath $dockerfile
$downloadMount='RUN --mount=type=cache,id=mxe-download,target=/usr/local/mxe/pkg \'
$downloadMountCount=[regex]::Matches($dockerfileText,[regex]::Escape($downloadMount)).Count
if($downloadMountCount -ne 1){throw "Expected one MXE download cache mount in Dockerfile; found $downloadMountCount."}
# Package stamps in this mount can otherwise reuse GLib after its source patch changes.
$targetCacheId="immich-mxe-$($v.target)-$($nativeIdentity.nativeBuildInputsSha256)"
$targetMount="RUN --mount=type=cache,id=mxe-download,target=/usr/local/mxe/pkg \`n  --mount=type=cache,id=$targetCacheId,target=/usr/local/mxe/usr/$($v.target),sharing=locked \"
$dockerfileText=$dockerfileText.Replace($downloadMount,$targetMount)
$makeLine='    GIT_COMMIT=$GIT_COMMIT'
if([regex]::Matches($dockerfileText,[regex]::Escape($makeLine)).Count -ne 1){throw 'Expected one MXE make invocation in Dockerfile.'}
$packageArgs="ARG FFI_COMPAT`nARG JPEG_IMPL`nARG HEVC`nARG ZLIB_NG"
$packageStep="`nCOPY --from=packaging . /data/packaging`n`n$packageArgs`nRUN --mount=type=cache,id=$targetCacheId,target=/usr/local/mxe/usr/$($v.target),sharing=locked \`n  cd /data/packaging && \`n  PKGS=`"`$PKGS`" MXE_TARGETS=`"`$MXE_TARGETS`" FFI_COMPAT=`"`$FFI_COMPAT`" JPEG_IMPL=`"`$JPEG_IMPL`" HEVC=`"`$HEVC`" DEBUG=`"`$DEBUG`" ZLIB_NG=`"`$ZLIB_NG`" /bin/bash package.sh`n"
$dockerfileText=$dockerfileText.Replace("$makeLine`n", "$makeLine`n$packageStep")
Write-Utf8NoBom -Path $dockerfile -Content $dockerfileText
$buildScript=Join-Path $source 'build.sh'
$buildScriptText=Get-Content -Raw -LiteralPath $buildScript
$packagingMount='  -v $PWD/packaging:/data/packaging \'
if([regex]::Matches($buildScriptText,[regex]::Escape($packagingMount)).Count -ne 1){throw 'Expected one packaging bind mount in build.sh.'}
$buildScriptText=$buildScriptText.Replace($packagingMount,'  -v "$IMMICH_PACKAGING_PATH:/data/packaging" \')
$buildContextMarker='  --build-arg GIT_COMMIT="$git_commit" \'
if([regex]::Matches($buildScriptText,[regex]::Escape($buildContextMarker)).Count -ne 1){throw 'Expected one Docker GIT_COMMIT build argument.'}
$buildContextLine='  --build-context packaging="$IMMICH_PACKAGING_PATH" \'
$buildScriptText=$buildScriptText.Replace($buildContextMarker,"$buildContextLine`n$buildContextMarker")
$buildArgsMarker='  --build-arg GIT_COMMIT="$git_commit" \'
if([regex]::Matches($buildScriptText,[regex]::Escape($buildArgsMarker)).Count -ne 1){throw 'Expected one Docker GIT_COMMIT build argument.'}
$buildArgs=@'
  --build-arg GIT_COMMIT="$git_commit" \
  --build-arg FFI_COMPAT="$with_ffi_compat" \
  --build-arg JPEG_IMPL="$jpeg_impl" \
  --build-arg HEVC="$with_hevc" \
  --build-arg ZLIB_NG="$with_zlib_ng" \
'@
$buildScriptText=$buildScriptText.Replace($buildArgsMarker,$buildArgs.TrimEnd())
$runtimePackageMarker='  -e PKGS="${pkgs[*]}" \'
if([regex]::Matches($buildScriptText,[regex]::Escape($runtimePackageMarker)).Count -ne 1){throw 'Expected one runtime packaging PKGS argument.'}
$buildScriptText=$buildScriptText.Replace($runtimePackageMarker,'  -e PKGS="" \')
Write-Utf8NoBom -Path $buildScript -Content $buildScriptText

$pangoPatch=Join-Path $root 'media-patches/libvips/0002-pango-clang-unused-global.patch'
Assert-FileExists $pangoPatch|Out-Null
Invoke-Native $git @('-C',$source,'apply','--check','--whitespace=error-all',$pangoPatch)
Invoke-Native $git @('-C',$source,'apply','--whitespace=error-all',$pangoPatch)

# Mirror the Immich base-image libvips behavior instead of building the plain
# upstream Windows package. The base image for this Immich generation used
# libvips v8.18.5 plus a loader-priority patch so cheap HEIF/JPEG sniffers run
# before dcraw. Inject that patch into the MXE vips-all build recipe.
$immichPatch=Join-Path $root ([string]$v.immichLoaderPatch)
Assert-FileExists $immichPatch|Out-Null
$containerPatch=Join-Path $source 'build/patches/immich-loader-priority.patch'
Copy-Item -LiteralPath $immichPatch -Destination $containerPatch -Force
$popplerPatch=Join-Path $root 'media-patches/libvips/0004-poppler-fontinfo-vector.patch'
Assert-FileExists $popplerPatch|Out-Null
Copy-Item -LiteralPath $popplerPatch -Destination (Join-Path $source 'build/patches/poppler-0001-fontinfo-vector.patch') -Force
$pluginDirectoryPatch=Join-Path $root 'media-patches/libvips/0005-win32-plugin-directory-separators.patch'
Assert-FileExists $pluginDirectoryPatch|Out-Null
Copy-Item -LiteralPath $pluginDirectoryPatch -Destination (Join-Path $source 'build/patches/win32-plugin-directory-separators.patch') -Force
$vipsMake=Join-Path $source 'build/plugins/all-deps/vips-all.mk'
$vipsMakeText=Get-Content -Raw -LiteralPath $vipsMake
$buildLine='    $(vips_BUILD)'
$matches=[regex]::Matches($vipsMakeText,[regex]::Escape($buildLine)).Count
if($matches -ne 1){throw "Expected exactly one vips_BUILD call in vips-all.mk; found $matches. Upstream build-win64-mxe layout changed."}
$patchLine="    patch -p1 -d '`$(SOURCE_DIR)' < /data/patches/immich-loader-priority.patch"
$pluginDirectoryPatchLine="    patch -p1 -d '`$(SOURCE_DIR)' < /data/patches/win32-plugin-directory-separators.patch"
Write-Utf8NoBom -Path $vipsMake -Content $vipsMakeText.Replace($buildLine,"$patchLine`n$pluginDirectoryPatchLine`n$buildLine")

$jpegFlag=if($v.jpeg -eq 'jpegli'){'--with-jpegli'}elseif($v.jpeg -eq 'libjpeg-turbo'){'--with-jpeg-turbo'}else{''}
$command=("./build.sh -t {0} --with-hevc {1} {2}" -f $v.target,$jpegFlag,$v.variant).Trim()
$previousPackagingPath=$env:IMMICH_PACKAGING_PATH
$previousPathConversion=$env:MSYS_NO_PATHCONV
$env:IMMICH_PACKAGING_PATH=(Join-Path $source 'packaging').Replace('\','/')
$env:MSYS_NO_PATHCONV='1'
try{Invoke-Native $bash @('-lc',$command) $source}
finally{
    $env:IMMICH_PACKAGING_PATH=$previousPackagingPath
    $env:MSYS_NO_PATHCONV=$previousPathConversion
}
$suffix=if($v.jpeg -eq 'jpegli'){'-hevc-jpegli'}elseif($v.jpeg -eq 'libjpeg-turbo'){'-hevc-libjpeg-turbo'}else{'-hevc'}
$zipName="vips-dev-x64-all-$($v.version)$suffix.zip"
$containerName='immich-libvips-export-'+[Guid]::NewGuid().ToString('N')
Invoke-Native $runtime @('create','--name',$containerName,'libvips-build-win-mxe:latest')|Out-Null
try{
    Invoke-Native $runtime @('cp',"${containerName}:/data/packaging/$zipName",(Join-Path $source 'packaging'))
}
finally{Invoke-Native $runtime @('rm',$containerName)|Out-Null}
$zip=Get-ChildItem -LiteralPath (Join-Path $source 'packaging') -Filter "vips-dev-x64-all-$($v.version)$suffix.zip" -File|Select-Object -First 1
if(-not $zip){
    $candidates=Get-ChildItem -LiteralPath (Join-Path $source 'packaging') -Filter 'vips-dev-x64-all-*-hevc*.zip' -File
    throw "Expected libvips $($v.version) HEVC package was not produced. Candidates: $($candidates.Name -join ', ')"
}
$temp=Expand-ZipClean $zip.FullName (Join-Path $root '.work/sharp-libvips-extracted')
$vipsRoot=Get-ChildItem -LiteralPath $temp -Directory|Where-Object{$_.Name -like 'vips-dev-*'}|Select-Object -First 1
if(-not $vipsRoot){throw 'Unexpected build-win64-mxe zip layout.'}
$bin=Join-Path $vipsRoot.FullName 'bin'
if(-not(Test-Path $bin)){throw "libvips bin directory missing: $bin"}

$Destination=New-CleanDirectory $Destination
$lib=Join-Path $Destination 'lib';New-Item -ItemType Directory -Path $lib -Force|Out-Null
$dlls=@(Get-ChildItem -LiteralPath $bin -Filter '*.dll' -File -Recurse)
if(-not($dlls.Name -contains 'libvips-42.dll')){throw 'Built libvips package has no libvips-42.dll.'}
foreach($dll in $dlls){
    $relative=Get-RelativePathPortable -BasePath $bin -FullPath $dll.FullName
    $target=Join-Path $lib $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force|Out-Null
    Copy-Item -LiteralPath $dll.FullName -Destination $target -Force
}
Assert-WindowsPeTlsDirectory -Path (Join-Path $lib 'libglib-2.0-0.dll')
foreach($name in @('versions.json','LICENSE','README.md','ChangeLog')){
    $candidate=Join-Path $vipsRoot.FullName $name
    if(Test-Path -LiteralPath $candidate){Copy-Item -LiteralPath $candidate -Destination (Join-Path $Destination $name) -Force}
}
$versionsFile=Join-Path $Destination 'versions.json'
if(Test-Path -LiteralPath $versionsFile -PathType Leaf){
    $builtVersions=Read-JsonFile $versionsFile
    if([string]$builtVersions.vips -ne [string]$v.version){throw "Built libvips version mismatch. Expected $($v.version), got $($builtVersions.vips)"}
    if([string]$builtVersions.heif -ne [string]$v.libheif.version){throw "Built libheif version mismatch. Expected $($v.libheif.version), got $($builtVersions.heif)"}
    if($v.jpeg -eq 'jpegli' -and -not $builtVersions.jpegli){throw 'Codec bundle was expected to use jpegli but versions.json has no jpegli entry.'}
}
else { throw 'Built codec bundle is missing versions.json; libheif cannot be verified.' }
$metadata=[ordered]@{
    schemaVersion=1
    libvips=$v.version
    sharp=$((Read-JsonFile (Join-Path $root 'dependencies/versions.json')).sharp.version)
    sourceRepository=$v.repository
    sourceCommit=$actual
    target=$v.target
    variant=$v.variant
    hevc=$true
    jpeg=$v.jpeg
    libvipsRevision=$v.libvipsRevision
    libheif=$v.libheif.version
    libheifRevision=$v.libheif.revision
    libheifSourceSha256=$v.libheif.sha256
    immichBaseImagesCommit=$v.immichBaseImagesCommit
    immichLoaderPatch=$v.immichLoaderPatch
    mediaPatchesSha256=$nativeIdentity.mediaPatchesSha256
    nativeBuildInputsSha256=$nativeIdentity.nativeBuildInputsSha256
    dllCount=$dlls.Count
    builtAtUtc=[DateTime]::UtcNow.ToString('o')
    warning='HEVC build includes patent-encumbered and GPL-licensed components. Preserve upstream license notices and review distribution obligations before sharing binaries.'
}
$metadata|ConvertTo-Json -Depth 5|Set-Content -Encoding utf8 -LiteralPath (Join-Path $Destination 'immich-windows-libvips.json')
Write-Host "Codec-complete Windows libvips bundle staged at $Destination"
Write-Output $Destination
