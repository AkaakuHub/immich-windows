#requires -Version 7.0
# Execute the actual Install.cmd embedded PowerShell, with only HTTP mocked.
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Import-Module (Join-Path $repo 'runtime/Common.psm1') -Force
$tag=Get-WindowsReleaseVersion (Get-Content -Raw (Join-Path $repo 'upstream.json')|ConvertFrom-Json)
$template=(Get-Content -Raw (Join-Path $repo 'packaging/Install.cmd')).Replace('__IMMICH_VERSION__',$tag)
$embedded=[regex]::Match($template,'(?m)^pwsh\.exe -NoProfile -ExecutionPolicy Bypass -Command "(.*)"\r?$')
if (-not $embedded.Success) { throw 'Could not find the real bootstrap download/validation command.' }
if (-not $template.Contains('set "immichVersion='+$tag+'"') -or
    -not $template.Contains('-File "%IMMICH_BOOTSTRAP_STAGE%\immich-windows-%immichVersion%-win-x64\installer\Install.ps1" %*')) {
    throw 'Generated bootstrap does not preserve the release identity and installer argument forwarding.'
}
$command=[scriptblock]::Create($embedded.Groups[1].Value)
$root=Join-Path ([IO.Path]::GetTempPath()) ('immich-bootstrap-tests-'+[guid]::NewGuid().ToString('N'))
$oldVersion=$env:immichVersion;$oldStage=$env:IMMICH_BOOTSTRAP_STAGE;$oldEvents=$env:IMMICH_BOOTSTRAP_TEST_EVENTS
function Invoke-WebRequest {
    param([string]$Uri,[string]$OutFile)
    if ($Uri -cne "https://github.com/AkaakuHub/immich-windows/releases/download/$env:immichVersion/immich-windows-$env:immichVersion-win-x64.zip") { throw 'Bootstrap download target is incorrect.' }
    Add-Content $env:IMMICH_BOOTSTRAP_TEST_EVENTS download
    Copy-Item -LiteralPath $global:ImmichBootstrapArchive -Destination $OutFile
}
try {
    $index=0
    foreach ($version in @($tag,'v3.2.4.0','v3.2.2.8','v3.2.4.10','v0.0.0.0','v3.2.4.00','v3.2.4.01','v03.2.4.0','v3.02.4.0','v3.2.04.0','v3.2.4.-1','v3.2.4.+1','v3.2.4','V3.2.4.0',"v3.2.4.0`n")) {
        $case=Join-Path $root ([string]$index++)
        $env:immichVersion=$version
        $env:IMMICH_BOOTSTRAP_STAGE=Join-Path $case stage
        $env:IMMICH_BOOTSTRAP_TEST_EVENTS=Join-Path $case events
        $valid=$index -le 5
        New-Item -ItemType Directory -Path $case -Force | Out-Null
        if ($valid) {
            $fixture=Join-Path $case "immich-windows-$version-win-x64"
            New-Item -ItemType Directory -Path (Join-Path $fixture installer) -Force | Out-Null
            Set-Content (Join-Path $fixture version.txt) $version
            Set-Content (Join-Path $fixture 'installer/Test-ReleasePackage.ps1') 'param($PackageRoot,$Version); if ((Get-Content -Raw (Join-Path $PackageRoot version.txt)).Trim() -cne $Version) { throw "Bootstrap package identity differs" }; Add-Content $env:IMMICH_BOOTSTRAP_TEST_EVENTS validate'
            $global:ImmichBootstrapArchive=Join-Path $case fixture.zip
            Compress-Archive -LiteralPath $fixture -DestinationPath $global:ImmichBootstrapArchive
        }
        $caught=$null
        try { & $command } catch { $caught=$_ }
        if ($valid) {
            if ($caught) { throw $caught }
            if ((Get-Content $env:IMMICH_BOOTSTRAP_TEST_EVENTS) -join ',' -cne 'download,validate') { throw 'Bootstrap did not download and validate exactly once.' }
        } else {
            if (-not $caught -or $caught.Exception.Message -cne 'Invalid installer version.' -or (Test-Path -LiteralPath $env:IMMICH_BOOTSTRAP_STAGE) -or (Test-Path -LiteralPath $env:IMMICH_BOOTSTRAP_TEST_EVENTS)) {
                throw "Malformed bootstrap version was not rejected before acquisition: [$version]"
            }
        }
        Write-Host "PASS actual Install.cmd command: case $index"
    }
} finally {
    $env:immichVersion=$oldVersion;$env:IMMICH_BOOTSTRAP_STAGE=$oldStage;$env:IMMICH_BOOTSTRAP_TEST_EVENTS=$oldEvents
    Remove-Variable ImmichBootstrapArchive -Scope Global -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
