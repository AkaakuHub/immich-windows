#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CandidatePackageRoot,
    [Parameter(Mandatory)][string]$Destination,
    [Parameter(Mandatory)][string]$DownloadCache
)
# Download once per qualification run; both scopes install the same immutable
# released application payload. Never manufacture an older upstream manifest.
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../../runtime/Common.psm1') -Force
$candidate=Get-Content -Raw (Join-Path $CandidatePackageRoot 'manifest.json') | ConvertFrom-Json
$candidateVersion=Get-WindowsPackageVersion $candidate
$tagPattern='\Av(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z'
$headers=@{'User-Agent'='immich-windows-qualification';Accept='application/vnd.github+json';'X-GitHub-Api-Version'='2022-11-28'}
if ($env:GH_TOKEN) { $headers.Authorization="Bearer $env:GH_TOKEN" }
$eligible=@()
$page=1
do {
    # Invoke-RestMethod emits a JSON array as one pipeline object. Assign it
    # before normalizing, so @() does not wrap the entire page in another array.
    $response=Invoke-RestMethod -Uri "https://api.github.com/repos/AkaakuHub/immich-windows/releases?per_page=100&page=$page" -Headers $headers -TimeoutSec 60
    $releases=@($response)
    foreach ($release in $releases) {
        if ($release.draft -or $release.prerelease -or [string]$release.tag_name -cnotmatch $tagPattern) { continue }
        $version=[version]$release.tag_name.Substring(1)
        if ($version -lt $candidateVersion) { $eligible+=,[pscustomobject]@{Version=$version;Release=$release} }
    }
    $page++
} while ($releases.Count -eq 100)
$selected=$eligible | Sort-Object Version -Descending | Select-Object -First 1
if (-not $selected) { throw "No published stable Windows release precedes v$candidateVersion; an authentic upgrade baseline is required." }
$release=$selected.Release
$version=[string]$release.tag_name
if (Test-Path -LiteralPath $Destination) { throw 'Upgrade baseline destination already exists; refusing to reuse an unverified extraction.' }
New-Item -ItemType Directory -Path $Destination,$DownloadCache -Force | Out-Null
function Get-VerifiedBaselineAsset([string]$Name,[string]$Path) {
    $assets=@($release.assets | Where-Object { $_.name -ceq $Name })
    if ($assets.Count -ne 1 -or [string]$assets[0].digest -cnotmatch '\Asha256:[0-9a-f]{64}\z') { throw "Missing unique SHA-256 verified baseline asset: $Name" }
    $asset=$assets[0]
    $expectedUrl="https://github.com/AkaakuHub/immich-windows/releases/download/$version/$Name"
    if ([string]$asset.browser_download_url -cne $expectedUrl) { throw "Unexpected baseline asset URL: $Name" }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        # No API authorization header is sent to public release download redirects.
        Invoke-WebRequest -Uri $expectedUrl -OutFile $Path -TimeoutSec 1800
    }
    if ((Get-Item -LiteralPath $Path).Length -ne [long]$asset.size -or
        ('sha256:'+(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()) -cne [string]$asset.digest) {
        throw "Baseline asset SHA-256 or size mismatch: $Name"
    }
    return $Path
}
$folder="immich-windows-$version-win-x64"
$application=Get-VerifiedBaselineAsset "$folder.zip" (Join-Path $Destination "$folder.zip")
$nativeName="immich-windows-$version-native-dependencies.zip"
$native=Get-VerifiedBaselineAsset $nativeName (Join-Path $DownloadCache $nativeName)
$nativeSha256=([string]($release.assets | Where-Object { $_.name -ceq $nativeName }).digest).Substring(7)
Expand-Archive -LiteralPath $application -DestinationPath $Destination
$packageRoot=Join-Path $Destination $folder
$manifest=Get-Content -Raw (Join-Path $packageRoot 'manifest.json') | ConvertFrom-Json
if ((Get-WindowsPackageVersion $manifest) -ne $selected.Version -or $manifest.schemaVersion -ne 2 -or
    [string]$manifest.upstreamCommit -cnotmatch '\A[0-9a-f]{40}\z' -or
    [string]$manifest.sourceCommit -cnotmatch '\A[0-9a-f]{40}\z' -or
    [string]$manifest.nativeDependenciesSha256 -cne $nativeSha256) {
    throw 'Baseline package identity or native archive provenance does not match the released assets.'
}
# Validate the historical release with its own historical packaging rules.
$global:LASTEXITCODE=0
& (Join-Path $packageRoot 'installer/Test-ReleasePackage.ps1') -PackageRoot $packageRoot -Version $version | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Released upgrade baseline failed package validation.' }
Write-Host "Verified upgrade baseline: $version ($($manifest.immichVersion), upstream $($manifest.upstreamCommit)) -> v$candidateVersion"
[pscustomobject]@{PackageRoot=$packageRoot;Version=$version;NativeArchive=$native}
