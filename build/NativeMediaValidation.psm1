#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Get-NativeMediaBuildIdentity {
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    $versions=Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot 'dependencies/versions.json')|ConvertFrom-Json -AsHashtable
    $patches=@(Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot 'media-patches/libvips') -Filter '*.patch' -File|Sort-Object Name)
    if(-not $patches.Count){throw 'Native media patches are missing.'}
    $patchInputs=@($patches|ForEach-Object{"$($_.Name):$((Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant())"}) -join "`n"
    $patchDigest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($patchInputs))).ToLowerInvariant()
    $builderInputs=@('build/Build-CustomSharpLibvips.ps1','build/Common.psm1','build/NativeMediaValidation.psm1')|ForEach-Object {
        "${_}:$((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $RepositoryRoot $_)).Hash.ToLowerInvariant())"
    }
    # Provenance descriptions do not affect the DLL build. The selected source
    # revisions/checksums, Windows flags, patches and builder bytes do.
    $media=$versions.sharpLibvips
    foreach($field in @('notes','immichBaseImagesCommit')){[void]$media.Remove($field)}
    if($media.Contains('libheif')){[void]$media.libheif.Remove('source')}
    function ConvertTo-CanonicalNativeValue($Value) {
        if($Value -is [Collections.IDictionary]) {
            $ordered=[ordered]@{}
            foreach($key in @($Value.Keys|Sort-Object -CaseSensitive)) {$ordered[$key]=ConvertTo-CanonicalNativeValue $Value[$key]}
            return $ordered
        }
        if($Value -is [array]) {return ,@($Value|ForEach-Object {ConvertTo-CanonicalNativeValue $_})}
        return $Value
    }
    $inputs=[ordered]@{schemaVersion=2;media=(ConvertTo-CanonicalNativeValue $media);sharpVersion=$versions.sharp.version;patches=$patchDigest;builders=@($builderInputs)}|ConvertTo-Json -Depth 10 -Compress
    [pscustomobject]@{
        mediaPatchesSha256=$patchDigest
        nativeBuildInputsSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($inputs))).ToLowerInvariant()
    }
}

function Assert-WindowsPeTlsDirectory {
    param([Parameter(Mandatory)][string]$Path)
    $bytes=[IO.File]::ReadAllBytes($Path)
    if($bytes.Length -lt 64 -or [BitConverter]::ToUInt16($bytes,0) -ne 0x5a4d){throw "Invalid Windows DLL: $Path"}
    $pe=[BitConverter]::ToUInt32($bytes,0x3c)
    if([uint64]$pe+24 -gt $bytes.Length -or [BitConverter]::ToUInt32($bytes,[int]$pe) -ne 0x4550){throw "Invalid PE header: $Path"}
    $optional=[int]$pe+24
    $optionalSize=[BitConverter]::ToUInt16($bytes,[int]$pe+20)
    $sectionCount=[BitConverter]::ToUInt16($bytes,[int]$pe+6)
    $sections=$optional+$optionalSize
    if([BitConverter]::ToUInt16($bytes,[int]$pe+4) -ne 0x8664 -or $optionalSize -lt 240 -or
        [uint64]$sections+[uint64]$sectionCount*40 -gt $bytes.Length -or [BitConverter]::ToUInt16($bytes,$optional) -ne 0x20b){
        throw "Expected a complete Windows x64 PE32+ DLL: $Path"
    }
    if([BitConverter]::ToUInt32($bytes,$optional+108) -lt 10){throw "PE TLS directory is missing: $Path"}
    $tlsRva=[BitConverter]::ToUInt32($bytes,$optional+184)
    $tlsSize=[BitConverter]::ToUInt32($bytes,$optional+188)
    if(-not $tlsRva -or $tlsSize -lt 40){throw "PE TLS directory is missing: $Path"}
    function Resolve-Rva([uint64]$Rva,[uint32]$Length) {
        for($i=0;$i -lt $sectionCount;$i++){
            $section=$sections+$i*40
            $address=[BitConverter]::ToUInt32($bytes,$section+12)
            $rawSize=[BitConverter]::ToUInt32($bytes,$section+16)
            $rawOffset=[BitConverter]::ToUInt32($bytes,$section+20)
            if($Rva -ge $address -and $Rva+$Length -le [uint64]$address+$rawSize){
                $offset=[uint64]$rawOffset+$Rva-$address
                if($offset+$Length -le $bytes.Length){return [int]$offset}
            }
        }
        throw "PE TLS data is outside the DLL's file-backed sections: $Path"
    }
    $tlsOffset=Resolve-Rva $tlsRva 40
    $imageBase=[BitConverter]::ToUInt64($bytes,$optional+24)
    $callbacks=[BitConverter]::ToUInt64($bytes,$tlsOffset+24)
    if($callbacks -le $imageBase -or $callbacks-$imageBase -gt [uint32]::MaxValue){throw "PE TLS callback array is missing: $Path"}
    $callbackOffset=Resolve-Rva ($callbacks-$imageBase) 8
    if(-not [BitConverter]::ToUInt64($bytes,$callbackOffset)){throw "PE TLS callback array is empty: $Path"}
}

function Assert-NativeMediaBundleIdentity {
    param([Parameter(Mandatory)][string]$BundleRoot,[Parameter(Mandatory)][string]$RepositoryRoot)
    $metadata=Get-Content -Raw -LiteralPath (Join-Path $BundleRoot 'immich-windows-libvips.json')|ConvertFrom-Json
    $expected=Get-NativeMediaBuildIdentity -RepositoryRoot $RepositoryRoot
    foreach($field in @('mediaPatchesSha256','nativeBuildInputsSha256')){
        $actual=$metadata.PSObject.Properties[$field]
        if(-not $actual -or [string]$actual.Value -cne [string]$expected.$field){throw "Native media bundle has stale or missing $field; rebuild it from the current native inputs."}
    }
    Assert-WindowsPeTlsDirectory -Path (Join-Path $BundleRoot 'lib/libglib-2.0-0.dll')
}

Export-ModuleMember -Function Get-NativeMediaBuildIdentity,Assert-WindowsPeTlsDirectory,Assert-NativeMediaBundleIdentity
