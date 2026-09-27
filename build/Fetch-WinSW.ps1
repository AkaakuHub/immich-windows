[CmdletBinding()]
param([string]$Destination)
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
Assert-WindowsX64
$root = Get-RepositoryRoot
$v = (Read-JsonFile (Join-Path $root 'dependencies\versions.json')).winsw
if (-not $Destination) { $Destination = Join-Path $root 'artifacts\native\winsw' }
$cache = Join-Path $root ".cache\winsw-$($v.version)\$($v.asset)"
$url = "https://github.com/winsw/winsw/releases/download/v$($v.version)/$($v.asset)"
Get-CachedDownload -Uri $url -Destination $cache | Out-Null
$Destination = New-CleanDirectory $Destination
$file = Join-Path $Destination $v.asset
Copy-Item -LiteralPath $cache -Destination $file
Assert-FileExists $file | Out-Null
Write-Host "WinSW staged at $Destination"
