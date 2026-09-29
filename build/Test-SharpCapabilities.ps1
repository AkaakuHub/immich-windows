#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ApplicationRoot,
    [string[]]$Fixture = @()
)
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
Assert-WindowsX64
$ApplicationRoot=(Resolve-Path -LiteralPath $ApplicationRoot).Path
$nodePath = Join-Path (Get-RepositoryRoot) '.tools\node\node.exe'
if (-not (Test-Path -LiteralPath $nodePath -PathType Leaf)) { throw "Pinned Node runtime is missing: $nodePath" }
$nodeVersion = (& $nodePath --version).Trim().TrimStart('v')
$expectedNodeVersion = [string](Read-JsonFile (Join-Path (Get-RepositoryRoot) 'dependencies\versions.json')).node.version
if ($nodeVersion -ne $expectedNodeVersion) { throw "Sharp qualification requires Node $expectedNodeVersion; found $nodeVersion." }
$node = Get-Item -LiteralPath $nodePath
$scriptPath = Join-Path (Get-RepositoryRoot) '.work\test-sharp-capabilities.cjs'
New-Item -ItemType Directory -Path (Split-Path $scriptPath -Parent) -Force | Out-Null
$serverRoot = Join-Path $ApplicationRoot 'server'
$smokeMarker = Join-Path $ApplicationRoot 'sharp-libvips-smoke.json'
$qualificationMarker = Join-Path $ApplicationRoot 'sharp-libvips-qualification.json'
Remove-Item -LiteralPath $qualificationMarker -Force -ErrorAction SilentlyContinue
$js = @'
const path = require('node:path');
const { createRequire } = require('node:module');
const req = createRequire(path.join(process.argv[2], 'package.json'));
const sharp = req('sharp');
(async () => {
  const report = { versions: sharp.versions, formats: sharp.format, fixtures: [] };
  for (const file of process.argv.slice(3)) {
    try {
      const image = sharp(file, { failOn: 'error' });
      const metadata = await image.metadata();
      await image.clone().resize({ width: 64, height: 64, fit: 'inside' }).jpeg().toBuffer();
      report.fixtures.push({ file, ok: true, format: metadata.format, width: metadata.width, height: metadata.height });
    } catch (error) {
      report.fixtures.push({ file, ok: false, error: String(error && error.stack || error) });
    }
  }
  console.log(JSON.stringify(report, null, 2));
  if (report.fixtures.some((x) => !x.ok)) process.exitCode = 2;
})().catch((error) => { console.error(error); process.exit(3); });
'@
Write-Utf8NoBom -Path $scriptPath -Content $js
$fixturePaths=@($Fixture | ForEach-Object { (Resolve-Path -LiteralPath $_).Path })
$pnpmRoot=Join-Path $serverRoot 'node_modules\.pnpm'
$sharpPackage=Get-ChildItem -LiteralPath $pnpmRoot -Directory -Filter '@img+sharp-win32-x64@*' | Select-Object -First 1
if(-not $sharpPackage){throw 'Deployed @img/sharp-win32-x64 package was not found.'}
$sharpLib=Join-Path $sharpPackage.FullName 'node_modules\@img\sharp-win32-x64\lib'
if(-not(Test-Path -LiteralPath $sharpLib -PathType Container)){throw 'Deployed @img/sharp-win32-x64 library was not found.'}
$previousPath=$env:PATH
$env:PATH="$sharpLib;$previousPath"
try{
    $rawReport=@(& $node.FullName $scriptPath $serverRoot @fixturePaths)
    $nodeExit=$LASTEXITCODE
}
finally{$env:PATH=$previousPath}
$reportText=$rawReport -join "`n"
if($reportText){Write-Host $reportText}
if ($nodeExit -ne 0) { throw "Sharp capability test failed with exit code $nodeExit" }
try{$report=$reportText|ConvertFrom-Json}catch{throw "Sharp capability test did not emit valid JSON: $($_.Exception.Message)"}

$bundleMetadataPath=Join-Path $ApplicationRoot 'media-stack\sharp-libvips\immich-windows-libvips.json'
if(Test-Path -LiteralPath $bundleMetadataPath -PathType Leaf){
    $bundleMetadata=Get-Content -Raw -LiteralPath $bundleMetadataPath|ConvertFrom-Json
    if([string]$bundleMetadata.libvips -and [string]$report.versions.vips -ne [string]$bundleMetadata.libvips){
        throw "Sharp loaded libvips $($report.versions.vips), but the injected bundle declares $($bundleMetadata.libvips)."
    }
}

$smoke=[ordered]@{
    schemaVersion=1
    testedAtUtc=[DateTime]::UtcNow.ToString('o')
    libvips=[string]$report.versions.vips
    fixtureCount=$fixturePaths.Count
    fixtures=@($report.fixtures)
}
$smoke|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $smokeMarker -Encoding utf8

if($fixturePaths.Count -eq 0){
    Write-Warning 'Sharp/libvips runtime loaded, but no media fixtures were supplied. The application is NOT production-qualified.'
    return
}

$rawExtensions=@('.3fr','.arw','.cr2','.cr3','.dng','.erf','.kdc','.mrw','.nef','.nrw','.orf','.pef','.raf','.raw','.rw2','.sr2','.srf','.srw','.x3f')
$counts=[ordered]@{jpeg=0;png=0;webp=0;avif=0;heif=0;raw=0;jxl=0}
foreach($file in $fixturePaths){
    $extension=[IO.Path]::GetExtension($file).ToLowerInvariant()
    switch($extension){
        '.jpg' {$counts['jpeg']=[int]$counts['jpeg']+1}
        '.jpeg' {$counts['jpeg']=[int]$counts['jpeg']+1}
        '.png' {$counts['png']=[int]$counts['png']+1}
        '.webp' {$counts['webp']=[int]$counts['webp']+1}
        '.avif' {$counts['avif']=[int]$counts['avif']+1}
        '.heic' {$counts['heif']=[int]$counts['heif']+1}
        '.heif' {$counts['heif']=[int]$counts['heif']+1}
        '.jxl' {$counts['jxl']=[int]$counts['jxl']+1}
        default { if($rawExtensions -contains $extension){$counts['raw']=[int]$counts['raw']+1} }
    }
}
$requirements=[ordered]@{jpeg=2;png=1;webp=1;avif=1;heif=3;raw=1;jxl=1}
$missing=@()
foreach($name in $requirements.Keys){
    if([int]$counts[$name] -lt [int]$requirements[$name]){
        $missing += "${name}: need $($requirements[$name]), got $($counts[$name])"
    }
}
if($missing.Count -gt 0){
    throw "Sharp fixture matrix is incomplete; production qualification was not written. $($missing -join '; ')"
}

$qualification=[ordered]@{
    schemaVersion=1
    productionQualified=$true
    qualifiedAtUtc=[DateTime]::UtcNow.ToString('o')
    libvips=[string]$report.versions.vips
    fixtureCount=$fixturePaths.Count
    categoryCounts=$counts
    requiredCategoryCounts=$requirements
    fixtures=@($report.fixtures)
    note='Category counts check file extensions only. Results cover the supplied samples; they do not establish coverage of HDR or other format variants.'
}
$qualification|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $qualificationMarker -Encoding utf8
Write-Host "Sharp/libvips production fixture qualification written: $qualificationMarker"
