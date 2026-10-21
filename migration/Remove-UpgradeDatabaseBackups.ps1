#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$DataRoot)

$ErrorActionPreference='Stop'
$data=[IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($DataRoot))
$state=Get-Content -Raw -LiteralPath (Join-Path $data 'state/upgrade-recovery.json') | ConvertFrom-Json
if ($state.status -ne 'qualified') { throw 'Only a qualified update may prune upgrade database backups.' }
$directory=Join-Path $data 'database-backups/upgrades'
foreach ($path in @($data,(Join-Path $data 'database-backups'),$directory)) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    $item=Get-Item -LiteralPath $path -Force
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Upgrade backup directory must not be a link.' }
}
$backups=@(Get-ChildItem -LiteralPath $directory -File -Force | Where-Object {
    $_.Name -cmatch '\Aimmich-native-\d{8}-\d{6}-\d{7}\.dump\z' -and
    -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)
} | Sort-Object Name -Descending)
$protected=if ($state.databaseBackup) { [IO.Path]::GetFullPath([string]$state.databaseBackup) } else { $null }
foreach ($file in ($backups | Select-Object -Skip 3)) {
    $full=[IO.Path]::GetFullPath($file.FullName)
    if ([IO.Path]::GetDirectoryName($full) -ine $directory) { throw 'Upgrade backup escaped its managed directory.' }
    if ($full -ieq $protected) { continue }
    Remove-Item -LiteralPath $full -Force
    Write-Host "Removed obsolete upgrade database backup: $($file.Name)"
}
