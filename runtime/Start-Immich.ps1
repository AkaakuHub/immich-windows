[CmdletBinding()]
param(
    [int]$TimeoutSeconds = 120,
    [string]$EnvFile = (Join-Path $env:LOCALAPPDATA 'Immich\immich.env'),
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\Immich'),
    [string]$DataRoot = (Join-Path $env:LOCALAPPDATA 'Immich')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$loader = Join-Path $PSScriptRoot 'Load-ImmichEnv.ps1'
if (Test-Path -LiteralPath $EnvFile) {
    . $loader -EnvFile $EnvFile
}

$redisMode = if ($env:IMMICH_WINDOWS_REDIS_MODE) { $env:IMMICH_WINDOWS_REDIS_MODE } else { 'BundledValkey' }
if ($env:IMMICH_WINDOWS_INSTALL_SCOPE -eq 'CurrentUser') {
    $current = (Resolve-Path -LiteralPath (Join-Path $InstallRoot 'current')).Path
    $services = Join-Path $DataRoot 'services'
    New-Item -ItemType Directory -Path $services -Force | Out-Null
    $sharpLib = Join-Path $current 'server\node_modules\@img\sharp-win32-x64\lib'
    if (-not (Test-Path -LiteralPath $sharpLib -PathType Container)) { throw "Sharp runtime is missing: $sharpLib" }
    $env:PATH = (@($sharpLib,(Join-Path $current 'runtime\vc-runtime'),(Join-Path $current 'runtime\node'),(Join-Path $current 'runtime\ffmpeg'),$env:PATH) | Where-Object { $_ }) -join ';'
    $env:FFMPEG_PATH = Join-Path $current 'runtime\ffmpeg\ffmpeg.exe'
    $env:FFPROBE_PATH = Join-Path $current 'runtime\ffmpeg\ffprobe.exe'
    if ($redisMode -eq 'BundledValkey') {
        $valkey = Join-Path $current 'dependencies\valkey\valkey-server.exe'
        $valkeyConfig = Join-Path $DataRoot 'valkey.conf'
        if ($valkeyConfig -notmatch '^([A-Za-z]):[\\/](.*)$') { throw "Valkey requires a drive path for its config: $valkeyConfig" }
        $valkeyConfigPath = '/cygdrive/' + $Matches[1].ToLowerInvariant() + '/' + $Matches[2].Replace('\','/')
        $valkeyProcess = Start-Process -FilePath $valkey -ArgumentList ('"{0}"' -f $valkeyConfigPath) -WorkingDirectory (Split-Path $valkey) -PassThru -WindowStyle Hidden
        $valkeyProcess.Id | Set-Content -LiteralPath (Join-Path $services 'ImmichValkey.pid')
    }
    $node = Join-Path $current 'runtime\node\node.exe'
    $serverEntry = Join-Path $current 'server\dist\main.js'
    $serverProcess = Start-Process -FilePath $node -ArgumentList ('"{0}"' -f $serverEntry) -WorkingDirectory $current -PassThru -WindowStyle Hidden
    $serverProcess.Id | Set-Content -LiteralPath (Join-Path $services 'ImmichServer.pid')
    $python = Get-ChildItem (Join-Path $current 'machine-learning\python-runtime') -Filter python.exe -File -Recurse | Where-Object { $_.FullName -notmatch '\\Scripts\\' } | Select-Object -First 1
    if (-not $python) { throw 'Packaged machine-learning Python runtime not found.' }
    $serverPort = $env:IMMICH_PORT
    $env:IMMICH_HOST = '127.0.0.1'
    $mlPort = if ($env:IMMICH_PORT_ML) { [int]$env:IMMICH_PORT_ML } else { 3003 }
    $env:IMMICH_PORT = [string]$mlPort
    $mlProcess = Start-Process -FilePath $python.FullName -ArgumentList @('-m','immich_ml') -WorkingDirectory (Join-Path $current 'machine-learning') -PassThru -WindowStyle Hidden
    $env:IMMICH_PORT = $serverPort
    $mlProcess.Id | Set-Content -LiteralPath (Join-Path $services 'ImmichMachineLearning.pid')
} elseif ($env:IMMICH_WINDOWS_INSTALL_SCOPE -eq 'AllUsers') {
    if ($redisMode -eq 'BundledValkey') {
    if (-not (Get-Service -Name ImmichValkey -ErrorAction SilentlyContinue)) {
        throw 'IMMICH_WINDOWS_REDIS_MODE=BundledValkey but the ImmichValkey service is not installed.'
    }
    Start-Service ImmichValkey
    } elseif ($redisMode -ne 'External') {
        throw "Unsupported IMMICH_WINDOWS_REDIS_MODE: $redisMode"
    }
    foreach ($serviceName in @('ImmichMachineLearning', 'ImmichServer')) {
        if (-not (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)) {
            throw "Required Windows service is not installed: $serviceName"
        }
        Start-Service $serviceName
    }
} else {
    throw "Unsupported IMMICH_WINDOWS_INSTALL_SCOPE: $($env:IMMICH_WINDOWS_INSTALL_SCOPE)"
}

$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$serverPort = if ($env:IMMICH_PORT) { [int]$env:IMMICH_PORT } else { 2283 }
$mlPort = if ($env:IMMICH_PORT_ML) { [int]$env:IMMICH_PORT_ML } else { 3003 }
while ([DateTime]::UtcNow -lt $deadline) {
    try {
        if ($env:IMMICH_WINDOWS_INSTALL_SCOPE -eq 'CurrentUser') {
            foreach ($name in @('ImmichServer','ImmichMachineLearning')) {
                $pidFile = Join-Path $DataRoot "services\$name.pid"
                if (-not (Test-Path -LiteralPath $pidFile) -or -not (Get-Process -Id ([int](Get-Content -Raw -LiteralPath $pidFile)) -ErrorAction SilentlyContinue)) {
                    throw "CurrentUser process $name exited during startup."
                }
            }
        }
        $ml = Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:$mlPort/ping" -TimeoutSec 3
        $server = Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:$serverPort/api/server/ping" -TimeoutSec 3
        if ($ml.StatusCode -eq 200 -and $server.StatusCode -eq 200) {
            Write-Host "Immich Server and ML are healthy (Redis mode: $redisMode)."
            exit 0
        }
    } catch {}
    Start-Sleep 2
}

throw "Immich health checks did not become ready within $TimeoutSeconds seconds (Redis mode: $redisMode)."
