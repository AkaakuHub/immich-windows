#requires -Version 7.0
[CmdletBinding()]
param([string]$Destination)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'build\Common.psm1') -Force
Import-Module (Join-Path $root 'runtime\Common.psm1') -Force
$version = Get-WindowsReleaseVersion (Read-JsonFile (Join-Path $root 'upstream.json'))
if (-not $Destination) { $Destination = Join-Path $root "dist\immich-windows-$version-migration-tools.zip" }
$Destination = [IO.Path]::GetFullPath($Destination)
New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force }

$files = @(
    Get-Item -LiteralPath (Join-Path $root 'migration\Export-WslDatabase.ps1')
    Get-Item -LiteralPath (Join-Path $root 'migration\Export-WslDatabase.cmd')
    Get-Item -LiteralPath (Join-Path $root 'docs\install.md')
    Get-Item -LiteralPath (Join-Path $root 'docs\migration.md')
    Get-Item -LiteralPath (Join-Path $root 'docs\operations.md')
)
$archive = [IO.Compression.ZipFile]::Open($Destination, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($file in $files) {
        $entry = [IO.Path]::GetRelativePath($root, $file.FullName).Replace('\', '/')
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $entry, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
} finally { $archive.Dispose() }

Write-Host "Migration tools archive: $Destination"
