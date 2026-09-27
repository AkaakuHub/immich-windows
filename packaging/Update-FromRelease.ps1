[CmdletBinding()]
param(
    [string]$Version,
    [ValidateSet('AllUsers','CurrentUser')][string]$Scope='AllUsers',
    [string]$InstallRoot,
    [string]$DataRoot,
    [string]$PostgresRoot='C:\Program Files\PostgreSQL\18',
    [string]$PostgresService='postgresql-x64-18'
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
if ($Scope -eq 'AllUsers') { Assert-Administrator }
$paths=Resolve-ImmichInstallPaths -Scope $Scope -InstallRoot $InstallRoot -DataRoot $DataRoot
$InstallRoot=$paths.InstallRoot
$DataRoot=$paths.DataRoot
New-Item -ItemType Directory -Path $DataRoot -Force|Out-Null

if($Version -and $Version -notmatch '^v\d+\.\d+\.\d+$'){throw "Invalid Immich version: $Version"}
$releaseUri=if($Version){"https://api.github.com/repos/AkaakuHub/immich-windows/releases/tags/$Version"}else{'https://api.github.com/repos/AkaakuHub/immich-windows/releases/latest'}
$release=Invoke-RestMethod -Uri $releaseUri -Headers @{'User-Agent'='immich-windows'}
$version=[string]$release.tag_name
if($version -notmatch '^v\d+\.\d+\.\d+$'){throw "Unexpected release tag: $version"}

$current=Get-CurrentReleaseTarget -InstallRoot $InstallRoot
if(-not $current){throw 'An existing Immich installation is required.'}
$currentVersion=[string](Get-Content -Raw -LiteralPath (Join-Path $current 'manifest.json')|ConvertFrom-Json).immichVersion
if($currentVersion -eq $version){Write-Host "Immich $version is already installed.";return}
if([version]$version.TrimStart('v') -lt [version]$currentVersion.TrimStart('v')){throw "Refusing to downgrade from $currentVersion to $version."}

$folder="immich-windows-$version-win-x64"
$assetName="$folder.tar.gz"
$asset=@($release.assets|Where-Object name -eq $assetName|Select-Object -First 1)
if($asset.Count -ne 1){throw "Release $version has no native Windows package: $assetName"}

$stagingBase=Join-Path (Resolve-Path -LiteralPath $DataRoot).Path 'staging'
$stage=Join-Path $stagingBase $version
$candidate=Join-Path $stage $folder
$stagingPath=[IO.Path]::GetFullPath($stagingBase).TrimEnd('\')+'\'
$stagePath=[IO.Path]::GetFullPath($stage)
if(-not $stagePath.StartsWith($stagingPath,[StringComparison]::OrdinalIgnoreCase)){throw "Invalid staging path: $stagePath"}

$readyPath=Join-Path $stage '.ready'
if(-not(Test-Path -LiteralPath $readyPath -PathType Leaf)){
    if(Test-Path -LiteralPath $stage){
        $item=Get-Item -LiteralPath $stage -Force
        if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Staging path is a junction: $stage"}
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
    New-Item -ItemType Directory -Path $stage -Force|Out-Null
    $archive=Join-Path $stage $assetName
    try{
        Invoke-WebRequest -Uri $asset[0].browser_download_url -OutFile $archive
        & tar.exe -xzf $archive -C $stage
        if($LASTEXITCODE -ne 0){throw "Could not extract $assetName"}
    }finally{Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue}
}

& (Join-Path $PSScriptRoot 'Test-ReleasePackage.ps1') -PackageRoot $candidate -Version $version
if(-not(Test-Path -LiteralPath $readyPath -PathType Leaf)){'ready'|Set-Content -Encoding ascii -LiteralPath $readyPath}
& (Join-Path $candidate 'installer\Update.ps1') -PackageRoot $candidate -Scope $Scope -InstallRoot $InstallRoot -DataRoot $DataRoot -PostgresRoot $PostgresRoot -PostgresService $PostgresService
Remove-Item -LiteralPath $stage -Recurse -Force
