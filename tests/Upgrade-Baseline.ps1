#requires -Version 7.0
# Offline release API/download fixtures. No network, installer, or database runs.
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$root=Join-Path ([IO.Path]::GetTempPath()) ('immich-baseline-tests-'+[guid]::NewGuid().ToString('N'))
function Invoke-RestMethod {
    param([uri]$Uri,$Headers,$TimeoutSec)
    if ($Uri.Host -cne 'api.github.com' -or $Uri.AbsolutePath -cne '/repos/AkaakuHub/immich-windows/releases') { throw 'Unexpected release API target.' }
    if ($Uri.Query -cnotmatch '\A\?per_page=100&page=([1-9][0-9]*)\z') { throw 'Unexpected release API query.' }
    $page=[int]$Matches[1]
    if (-not $global:ImmichBaselineFixture.Pages.ContainsKey($page)) { throw "Unexpected release API page: $page" }
    $global:ImmichBaselineFixture.Queries++
    # The real cmdlet emits a top-level JSON array as one pipeline object.
    # Returning an enumerated array here masks an extra @() in the caller.
    Write-Output -NoEnumerate $global:ImmichBaselineFixture.Pages[$page]
}
function Invoke-WebRequest {
    param([string]$Uri,[string]$OutFile,$TimeoutSec)
    $name=$Uri.Split('/')[-1]
    if (-not $global:ImmichBaselineFixture.Downloads.ContainsKey($name)) { throw 'Unexpected asset download.' }
    Copy-Item -LiteralPath $global:ImmichBaselineFixture.Downloads[$name] -Destination $OutFile
    $global:ImmichBaselineFixture.DownloadCount++
}
try {
    foreach ($mode in @('success','single-release','pagination','pagination-empty-tail','cached-native','no-older','empty-releases','bad-digest','bad-size','bad-content','wrong-url','duplicate-asset','mismatched-version','bad-source-commit','wrong-native-pin','cached-native-corrupt','existing-destination')) {
        $case=Join-Path $root $mode
        $source=Join-Path $case 'source'
        $destination=Join-Path $case 'destination'
        $cache=Join-Path $case 'cache'
        $candidate=Join-Path $case 'candidate'
        $folder='immich-windows-v3.2.2.8-win-x64'
        $package=Join-Path $source $folder
        New-Item -ItemType Directory -Path "$package/installer",$candidate,$cache -Force | Out-Null
        Set-Content (Join-Path $candidate 'manifest.json') '{"schemaVersion":2,"immichVersion":"v3.2.4","windowsRevision":0,"packageVersion":"v3.2.4.0"}'
        $nativeName='immich-windows-v3.2.2.8-native-dependencies.zip'
        $native=Join-Path $source $nativeName
        Set-Content -LiteralPath $native 'native archive fixture bytes'
        $manifest=[ordered]@{schemaVersion=2;immichVersion='v3.2.2';windowsRevision=8;packageVersion='v3.2.2.8';upstreamCommit=('a'*40);sourceCommit=('b'*40);nativeDependenciesSha256=(Get-FileHash -LiteralPath $native -Algorithm SHA256).Hash.ToLowerInvariant()}
        switch ($mode) {
            'mismatched-version' { $manifest.windowsRevision=7; $manifest.packageVersion='v3.2.2.7' }
            'bad-source-commit' { $manifest.sourceCommit='not-a-commit' }
            'wrong-native-pin' { $manifest.nativeDependenciesSha256='0'*64 }
        }
        $manifest | ConvertTo-Json | Set-Content (Join-Path $package 'manifest.json')
        Set-Content (Join-Path $package 'installer/Test-ReleasePackage.ps1') 'param($PackageRoot,$Version); if ($Version -cne "v3.2.2.8") { throw "Wrong historical validator input" }; $global:LASTEXITCODE=0'
        $application=Join-Path $source "$folder.zip"
        Compress-Archive -LiteralPath $package -DestinationPath $application
        $assets=@()
        $downloads=@{}
        foreach ($path in @($application,$native)) {
            $file=Get-Item -LiteralPath $path
            $downloads[$file.Name]=$path
            $assets+=,[pscustomobject]@{name=$file.Name;size=$file.Length;digest=('sha256:'+(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant());browser_download_url="https://github.com/AkaakuHub/immich-windows/releases/download/v3.2.2.8/$($file.Name)"}
        }
        switch ($mode) {
            'bad-digest' { $assets[0].digest=$null }
            'bad-size' { $assets[0].size++ }
            'bad-content' { $assets[0].digest='sha256:'+('0'*64) }
            'wrong-url' { $assets[0].browser_download_url='https://example.invalid/asset.zip' }
            'duplicate-asset' { $assets+=,$assets[0] }
        }
        $releases=@(
            [pscustomobject]@{tag_name='v3.2.4.0';draft=$false;prerelease=$false;assets=@()},
            [pscustomobject]@{tag_name='v3.2.3.9';draft=$true;prerelease=$false;assets=@()},
            [pscustomobject]@{tag_name='v3.2.3.8';draft=$false;prerelease=$true;assets=@()},
            [pscustomobject]@{tag_name='v3.2.3.00';draft=$false;prerelease=$false;assets=@()},
            [pscustomobject]@{tag_name='V3.2.3.0';draft=$false;prerelease=$false;assets=@()},
            [pscustomobject]@{tag_name='v3.2.3.0-rc.1';draft=$false;prerelease=$false;assets=@()},
            [pscustomobject]@{tag_name="v3.2.3.0`n";draft=$false;prerelease=$false;assets=@()},
            [pscustomobject]@{tag_name='v3.2.2.7';draft=$false;prerelease=$false;assets=@()},
            [pscustomobject]@{tag_name='v3.2.2.8';draft=$false;prerelease=$false;assets=$assets}
        )
        if ($mode -eq 'no-older') { $releases=@($releases[0]) }
        if ($mode -eq 'single-release') { $releases=@($releases[-1]) }
        if ($mode -eq 'empty-releases') { $releases=@() }
        $pages=@{1=$releases}
        if ($mode -eq 'pagination') {
            # A full page with an eligible version must not hide a newer
            # baseline on a later page; API ordering is not version ordering.
            $pages=@{1=@((1..100) | ForEach-Object { [pscustomobject]@{tag_name='v3.2.2.7';draft=$false;prerelease=$false;assets=@()} });2=$releases}
        }
        if ($mode -eq 'pagination-empty-tail') { $pages=@{1=@((1..100) | ForEach-Object { $releases[-1] });2=@()} }
        if ($mode -in @('cached-native','cached-native-corrupt')) {
            Copy-Item -LiteralPath $native -Destination $cache
            if ($mode -eq 'cached-native-corrupt') { Add-Content -LiteralPath (Join-Path $cache $nativeName) 'tampered' }
        }
        if ($mode -eq 'existing-destination') { New-Item -ItemType Directory $destination | Out-Null }
        $global:ImmichBaselineFixture=@{Pages=$pages;Downloads=$downloads;Queries=0;DownloadCount=0};$caught=$null;$result=$null
        try { $result=& (Join-Path $repo 'tests/actions/Get-UpgradeBaseline.ps1') -CandidatePackageRoot $candidate -Destination $destination -DownloadCache $cache }
        catch { $caught=$_ }
        if ($mode -in @('success','single-release','pagination','pagination-empty-tail','cached-native')) {
            if ($caught) { throw $caught }
            if ($result.Version -cne 'v3.2.2.8' -or -not (Test-Path -LiteralPath (Join-Path $result.PackageRoot 'manifest.json'))) { throw 'Baseline selection/extraction failed.' }
            if ($global:ImmichBaselineFixture.DownloadCount -ne $(if ($mode -eq 'cached-native') {1} else {2})) { throw 'Unexpected repeated baseline acquisition.' }
            if ($global:ImmichBaselineFixture.Queries -ne $(if ($mode -in @('pagination','pagination-empty-tail')) {2} else {1})) { throw 'Incorrect API pagination.' }
        } else {
            if (-not $caught) { throw "Unsafe baseline was accepted: $mode" }
            $expectedError=switch ($mode) {
                { $_ -in @('no-older','empty-releases') } { 'No published stable Windows release precedes' }
                { $_ -in @('bad-digest','duplicate-asset') } { 'Missing unique SHA-256 verified baseline asset' }
                { $_ -in @('bad-size','bad-content','cached-native-corrupt') } { 'Baseline asset SHA-256 or size mismatch' }
                'wrong-url' { 'Unexpected baseline asset URL' }
                { $_ -in @('mismatched-version','bad-source-commit') } { 'Baseline package identity or native archive provenance does not match' }
                'wrong-native-pin' { 'Historical native archive provenance mismatch' }
                'existing-destination' { 'Upgrade baseline destination already exists' }
            }
            if (-not $caught.Exception.Message.Contains($expectedError)) { throw "Wrong rejection for ${mode}: $($caught.Exception.Message)" }
        }
        Write-Host "PASS verified upgrade baseline: $mode"
    }
} finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue; Remove-Variable ImmichBaselineFixture -Scope Global -ErrorAction SilentlyContinue }
