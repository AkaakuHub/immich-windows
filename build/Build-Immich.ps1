[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Source,
    [string]$Destination
)
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
Assert-WindowsX64
$root = Get-RepositoryRoot
$versions = Read-JsonFile (Join-Path $root 'dependencies\versions.json')
$upstream = Read-JsonFile (Join-Path $root 'upstream.json')
if (-not $Destination) { $Destination = Join-Path $root 'artifacts\application' }
$Destination = New-CleanDirectory $Destination

Assert-Command node | Out-Null
Assert-Command corepack | Out-Null
Assert-Command pnpm | Out-Null
Assert-Command extism-js | Out-Null
Assert-Command wasm-opt | Out-Null
Assert-Command wasm-merge | Out-Null

$nodeVersion = (& node --version).Trim().TrimStart('v')
if ($nodeVersion -ne $versions.node.version) {
    throw "Node version mismatch. Immich $($upstream.version) pins $($versions.node.version); found $nodeVersion."
}
$pnpmVersion = (& pnpm --version).Trim()
if ($pnpmVersion -ne $versions.pnpm.version) {
    throw "pnpm version mismatch. Immich $($upstream.version) pins $($versions.pnpm.version); found $pnpmVersion."
}

$env:NODE_OPTIONS = '--max-old-space-size=4096'
$env:SHARP_IGNORE_GLOBAL_LIBVIPS = 'true'
$env:CI = '1'

$filters = @(
    '--filter','@immich/sdk',
    '--filter','@immich/plugin-sdk',
    '--filter','@immich/plugin-core',
    '--filter','@immich/cli',
    '--filter','immich',
    '--filter','immich-web'
)
Invoke-Native pnpm ($filters + @('install','--frozen-lockfile')) $Source
Invoke-Native pnpm @('--filter','@immich/sdk','--filter','@immich/plugin-sdk','--filter','immich','build') $Source
Invoke-Native pnpm @('--filter','@immich/sdk','--filter','immich-web','build') $Source
Invoke-Native pnpm @('--filter','@immich/sdk','--filter','@immich/plugin-sdk','--filter','@immich/plugin-core','build') $Source
Invoke-Native pnpm @('--filter','@immich/sdk','--filter','@immich/cli','build') $Source

$serverOut = Join-Path $Destination 'server'
$cliOut = Join-Path $Destination 'cli'
Invoke-Native pnpm @('--filter','immich','--prod','deploy',$serverOut) $Source
Invoke-Native pnpm @('--filter','@immich/cli','--prod','--no-optional','deploy',$cliOut) $Source
$pluginSdk = Join-Path $serverOut '.immich\plugin-sdk'
New-Item -ItemType Directory -Path $pluginSdk -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $Source 'packages\plugin-sdk\package.json') -Destination $pluginSdk -Force
Copy-Item -LiteralPath (Join-Path $Source 'packages\plugin-sdk\plugin-sdk.mjs') -Destination $pluginSdk -Force
Copy-Directory (Join-Path $Source 'packages\plugin-sdk\dist') (Join-Path $pluginSdk 'dist')
$buildOut = Join-Path $Destination 'build'
Copy-Directory (Join-Path $Source 'web\build') (Join-Path $buildOut 'www')
$pluginOut = Join-Path $buildOut 'plugins\immich-plugin-core'
New-Item -ItemType Directory -Force -Path $pluginOut | Out-Null
Copy-Directory (Join-Path $Source 'packages\plugin-core\dist') (Join-Path $pluginOut 'dist')
Copy-Item -LiteralPath (Join-Path $Source 'packages\plugin-core\manifest.json') -Destination $pluginOut -Force
Copy-Item -LiteralPath (Join-Path $Source 'LICENSE') -Destination (Join-Path $Destination 'LICENSE') -Force

& (Join-Path $PSScriptRoot 'Fetch-Geodata.ps1') -Destination (Join-Path $buildOut 'geodata')

Write-BuildLock -Path (Join-Path $buildOut 'build-lock.json') -Versions $versions

$commit = (& git -C $Source rev-parse HEAD).Trim()
$manifest = [ordered]@{
    immichVersion = $upstream.version
    upstreamCommit = $commit
    node = $nodeVersion
    pnpm = $pnpmVersion
    builtAtUtc = [DateTime]::UtcNow.ToString('o')
    sharp = 'upstream Windows optional dependency; custom libvips replacement is a separate build stage'
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 -LiteralPath (Join-Path $Destination 'application-manifest.json')
Write-Host "Application build staged at $Destination"
