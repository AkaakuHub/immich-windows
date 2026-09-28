[CmdletBinding()]
param([string]$Destination)
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
Assert-WindowsX64
$root = Get-RepositoryRoot
$v = (Read-JsonFile (Join-Path $root 'dependencies\versions.json')).node
if (-not $Destination) { $Destination = Join-Path $root 'artifacts\native\node' }
$cache = Join-Path $root ".cache\$($v.asset)"
$url = "https://nodejs.org/dist/v$($v.version)/$($v.asset)"
Get-CachedDownload -Uri $url -Destination $cache | Out-Null
$temp = Expand-ZipClean $cache (Join-Path $root '.work\node-runtime')
$inner = Get-ChildItem -LiteralPath $temp -Directory | Select-Object -First 1
if (-not $inner) { throw 'Unexpected Node archive layout.' }
$Destination = New-CleanDirectory $Destination
foreach ($name in @('node.exe','LICENSE')) {
    Copy-Item -LiteralPath (Join-Path $inner.FullName $name) -Destination $Destination -Force
}
Assert-FileExists (Join-Path $Destination 'node.exe') | Out-Null
$actual = (& (Join-Path $Destination 'node.exe') --version).Trim().TrimStart('v')
if ($actual -ne $v.version) { throw "Packaged Node version mismatch: $actual" }
Write-Host "Node runtime staged at $Destination"
