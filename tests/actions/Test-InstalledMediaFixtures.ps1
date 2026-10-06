#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReleaseRoot,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$Fixture
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or $env:GITHUB_ACTIONS -ne 'true') {
    throw 'Installed media fixtures are restricted to disposable Windows CI installations.'
}
$ReleaseRoot = (Resolve-Path -LiteralPath $ReleaseRoot).Path
Import-Module (Join-Path $ReleaseRoot 'runtime/Native-Probe.psm1') -Force
$node = Join-Path $ReleaseRoot 'runtime/node/node.exe'
$sharpLib = Join-Path $ReleaseRoot 'server/node_modules/@img/sharp-win32-x64/lib'
$vcRuntime = Join-Path $ReleaseRoot 'runtime/vc-runtime'
$probe=@'
const { createRequire } = require('node:module');
const path = require('node:path');
(async () => {
  const root = process.argv[1];
  const fixtures = process.argv.slice(2);
  const req = createRequire(path.join(root, 'package.json'));
  const sharp = req('sharp');
  console.log(`sharp ${sharp.versions.sharp}, libvips ${sharp.versions.vips}`);
  for (const fixture of fixtures) {
    const metadata = await sharp(fixture).metadata();
    await sharp(fixture).resize({ width: 64, height: 64, fit: 'inside' }).jpeg().toBuffer();
    console.log(`sharp fixture OK: ${fixture} ${metadata.format} ${metadata.width}x${metadata.height}`);
  }
})().catch((error) => { console.error(error); process.exit(1); });
'@
$previousPath = $env:PATH
try {
    $env:PATH = (@($sharpLib,$vcRuntime,(Split-Path $node),$previousPath) | Where-Object { $_ }) -join ';'
    Invoke-ImmichNativeProbe -FilePath $node -ArgumentList (@('-e',$probe,(Join-Path $ReleaseRoot 'server')) + $Fixture) -ProbeName 'Installed Sharp/libvips fixture test' | Write-Host
} finally { $env:PATH = $previousPath }
