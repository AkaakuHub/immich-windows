#requires -Version 7.0
# Isolated orchestration tests: all external processes and database operations are stubs.
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$base=Join-Path ([IO.Path]::GetTempPath()) ('immich-update-tests-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $base | Out-Null
$installStub=@'
param($PackageRoot,$Scope,$EnvFile,$InstallRoot,$DataRoot,$PostgresRoot,$PostgresService,[switch]$ReuseServices,[switch]$PrepareOnly,[switch]$ResumeExistingRelease,[switch]$DoNotStart,[scriptblock]$UpdateController)
Add-Content $env:IMMICH_TEST_COUNTS install
if (-not $UpdateController -or $PrepareOnly) { throw 'Update did not use one controlled installation.' }
Add-Content $env:IMMICH_TEST_EVENTS 'prepare'
if ($env:IMMICH_TEST_FAIL -eq 'prepare') { throw 'Injected prepare failure' }
if ($env:IMMICH_TEST_FAIL -eq 'prepare-exit') { exit 7 }
$candidate=Join-Path $InstallRoot 'releases/v3.2.2.1'
New-Item -ItemType Directory $candidate -Force | Out-Null
Copy-Item (Join-Path $PackageRoot '*') $candidate -Recurse -Force
$context=[pscustomobject]@{PackageRoot=$PackageRoot;Release=$candidate;PreviousRelease=(Get-CurrentReleaseTarget $InstallRoot);InstallRoot=$InstallRoot;DataRoot=$DataRoot;Scope=$Scope}
if ($env:IMMICH_TEST_FAIL -eq 'foreign-context') { $context.Release=Join-Path $InstallRoot foreign }
if ($env:IMMICH_TEST_FAIL -eq 'changed-manifest') { Add-Content (Join-Path $candidate manifest.json) ' ' }
if ($env:IMMICH_TEST_FAIL -eq 'skip-controller') { return }
& $UpdateController 'Prepared' $context | Out-Null
if ($env:IMMICH_TEST_FAIL -eq 'callback-replay') { & $UpdateController 'Prepared' $context | Out-Null }
if ($env:IMMICH_TEST_FAIL -eq 'classify-fail') { throw 'Injected classification failure' }
Add-Content $env:IMMICH_TEST_COUNTS compare
$equal=Test-ImmichDatabasePayloadEqual -PreviousRelease $context.PreviousRelease -CandidateRelease $candidate
& $UpdateController 'DatabaseCompared' $context ([bool]$equal) | Out-Null
Add-Content $env:IMMICH_TEST_EVENTS 'install'
if ($env:IMMICH_TEST_FAIL -eq 'install') { throw 'Injected install failure' }
if ($env:IMMICH_TEST_FAIL -eq 'install-exit') { exit 7 }
[IO.Directory]::Delete((Join-Path $InstallRoot 'current'))
New-Item -ItemType $(if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }) (Join-Path $InstallRoot 'current') -Target $candidate | Out-Null
'@
try {
 foreach ($mode in @('success','sharp-cleanup-fail','cleanup-fail','tray-stop-fail','tray-start-fail','same-payload','same-payload-start','foreign-context','changed-manifest','callback-replay','skip-controller','classify-fail','stop-mutates','prepare','prepare-exit','stop-exit','backup','backup-exit','install','install-exit','start','start-exit','smoke','smoke-exit')) {
  $case=Join-Path $base $mode
  $root=Join-Path $case install
  $data=Join-Path $case data
  $pkg=Join-Path $case package
  $old=Join-Path $root releases/v3.2.2
  foreach ($dir in @("$pkg/installer","$pkg/runtime/launchers","$pkg/migration","$pkg/tests","$old/runtime/launchers",$data)) { New-Item -ItemType Directory $dir -Force|Out-Null }
  $env:IMMICH_TEST_EVENTS=Join-Path $case events
  $env:IMMICH_TEST_COUNTS=Join-Path $case counts
  $env:IMMICH_TEST_FAIL=$mode
  Copy-Item "$repo/packaging/Update.ps1" "$pkg/installer/Update.ps1"
  $common=Get-Content -Raw "$repo/runtime/Common.psm1"
  $common+="`nfunction Stop-ImmichTray {param(`$InstallRoot,`$ReleasePath); Add-Content `$env:IMMICH_TEST_COUNTS tray-stop; if (`$env:IMMICH_TEST_FAIL -eq 'tray-stop-fail') { throw 'Injected tray stop failure' }} `nfunction Start-ImmichTray {param(`$InstallRoot,`$DataRoot,`$Scope); Add-Content `$env:IMMICH_TEST_COUNTS tray-start; if (`$env:IMMICH_TEST_FAIL -eq 'tray-start-fail') { throw 'Injected tray start failure' }} `nfunction Assert-Administrator {} `nfunction Protect-ImmichDataRoot {param(`$Path)}`nExport-ModuleMember -Function *`n"
  if ($mode -eq 'stop-mutates') { $common += "`nfunction Test-ImmichDatabasePayloadEqual {param(`$PreviousRelease,`$CandidateRelease) return -not (Test-Path (Join-Path `$PreviousRelease changed-during-stop))}`nExport-ModuleMember -Function *`n" }
  if ($mode -like 'same-payload*') { $common += "`nfunction Test-ImmichDatabasePayloadEqual {param(`$PreviousRelease,`$CandidateRelease) return `$true}`nExport-ModuleMember -Function *`n" }
  Set-Content "$pkg/runtime/Common.psm1" $common
  Set-Content "$pkg/installer/Install.ps1" $installStub
  Set-Content "$pkg/installer/Remove-ObsoleteReleases.ps1" 'function Remove-ImmichObsoleteReleases {param($InstallRoot,$DataRoot,$CurrentReleasePath,$PreviousReleasePath,$EnvFile); if ((Get-Content -Raw (Join-Path $DataRoot "state/upgrade-recovery.json")|ConvertFrom-Json).status -ne "qualified") { throw "Cleanup ran before qualification" }; Add-Content $env:IMMICH_TEST_COUNTS cleanup; if ($env:IMMICH_TEST_FAIL -eq "cleanup-fail") { throw "Injected cleanup failure" }}'
  Set-Content "$pkg/installer/Test-ReleasePackage.ps1" 'param($PackageRoot)'
  Set-Content "$pkg/runtime/launchers/Start-Immich.ps1" 'param($EnvFile,$InstallRoot,$DataRoot,[switch]$UpgradeInProgress); if (-not $UpgradeInProgress) { throw "Missing controlled startup flag" }; Assert-ImmichStartupAllowed -EnvFile $EnvFile -InstallRoot $InstallRoot -UpgradeInProgress; Add-Content $env:IMMICH_TEST_EVENTS start; if ($env:IMMICH_TEST_FAIL -in @("start","same-payload-start")) { throw "Injected start failure" }; if ($env:IMMICH_TEST_FAIL -eq "start-exit") { exit 7 }'
  Set-Content "$old/runtime/launchers/Stop-Immich.ps1" 'param($EnvFile,$InstallRoot,$DataRoot); Add-Content $env:IMMICH_TEST_EVENTS stop; if ($env:IMMICH_TEST_FAIL -eq "stop-mutates") { Set-Content (Join-Path (Get-CurrentReleaseTarget $InstallRoot) changed-during-stop) changed }; if ($env:IMMICH_TEST_FAIL -eq "stop-exit") { exit 7 }'
  Copy-Item "$old/runtime/launchers/Stop-Immich.ps1" "$pkg/runtime/launchers/Stop-Immich.ps1"
  Set-Content "$pkg/tests/Smoke-Windows.ps1" 'param($InstallRoot,$DataRoot,$PostgresRoot); Add-Content $env:IMMICH_TEST_EVENTS smoke; if ($env:IMMICH_TEST_FAIL -eq "smoke") { throw "Injected smoke failure" }; if ($env:IMMICH_TEST_FAIL -eq "smoke-exit") { exit 7 }'
  if ($mode -eq 'sharp-cleanup-fail') {
   Add-Content "$pkg/tests/Smoke-Windows.ps1" 'New-Item -ItemType Directory (Join-Path $InstallRoot "current/.dependency-backups/sharp") -Force | Out-Null; $global:IMMICH_TEST_SHARP_LOCK=[IO.File]::Open((Join-Path $InstallRoot "current/.dependency-backups/sharp/locked.dll"),[IO.FileMode]::Create,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)'
  }
  Set-Content "$pkg/migration/New-DatabaseBackup.ps1" 'param($EnvFile,$PostgresRoot); Add-Content $env:IMMICH_TEST_EVENTS backup; if ($env:IMMICH_TEST_FAIL -eq "backup") { throw "Injected backup failure" }; if ($env:IMMICH_TEST_FAIL -eq "backup-exit") { exit 7 }; $path=Join-Path (Split-Path $EnvFile) backup.dump; Set-Content $path dump; return $path'
  '{"schemaVersion":1,"immichVersion":"v3.2.2"}'|Set-Content "$old/manifest.json"
  '{"schemaVersion":2,"immichVersion":"v3.2.2","windowsRevision":1,"packageVersion":"v3.2.2.1"}'|Set-Content "$pkg/manifest.json"
  "IMMICH_WINDOWS_INSTALL_SCOPE=AllUsers`nDB_PASSWORD=test"|Set-Content "$data/immich.env"
  New-Item -ItemType $(if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }) "$root/current" -Target $old|Out-Null
  $thrown=$false
  $global:LASTEXITCODE=13
  try { & "$pkg/installer/Update.ps1" -PackageRoot $pkg -InstallRoot $root -DataRoot $data -Scope AllUsers } catch { $thrown=$true; Write-Host $_.Exception.Message }
  if ($mode -eq 'sharp-cleanup-fail' -and $global:IMMICH_TEST_SHARP_LOCK) { $global:IMMICH_TEST_SHARP_LOCK.Dispose(); $global:IMMICH_TEST_SHARP_LOCK=$null }
  $state=Get-Content -Raw "$data/state/upgrade-recovery.json"|ConvertFrom-Json
  $events=@(Get-Content $env:IMMICH_TEST_EVENTS)
  $counts=@(Get-Content $env:IMMICH_TEST_COUNTS)
  if (@($counts|Where-Object {$_ -eq 'install'}).Count -ne 1) { throw 'Repeated installer invocation.' }
  if (@($counts|Where-Object {$_ -eq 'compare'}).Count -gt 1) { throw 'Repeated DB payload comparison.' }
  if ($mode -in @('success','sharp-cleanup-fail','stop-mutates','cleanup-fail','tray-stop-fail','tray-start-fail')) {
   if ($thrown -or $LASTEXITCODE -ne 0 -or $state.status -ne 'qualified' -or ($events -join ',') -ne 'prepare,stop,backup,install,start,smoke') { throw "Success case failed: $($events -join ',') $($state.status)" }
  } elseif ($mode -eq 'same-payload') {
   if ($thrown -or $state.status -ne 'qualified' -or $state.databaseBackup -or ($events -join ',') -ne 'prepare,stop,install,start,smoke') { throw 'Identical payload update performed an unnecessary DB dump.' }
  } elseif ($mode -eq 'same-payload-start') {
   if (-not $thrown -or $state.status -ne 'failed' -or $events[-1] -ne 'stop' -or $state.databaseBackup -or -not $state.databaseUnchanged) { throw 'App-only failure lost recovery classification.' }
  } elseif ($mode -in @('prepare','prepare-exit','foreign-context','changed-manifest','skip-controller')) {
   if (-not $thrown -or $state.status -ne 'preparation-failed' -or ($events -join ',') -ne 'prepare') { throw 'Preparation failure stopped or changed the old instance.' }
  } elseif ($mode -in @('backup','backup-exit','stop-exit','classify-fail','callback-replay')) {
   if (-not $thrown -or $state.status -ne 'backup-failed' -or $events -contains 'install') { throw 'Failed backup allowed installation.' }
  } else {
   if (-not $thrown -or $state.status -ne 'failed' -or $events[-1] -ne 'stop' -or -not $state.databaseBackup) { throw "Failed update did not stay stopped with recovery state: $mode" }
  }
  if (($counts -contains 'cleanup') -ne ($mode -in @('success','same-payload','stop-mutates','cleanup-fail','tray-start-fail'))) { throw "Wrong cleanup timing: $mode" }
  $trayEvents=@($counts | Where-Object {$_ -in @('tray-stop','cleanup','tray-start')}) -join ','
  $expectedTray=if ($state.status -ne 'qualified') { '' } elseif ($mode -eq 'tray-stop-fail') { 'tray-stop' } elseif ($mode -eq 'sharp-cleanup-fail') { 'tray-stop,tray-start' } else { 'tray-stop,cleanup,tray-start' }
  if ($trayEvents -ne $expectedTray) { throw "Tray lifecycle order was incorrect for ${mode}: $trayEvents" }
  Write-Host "PASS update state machine: $mode"
 }
} finally { Remove-Item -LiteralPath $base -Recurse -Force }
& (Join-Path $PSScriptRoot 'Installer-Safety.ps1')

& (Join-Path $PSScriptRoot 'Prepared-Install.ps1')
& (Join-Path $PSScriptRoot 'Runtime-Staging.ps1')
& (Join-Path $PSScriptRoot 'Runtime-Staging.ps1') -ForceCrossVolumeFallback
if ($IsWindows) { & (Join-Path $PSScriptRoot 'Runtime-Staging.ps1') -ForceNativeCrossDeviceError }
& (Join-Path $PSScriptRoot 'Runtime-Staging.ps1') -ForceMovePermissionError

& (Join-Path $PSScriptRoot 'Runtime-Staging.ps1') -ReuseInstalled
