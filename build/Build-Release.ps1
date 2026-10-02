#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$PostgresRoot='C:\Program Files\PostgreSQL\18',
    [string]$CustomSharpLibvipsBundle,
    [switch]$SkipCodecBuild,
    [switch]$InstallCargoPgrx,
    [string[]]$SharpFixture,
    [switch]$AllowStockSharp,
    [string]$PackageDestination
)
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
Assert-WindowsX64
$root=Get-RepositoryRoot
if(-not $AllowStockSharp -and @($SharpFixture).Count -eq 0){
    throw 'A production release requires Sharp/libvips media fixture checks. Pass -SharpFixture with the documented files, or use -AllowStockSharp only for an explicitly unqualified bring-up package.'
}
if($CustomSharpLibvipsBundle -and -not $SkipCodecBuild){
    Write-Host 'Using the explicitly supplied custom Sharp/libvips bundle; codec build stage will not run.'
    $SkipCodecBuild=$true
}
if(-not $CustomSharpLibvipsBundle){
    $v=(Read-JsonFile (Join-Path $root 'dependencies\versions.json')).sharpLibvips
    $sharp=(Read-JsonFile (Join-Path $root 'dependencies\versions.json')).sharp.version
    $cached=Join-Path $root 'artifacts\native\sharp-libvips-custom'
    $metadataPath=Join-Path $cached 'immich-windows-libvips.json'
    $useCached=$false
    if((Test-Path -LiteralPath $metadataPath -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $cached 'lib\libvips-42.dll') -PathType Leaf)){
        $metadata=Read-JsonFile $metadataPath
        $patches=Get-ChildItem -LiteralPath (Join-Path $root 'media-patches\libvips') -Filter '*.patch' -File
        $useCached=$metadata.libvips -eq $v.version -and $metadata.sharp -eq $sharp -and
            $metadata.sourceCommit -eq $v.commit -and $metadata.target -eq $v.target -and
            $metadata.variant -eq $v.variant -and $metadata.jpeg -eq $v.jpeg -and
            $metadata.libvipsRevision -eq $v.libvipsRevision -and
            $metadata.immichBaseImagesCommit -eq $v.immichBaseImagesCommit -and
            $metadata.immichLoaderPatch -eq $v.immichLoaderPatch -and
            [bool]$metadata.hevc -eq [bool]$v.hevc -and
            @($patches | Where-Object { $_.LastWriteTimeUtc -gt [datetime]$metadata.builtAtUtc }).Count -eq 0
    }
    if($useCached){
        $CustomSharpLibvipsBundle=$cached
        Write-Host "Reusing custom Sharp/libvips bundle at $cached"
    }elseif(-not $SkipCodecBuild){
        $result=& (Join-Path $PSScriptRoot 'Build-CustomSharpLibvips.ps1')
        $CustomSharpLibvipsBundle=@($result)[-1]
    }
}
if(-not $CustomSharpLibvipsBundle -and -not $AllowStockSharp){
    throw 'No qualified custom Sharp/libvips bundle is available. Build it or pass -CustomSharpLibvipsBundle before building the application.'
}
& (Join-Path $PSScriptRoot 'Build-All.ps1') -PostgresRoot $PostgresRoot -InstallCargoPgrx:$InstallCargoPgrx -CustomSharpLibvipsBundle $CustomSharpLibvipsBundle -SharpFixture $SharpFixture
$packageArgs=@{}
if($PackageDestination){$packageArgs.Destination=$PackageDestination}
if($AllowStockSharp){$packageArgs.AllowStockSharp=$true}
& (Join-Path $PSScriptRoot 'Stage-VcRuntime.ps1')
if (-not $AllowStockSharp) { & (Join-Path $root 'packaging\New-NativeDependenciesArchive.ps1') }
& (Join-Path $root 'packaging\New-Package.ps1') @packageArgs
