#requires -Version 7.0
param([string]$EnvFile = 'C:\ProgramData\Immich\immich.env')
Import-Module (Join-Path $PSScriptRoot '..\Common.psm1') -Force
foreach ($entry in (Read-EnvFile $EnvFile).GetEnumerator()) {
    [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
}

$release = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$runtimePaths=@('server\node_modules\@img\sharp-win32-x64\lib','runtime\vc-runtime','runtime\node','runtime\ffmpeg') | ForEach-Object { Join-Path $release $_ }
$env:PATH=(@($runtimePaths)+@($env:PATH)) -join ';'
$env:FFMPEG_PATH=Join-Path $release 'runtime\ffmpeg\ffmpeg.exe'
$env:FFPROBE_PATH=Join-Path $release 'runtime\ffmpeg\ffprobe.exe'
