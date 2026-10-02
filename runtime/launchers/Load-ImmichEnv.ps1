#requires -Version 7.0
param(
    [string]$EnvFile = 'C:\ProgramData\Immich\immich.env',
    [ValidateSet('Server','MachineLearning')][string]$ServiceRole
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\Common.psm1') -Force
foreach ($entry in (Read-EnvFile $EnvFile).GetEnumerator()) {
    [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
}

if ($ServiceRole) {
    $installRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
    Assert-ImmichStartupAllowed -EnvFile $EnvFile -InstallRoot $installRoot -ServiceProcess
}

$release = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$runtimePaths=@('server\node_modules\@img\sharp-win32-x64\lib','runtime\vc-runtime','runtime\node','runtime\ffmpeg') | ForEach-Object { Join-Path $release $_ }
$env:PATH=(@($runtimePaths)+@($env:PATH)) -join ';'
$env:FFMPEG_PATH=Join-Path $release 'runtime\ffmpeg\ffmpeg.exe'
$env:FFPROBE_PATH=Join-Path $release 'runtime\ffmpeg\ffprobe.exe'

# WinSW runs this existing launcher in the foreground so env edits also apply at boot.
if ($ServiceRole -eq 'Server') {
    Set-Location -LiteralPath $release
    & (Join-Path $release 'runtime\node\node.exe') (Join-Path $release 'server\dist\main.js')
    exit $LASTEXITCODE
} elseif ($ServiceRole -eq 'MachineLearning') {
    $python = @(Get-ChildItem (Join-Path $release 'machine-learning\python-runtime') -Filter python.exe -File -Recurse | Where-Object { $_.FullName -notmatch '\\Scripts\\' })
    if ($python.Count -ne 1) { throw 'Expected exactly one packaged ML Python runtime.' }
    $env:IMMICH_HOST = if ($env:IMMICH_HOST_ML) { $env:IMMICH_HOST_ML } else { '127.0.0.1' }
    $env:IMMICH_PORT = if ($env:IMMICH_PORT_ML) { $env:IMMICH_PORT_ML } else { '3003' }
    $env:PYTHONPATH = Join-Path $release 'machine-learning\app'
    Set-Location -LiteralPath (Join-Path $release 'machine-learning')
    & $python[0].FullName -m immich_ml
    exit $LASTEXITCODE
}
