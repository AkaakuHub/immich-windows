[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'PowerShell 7 (pwsh.exe) is required.' }
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}

$scriptRoots=@('build','packaging','migration','runtime','tests')
$parseErrors=@()
$scriptFiles=@()
foreach($dir in $scriptRoots){
    $path=Join-Path $root $dir
    if(-not(Test-Path $path)){continue}
    foreach($file in Get-ChildItem -LiteralPath $path -Recurse -File | Where-Object {$_.Extension -in @('.ps1','.psm1')}){
        $scriptFiles += $file
        $tokens=$null;$errors=$null
        [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
        foreach($parseIssue in @($errors)){$parseErrors += "$($file.FullName):$($parseIssue.Extent.StartLineNumber): $($parseIssue.Message)"}
    }
}
if($parseErrors.Count){throw "PowerShell parse errors:`n$($parseErrors -join "`n")"}

$commonModule=Join-Path $root 'build\Common.psm1'
Import-Module $commonModule -Force
foreach($helper in @('Get-CachedDownload','Expand-ZipClean','Assert-FileExists','Invoke-Native')){
    $command=Get-Command $helper -ErrorAction SilentlyContinue
    Assert-True ($null -ne $command) "build/Common.psm1 did not export required helper: $helper"
}

foreach($requiredFile in @('packaging/Recover-Upgrade.ps1','packaging/Update.ps1','migration/New-DatabaseBackup.ps1','migration/Import-Database.ps1')){
    Assert-True (Test-Path -LiteralPath (Join-Path $root $requiredFile) -PathType Leaf) "Missing release recovery component: $requiredFile"
}

$packagingCommon=Join-Path $root 'packaging\Common.psm1'
Import-Module $packagingCommon -Force
$envRoundTrip=Join-Path ([IO.Path]::GetTempPath()) ("immich-windows-env-"+[guid]::NewGuid().ToString('N')+".env")
try {
    $expectedPassword=' leading=middle trailing '
    Write-EnvFile -Path $envRoundTrip -Values ([ordered]@{DB_PASSWORD=$expectedPassword;DB_DATABASE_NAME='immich'})
    $parsedEnv=Read-EnvFile $envRoundTrip
    Assert-True ([string]$parsedEnv.DB_PASSWORD -ceq $expectedPassword) 'Env parsing must preserve password whitespace and embedded equals signs exactly.'
} finally { Remove-Item -LiteralPath $envRoundTrip -Force -ErrorAction SilentlyContinue }

$upstream=Get-Content -Raw -LiteralPath (Join-Path $root 'upstream.json')|ConvertFrom-Json
Assert-True ($upstream.version -match '^v[0-9]+\.[0-9]+\.[0-9]+$') "Invalid upstream version: $($upstream.version)"
Assert-True ($upstream.commit -match '^[0-9a-f]{40}$') 'upstream.json must pin a full 40-character commit SHA.'

$seriesPath=Join-Path $root 'patches/series'
Assert-True (Test-Path -LiteralPath $seriesPath -PathType Leaf) 'patches/series is required.'
$series=@(Get-Content -LiteralPath $seriesPath|ForEach-Object{$_.Trim()}|Where-Object{$_ -and -not $_.StartsWith('#')})
$listed=@($series|ForEach-Object{(Join-Path (Join-Path $root 'patches') $_)})
$all=@(Get-ChildItem -LiteralPath (Join-Path $root 'patches') -Recurse -Filter '*.patch' -File|Select-Object -ExpandProperty FullName)
Assert-True ($all.Count -eq $listed.Count) 'Every .patch file must be listed exactly once in patches/series.'
foreach($file in $listed){Assert-True (Test-Path -LiteralPath $file -PathType Leaf) "Missing patch file: $file"}
foreach($file in $all){Assert-True ($file -in $listed) "Unlisted patch file: $file"}

# Parse each patch without requiring an upstream working tree. This catches malformed
# unified-diff hunk headers before the networked Prepare-Source CI stage.
foreach($relative in $series){
    $patch=Join-Path (Join-Path $root 'patches') $relative
    $output=& git apply --numstat -- $patch 2>&1
    Assert-True ($LASTEXITCODE -eq 0) "Malformed patch file: $relative`n$($output -join "`n")"
}

# This repository is a distribution/patch layer, not an Immich source fork.
foreach($forbiddenRoot in @('server','web','mobile','machine-learning','packages','docker')){
    Assert-True (-not(Test-Path -LiteralPath (Join-Path $root $forbiddenRoot))) "Upstream Immich source directory must not be tracked at repository root: $forbiddenRoot"
}
Assert-True (-not(Test-Path -LiteralPath (Join-Path $root '.gitmodules'))) 'Do not add Immich as a git submodule; source is fetched from the pinned tag at build time.'

$versions=Get-Content -Raw -LiteralPath (Join-Path $root 'dependencies/versions.json')|ConvertFrom-Json
Assert-True ([int]$versions.postgresql.major -eq ([version]$versions.postgresql.version).Major) 'PostgreSQL major and version differ.'
foreach($name in @('node','pnpm','sharp','pgvector','vectorchord','sharpLibvips')){
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$versions.$name.version)) "Missing dependency version: $name"
}
$mediaPatch=Join-Path $root ([string]$versions.sharpLibvips.immichLoaderPatch)
Assert-True (Test-Path -LiteralPath $mediaPatch -PathType Leaf) 'Pinned Immich base-image libvips loader patch is missing.'

Write-Host "Static repository audit passed for $($scriptFiles.Count) PowerShell files."
