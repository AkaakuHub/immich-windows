#requires -Version 7.0
$ErrorActionPreference='Stop'
$script=Join-Path $PSScriptRoot '../migration/Remove-UpgradeDatabaseBackups.ps1'
$root=Join-Path ([IO.Path]::GetTempPath()) ('immich-backup-retention-'+[guid]::NewGuid().ToString('N'))
try {
    $directory=Join-Path $root 'database-backups/upgrades'
    New-Item -ItemType Directory -Path $directory,(Join-Path $root state) -Force | Out-Null
    $manual=Join-Path $root 'database-backups/immich-native-20260101-000000-0000000.dump'
    Set-Content -LiteralPath $manual manual
    $names=@(1..6 | ForEach-Object { 'immich-native-2026010{0}-000000-0000000.dump' -f $_ })
    foreach ($name in $names) { Set-Content -LiteralPath (Join-Path $directory $name) dump }
    Set-Content -LiteralPath (Join-Path $directory 'unrelated.dump') unrelated
    $stateFile=Join-Path $root 'state/upgrade-recovery.json'
    @{status='failed';databaseBackup=(Join-Path $directory $names[0])} | ConvertTo-Json | Set-Content -LiteralPath $stateFile
    $rejected=$false
    try { & $script -DataRoot $root } catch { $rejected=$true }
    if (-not $rejected -or @(Get-ChildItem -LiteralPath $directory -File).Count -ne 7) { throw 'Failed-update backups were not preserved.' }
    @{status='qualified';databaseBackup=(Join-Path $directory $names[0])} | ConvertTo-Json | Set-Content -LiteralPath $stateFile
    & $script -DataRoot $root
    $remaining=@(Get-ChildItem -LiteralPath $directory -File | Select-Object -ExpandProperty Name)
    if ($remaining.Count -ne 5 -or @($names[0],$names[3],$names[4],$names[5],'unrelated.dump' | Where-Object { $_ -notin $remaining }).Count) { throw 'Retention did not preserve the newest three and the recovery backup.' }
    if (-not (Test-Path -LiteralPath $manual)) { throw 'Manual or historical backup was removed.' }
    @{status='qualified';databaseBackup=(Join-Path $directory $names[5])} | ConvertTo-Json | Set-Content -LiteralPath $stateFile
    & $script -DataRoot $root
    if ((Test-Path -LiteralPath (Join-Path $directory $names[0])) -or @(Get-ChildItem -LiteralPath $directory -Filter 'immich-native-*.dump').Count -ne 3) { throw 'Obsolete recovery backup was retained indefinitely.' }
    & $script -DataRoot $root
    if (@(Get-ChildItem -LiteralPath $directory -File).Count -ne 4) { throw 'Repeated retention changed the retained set.' }
    Write-Host 'PASS upgrade backup retention: bounded automatic backups, recovery protection, manual backups and failed updates preserved.'
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
