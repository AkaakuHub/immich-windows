[CmdletBinding()]
param([string]$Destination)
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
Assert-WindowsX64
$root = Get-RepositoryRoot
$v = (Read-JsonFile (Join-Path $root 'dependencies\versions.json')).ffmpeg
if (-not $Destination) { $Destination = Join-Path $root 'artifacts\native\ffmpeg' }
$cache = Join-Path $root ".cache\$($v.asset)"
$url = "https://github.com/jellyfin/jellyfin-ffmpeg/releases/download/v$($v.version)/$($v.asset)"
Get-CachedDownload -Uri $url -Destination $cache | Out-Null
$temp = Expand-ZipClean $cache (Join-Path $root '.work\ffmpeg')
$ffmpeg = Get-ChildItem -LiteralPath $temp -Filter ffmpeg.exe -File -Recurse | Select-Object -First 1
$ffprobe = Get-ChildItem -LiteralPath $temp -Filter ffprobe.exe -File -Recurse | Select-Object -First 1
if (-not $ffmpeg -or -not $ffprobe) { throw 'Jellyfin FFmpeg archive did not contain ffmpeg.exe and ffprobe.exe.' }
$binDir = $ffmpeg.Directory.FullName
$Destination = New-CleanDirectory $Destination
Copy-Directory $binDir $Destination
Invoke-Native (Join-Path $Destination 'ffmpeg.exe') @('-version')
Invoke-Native (Join-Path $Destination 'ffprobe.exe') @('-version')
Write-Host "Jellyfin FFmpeg staged at $Destination"
