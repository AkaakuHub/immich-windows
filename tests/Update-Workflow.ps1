#requires -Version 7.0
# Isolated orchestration tests: all external processes and database operations are stubs.
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$base=Join-Path ([IO.Path]::GetTempPath()) ('immich-update-tests-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $base | Out-Null
$installStub=@'
param($PackageRoot,$Scope,$EnvFile,$InstallRoot,$DataRoot,$PostgresRoot,$PostgresService,[switch]$ReuseServices,[switch]$PrepareOnly,[switch]$ResumeExistingRelease,[switch]$DoNotStart)
if ($PrepareOnly) {
  Add-Content $env:IMMICH_TEST_EVENTS 'prepare'
  if ($env:IMMICH_TEST_FAIL -eq 'prepare') { throw 'Injected prepare failure' }
  if ($env:IMMICH_TEST_FAIL -eq 'prepare-exit') { exit 7 }
  $candidate=Join-Path $InstallRoot 'releases/v3.2.2.1'
  New-Item -ItemType Directory $candidate -Force | Out-Null
  Copy-Item (Join-Path $PackageRoot '*') $candidate -Recurse -Force
  return
}
Add-Content $env:IMMICH_TEST_EVENTS 'install'
if ($env:IMMICH_TEST_FAIL -eq 'install') { throw 'Injected install failure' }
if ($env:IMMICH_TEST_FAIL -eq 'install-exit') { exit 7 }
[IO.Directory]::Delete((Join-Path $InstallRoot 'current'))
New-Item -ItemType $(if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }) (Join-Path $InstallRoot 'current') -Target (Join-Path $InstallRoot 'releases/v3.2.2.1') | Out-Null
'@
try {
 foreach ($mode in @('success','same-payload','same-payload-start','prepare','prepare-exit','stop-exit','backup','backup-exit','install','install-exit','start','start-exit','smoke','smoke-exit')) {
  $case=Join-Path $base $mode
  $root=Join-Path $case install
  $data=Join-Path $case data
  $pkg=Join-Path $case package
  $old=Join-Path $root releases/v3.2.2
  foreach ($dir in @("$pkg/installer","$pkg/runtime/launchers","$pkg/migration","$pkg/tests","$old/runtime/launchers",$data)) { New-Item -ItemType Directory $dir -Force|Out-Null }
  $env:IMMICH_TEST_EVENTS=Join-Path $case events
  $env:IMMICH_TEST_FAIL=$mode
  Copy-Item "$repo/packaging/Update.ps1" "$pkg/installer/Update.ps1"
  $common=Get-Content -Raw "$repo/runtime/Common.psm1"
  $common+="`nfunction Start-ImmichTray {param(`$InstallRoot,`$DataRoot,`$Scope)} `nfunction Assert-Administrator {} `nfunction Protect-ImmichDataRoot {param(`$Path)}`nExport-ModuleMember -Function *`n"
  if ($mode -like 'same-payload*') { $common += "`nfunction Test-ImmichDatabasePayloadEqual {param(`$PreviousRelease,`$CandidateRelease) return `$true}`nExport-ModuleMember -Function *`n" }
  Set-Content "$pkg/runtime/Common.psm1" $common
  Set-Content "$pkg/installer/Install.ps1" $installStub
  Set-Content "$pkg/installer/Test-ReleasePackage.ps1" 'param($PackageRoot)'
  Set-Content "$pkg/runtime/launchers/Start-Immich.ps1" 'param($EnvFile,$InstallRoot,$DataRoot,[switch]$UpgradeInProgress); if (-not $UpgradeInProgress) { throw "Missing controlled startup flag" }; Assert-ImmichStartupAllowed -EnvFile $EnvFile -InstallRoot $InstallRoot -UpgradeInProgress; Add-Content $env:IMMICH_TEST_EVENTS start; if ($env:IMMICH_TEST_FAIL -in @("start","same-payload-start")) { throw "Injected start failure" }; if ($env:IMMICH_TEST_FAIL -eq "start-exit") { exit 7 }'
  Set-Content "$old/runtime/launchers/Stop-Immich.ps1" 'param($EnvFile,$InstallRoot,$DataRoot); Add-Content $env:IMMICH_TEST_EVENTS stop; if ($env:IMMICH_TEST_FAIL -eq "stop-exit") { exit 7 }'
  Copy-Item "$old/runtime/launchers/Stop-Immich.ps1" "$pkg/runtime/launchers/Stop-Immich.ps1"
  Set-Content "$pkg/tests/Smoke-Windows.ps1" 'param($InstallRoot,$DataRoot,$PostgresRoot); Add-Content $env:IMMICH_TEST_EVENTS smoke; if ($env:IMMICH_TEST_FAIL -eq "smoke") { throw "Injected smoke failure" }; if ($env:IMMICH_TEST_FAIL -eq "smoke-exit") { exit 7 }'
  Set-Content "$pkg/migration/New-DatabaseBackup.ps1" 'param($EnvFile,$PostgresRoot); Add-Content $env:IMMICH_TEST_EVENTS backup; if ($env:IMMICH_TEST_FAIL -eq "backup") { throw "Injected backup failure" }; if ($env:IMMICH_TEST_FAIL -eq "backup-exit") { exit 7 }; $path=Join-Path (Split-Path $EnvFile) backup.dump; Set-Content $path dump; return $path'
  '{"schemaVersion":1,"immichVersion":"v3.2.2"}'|Set-Content "$old/manifest.json"
  '{"schemaVersion":2,"immichVersion":"v3.2.2","windowsRevision":1,"packageVersion":"v3.2.2.1"}'|Set-Content "$pkg/manifest.json"
  "IMMICH_WINDOWS_INSTALL_SCOPE=AllUsers`nDB_PASSWORD=test"|Set-Content "$data/immich.env"
  New-Item -ItemType $(if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }) "$root/current" -Target $old|Out-Null
  $thrown=$false
  $global:LASTEXITCODE=13
  try { & "$pkg/installer/Update.ps1" -PackageRoot $pkg -InstallRoot $root -DataRoot $data -Scope AllUsers } catch { $thrown=$true; Write-Host $_.Exception.Message }
  $state=Get-Content -Raw "$data/state/upgrade-recovery.json"|ConvertFrom-Json
  $events=@(Get-Content $env:IMMICH_TEST_EVENTS)
  if ($mode -eq 'success') {
   if ($thrown -or $LASTEXITCODE -ne 0 -or $state.status -ne 'qualified' -or ($events -join ',') -ne 'prepare,stop,backup,install,start,smoke') { throw "Success case failed: $($events -join ',') $($state.status)" }
  } elseif ($mode -eq 'same-payload') {
   if ($thrown -or $state.status -ne 'qualified' -or $state.databaseBackup -or ($events -join ',') -ne 'prepare,stop,install,start,smoke') { throw 'Identical payload update performed an unnecessary DB dump.' }
  } elseif ($mode -eq 'same-payload-start') {
   if (-not $thrown -or $state.status -ne 'failed' -or $events[-1] -ne 'stop' -or $state.databaseBackup -or -not $state.databaseUnchanged) { throw 'App-only failure lost recovery classification.' }
  } elseif ($mode -in @('prepare','prepare-exit')) {
   if (-not $thrown -or $state.status -ne 'preparation-failed' -or ($events -join ',') -ne 'prepare') { throw 'Preparation failure stopped or changed the old instance.' }
  } elseif ($mode -in @('backup','backup-exit','stop-exit')) {
   if (-not $thrown -or $state.status -ne 'backup-failed' -or $events -contains 'install') { throw 'Failed backup allowed installation.' }
  } else {
   if (-not $thrown -or $state.status -ne 'failed' -or $events[-1] -ne 'stop' -or -not $state.databaseBackup) { throw "Failed update did not stay stopped with recovery state: $mode" }
  }
  Write-Host "PASS update state machine: $mode"
 }
} finally { Remove-Item -LiteralPath $base -Recurse -Force }
& (Join-Path $PSScriptRoot 'Installer-Safety.ps1')
