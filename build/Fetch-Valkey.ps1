[CmdletBinding()]
param([string]$Destination)
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
Assert-WindowsX64
$root = Get-RepositoryRoot
$v = (Read-JsonFile (Join-Path $root 'dependencies\versions.json')).valkey
if (-not $Destination) { $Destination = Join-Path $root 'artifacts\native\valkey' }
$cache = Join-Path $root ".cache\$($v.asset)"
$url = "https://github.com/valkey-windows/valkey-windows/releases/download/$($v.version)/$($v.asset)"
Get-CachedDownload -Uri $url -Destination $cache | Out-Null
$temp = Expand-ZipClean $cache (Join-Path $root '.work\valkey')
$Destination = New-CleanDirectory $Destination
$service = Get-ChildItem -LiteralPath $temp -Filter ValkeyService.exe -File -Recurse | Select-Object -First 1
$server = Get-ChildItem -LiteralPath $temp -Filter valkey-server.exe -File -Recurse | Select-Object -First 1
$cli = Get-ChildItem -LiteralPath $temp -Filter valkey-cli.exe -File -Recurse | Select-Object -First 1
if (-not $service -or -not $server -or -not $cli) { throw 'Valkey Windows archive layout is incomplete.' }
Copy-Directory $service.Directory.FullName $Destination
Invoke-Native (Join-Path $Destination 'ValkeyService.exe') @('--version')
Write-Host "Valkey runtime staged at $Destination"
