#requires -Version 7.0
param([switch]$ForceCrossVolumeFallback,[switch]$ForceNativeCrossDeviceError,[switch]$ForceMovePermissionError,[switch]$VerifyFfmpegChecksum,[switch]$RejectFfmpegChecksum)
# Tiny real ZIPs exercise disposable stage promotion; no network or native tools.
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$base=Join-Path ([IO.Path]::GetTempPath()) ('runtime-staging-'+[guid]::NewGuid().ToString('N'))
function Check([bool]$Value,[string]$Message) { if (-not $Value) { throw $Message } }
function Write-Fixture([string]$Path,[string]$Text) { [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)); [IO.File]::WriteAllText($Path,$Text) }
$commands=@()
$moveHook=$null;$previousMoveHook=$false
$promotionCopies=[Collections.Generic.List[string]]::new()
try {
 $root=Join-Path $base install;$release=Join-Path $root 'releases/v3.2.2.2';$cache=Join-Path $root 'cache/downloads'
 [void][IO.Directory]::CreateDirectory($cache)
 $archives=@(
  @{Name='node-fixture.zip';Files=@{'node-fixture/node.exe'='node';'node-fixture/npm.cmd'='npm';'node-fixture/node_modules/npm/index.js'='package'}},
  @{Name='ffmpeg-fixture.zip';Files=@{'ffmpeg-fixture/bin/ffmpeg.exe'='ffmpeg';'ffmpeg-fixture/bin/ffprobe.exe'='ffprobe'}},
  @{Name='uv-0.12.18-uv-fixture.zip';Files=@{'uv.exe'='uv'}},
  @{Name='immich-windows-v3.2.2.2-native-dependencies.zip';Files=@{'dependencies/postgres-extensions/vector/vector.dll'='native';'unused/large.dll'='must not extract'}}
 )
 foreach ($archive in $archives) {
  $source=Join-Path $base $archive.Name
  foreach ($entry in $archive.Files.GetEnumerator()) { Write-Fixture (Join-Path $source $entry.Key) $entry.Value }
  [IO.Compression.ZipFile]::CreateFromDirectory($source,(Join-Path $cache $archive.Name))
 }
 $nativePath='dependencies/postgres-extensions/vector/vector.dll'
 $manifest=@{schemaVersion=2;target='windows-x64-native';immichVersion='v3.2.2';windowsRevision=2;packageVersion='v3.2.2.2';dependencies=@{
  node=@{version='24.15.0';asset='node-fixture.zip'};ffmpeg=@{version='7';asset='ffmpeg-fixture.zip'};valkey=@{version='1';asset='valkey.zip'};winsw=@{version='2';asset='WinSW-x64.exe'};uv=@{version='0.12.18';asset='uv-fixture.zip'};python=@{version='3.11.14'}
 };nativeDependencyFiles=@{};nativeDependenciesSha256=(Get-FileHash (Join-Path $cache $archives[-1].Name)).Hash}
 if ($VerifyFfmpegChecksum -or $RejectFfmpegChecksum) { $manifest.dependencies.ffmpeg.sha256 = if ($RejectFfmpegChecksum) { '0' * 64 } else { (Get-FileHash -Algorithm SHA256 (Join-Path $cache 'ffmpeg-fixture.zip')).Hash } }
 $manifest.nativeDependencyFiles[$nativePath]=(Get-FileHash (Join-Path (Join-Path $base $archives[-1].Name) $nativePath)).Hash
 Write-Fixture (Join-Path $release manifest.json) ($manifest|ConvertTo-Json -Depth 10)
 Write-Fixture (Join-Path $release 'runtime/Common.psm1') (Get-Content -Raw (Join-Path $repo 'runtime/Common.psm1'))
 Write-Fixture (Join-Path $release 'installer/Install-RuntimeDependencies.ps1') (Get-Content -Raw (Join-Path $repo 'packaging/Install-RuntimeDependencies.ps1'))
 Write-Fixture (Join-Path $release 'dependencies/valkey/ValkeyService.exe') 'existing valkey'
 Write-Fixture (Join-Path $release 'runtime/winsw/WinSW-x64.exe') 'existing winsw'
 $python=Join-Path $release 'machine-learning/python-runtime/cpython-3.11.14-windows-x86_64-none/python.exe'
 Write-Fixture $python python
 $node=Join-Path $release 'runtime/node/node.exe'
 Set-Item "function:global:$node" { $global:LASTEXITCODE=0; 'v24.15.0' };$commands+=$node
 Set-Item "function:global:$python" { $global:LASTEXITCODE=0; '3.11.14' };$commands+=$python
 function Invoke-WebRequest { throw 'A cached fixture unexpectedly attempted network access.' }
 function Copy-Item {
  [CmdletBinding()]param([Parameter(ValueFromPipeline,Position=0)]$Path,[string]$LiteralPath,[Parameter(Position=1)][string]$Destination,[switch]$Recurse,[switch]$Force)
  process {
   $source=if ($LiteralPath) {$LiteralPath} else {[string]$Path}
   if ($source -match 'runtime-extract') {
    if (-not $ForceNativeCrossDeviceError) { throw 'Disposable extraction was copied instead of promoted.' }
    $promotionCopies.Add($source)
   }
   Microsoft.PowerShell.Management\Copy-Item -LiteralPath $source -Destination $Destination -Recurse:$Recurse -Force:$Force
  }
 }
 if ($ForceNativeCrossDeviceError -or $ForceMovePermissionError) {
  function Move-Item {
   param($LiteralPath,$Destination)
   if ($LiteralPath -match 'runtime-extract') {
    if ($ForceMovePermissionError) { throw [UnauthorizedAccessException]::new('Injected move permission failure') }
    throw [IO.IOException]::new('Injected Windows cross-device move failure',-2147024879)
   }
   Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath -Destination $Destination
  }
 }
 if ($ForceCrossVolumeFallback) {
  $type=[psobject].Assembly.GetType('System.Management.Automation.Internal.InternalTestHooks')
  $moveHook=$type.GetField('ThrowExdevErrorOnMoveDirectory',[Reflection.BindingFlags]'Public,NonPublic,Static')
  if (-not $moveHook) { throw 'PowerShell cross-volume test hook is unavailable.' }
  $previousMoveHook=$moveHook.GetValue($null);$moveHook.SetValue($null,$true)
 }
 $failed=$false
 try { & (Join-Path $release 'installer/Install-RuntimeDependencies.ps1') -ReleaseRoot $release -InstallRoot $root } catch { $failed=$true; if (-not $ForceMovePermissionError -and -not $RejectFfmpegChecksum) { throw }; if ($RejectFfmpegChecksum) { Check ($_.Exception.Message -like '*checksum mismatch*') 'FFmpeg did not fail for its checksum.' } }
 if ($RejectFfmpegChecksum) {
  Check $failed 'Invalid FFmpeg checksum was accepted.'
  Check (-not (Test-Path (Join-Path $release 'runtime/ffmpeg/ffmpeg.exe'))) 'Unverified FFmpeg was extracted.'
  Write-Host 'PASS runtime staging: FFmpeg checksum mismatch rejected before extraction'
  return
 }
 if ($ForceMovePermissionError) {
  Check $failed 'Move permission failure was swallowed.'
  Check ($promotionCopies.Count -eq 0) 'Move permission failure caused an unsafe copy fallback.'
  Write-Host 'PASS runtime staging: permission failure stays failed, no copy fallback'
  return
 }
 foreach ($pair in @(@('runtime/node/node_modules/npm/index.js','package'),@('runtime/ffmpeg/ffmpeg.exe','ffmpeg'),@($nativePath,'native'))) {
  Check ((Get-Content -Raw (Join-Path $release $pair[0])) -ceq $pair[1]) "Promoted payload differs: $($pair[0])"
 }
 Check ((Get-Content -Raw (Join-Path $root 'tools/uv/0.12.18/uv.exe')) -ceq 'uv') 'uv extraction was not promoted.'
 Check (@(Get-ChildItem (Join-Path $root 'cache/runtime-extract') -Force).Count -eq 0) 'Disposable extraction trees remained.'
 foreach ($archive in $archives) { Check (Test-Path (Join-Path $cache $archive.Name)) 'Reusable download archive was removed.' }
 if ($ForceNativeCrossDeviceError) { Check ($promotionCopies.Count -gt 0) 'Native cross-device fallback was not exercised.' }
 Check (-not (Test-Path (Join-Path $release unused))) 'Unneeded native ZIP content was extracted.'
 Write-Host "PASS runtime staging: Node/FFmpeg/uv/native promotions, cached ZIP retention, no extraction copy or network (cross-volume fallback=$ForceCrossVolumeFallback)"
} finally {
 if ($moveHook) { $moveHook.SetValue($null,$previousMoveHook) }
 foreach ($command in $commands) { Remove-Item "function:global:$command" -ErrorAction SilentlyContinue }
 if (Test-Path $base) { Remove-Item -LiteralPath $base -Recurse -Force }
}
