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
    Check ($builder.Contains('build/patches/glib-3-win32-tls-directory.patch')) 'TLS patch does not use the MXE glib-[0-9]* discovery naming.'
    Check ($builder.Contains('$targetCacheId="immich-mxe-$($v.target)-$($nativeIdentity.nativeBuildInputsSha256)"')) 'BuildKit installed-library cache lacks the content digest.'
    Check ($builder.Contains('Assert-WindowsPeTlsDirectory -Path')) 'Native output is not checked for a TLS directory.'
    foreach($file in @('build/Stage-CustomSharpLibvips.ps1','build/Build-Release.ps1','build/Build-All.ps1')){
        Check ((Get-Content -Raw -LiteralPath (Join-Path $repo $file)).Contains('Assert-NativeMediaBundleIdentity')) "Explicit or cached bundle identity bypass in $file."
    }
    $actualPatch=Get-Content -Raw -LiteralPath (Join-Path $repo 'media-patches/libvips/0006-glib-win32-tls-directory.patch')
    Check ($actualPatch.Contains('+const IMAGE_TLS_DIRECTORY * const g_priv_tls_used_ = &_tls_used;')) 'Upstream TLS directory anchor is missing.'
    Check ($actualPatch.Contains('+__attribute__ ((used, selectany))')) 'Upstream TLS anchor retention is missing.'
    if($LegacyGlibDll){Reject {Assert-WindowsPeTlsDirectory $LegacyGlibDll} 'Accepted the known-bad released GLib DLL.'}
    Write-Host 'PASS native media build: PE TLS directory/callback bounds, content-addressed cache, stale bundle rejection, upstream patch wiring.'
}finally{if(Test-Path -LiteralPath $base){Remove-Item -LiteralPath $base -Recurse -Force}}
