[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReleaseRoot,
    [Parameter(Mandatory)][string]$InstallRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$manifest = Get-Content -Raw -LiteralPath (Join-Path $ReleaseRoot 'manifest.json') | ConvertFrom-Json
$statePath = Join-Path $ReleaseRoot '.node-dependencies-installed.json'
$expectedState = [ordered]@{ immichVersion = $manifest.immichVersion; node = $manifest.dependencies.node.version; pnpm = $manifest.dependencies.pnpm.version }
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    $installedState = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
    if ($installedState.immichVersion -eq $expectedState.immichVersion -and $installedState.node -eq $expectedState.node -and
        $installedState.pnpm -eq $expectedState.pnpm -and
        (Test-Path -LiteralPath (Join-Path $ReleaseRoot 'server\node_modules') -PathType Container) -and
        (Test-Path -LiteralPath (Join-Path $ReleaseRoot 'cli\node_modules') -PathType Container) -and
        (Test-Path -LiteralPath (Join-Path $ReleaseRoot 'server\node_modules\@img\sharp-win32-x64\lib\libvips-core.dll'))) {
        Write-Host 'Pinned Node dependencies are already installed for this release.'
        return
    }
}
$nodeRoot = Join-Path $ReleaseRoot 'runtime\node'
$node = Join-Path $nodeRoot 'node.exe'
$npm = Join-Path $nodeRoot 'npm.cmd'
foreach ($required in @($node,$npm)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Node runtime is missing: $required" }
}

$pnpmVersion = [string]$manifest.dependencies.pnpm.version
$pnpmRoot = Join-Path $InstallRoot "tools\pnpm\$pnpmVersion"
$pnpmCli = Join-Path $pnpmRoot 'node_modules\pnpm\bin\pnpm.cjs'
$pnpm = $pnpmCli
if (-not (Test-Path -LiteralPath $pnpmCli -PathType Leaf)) {
    New-Item -ItemType Directory -Path $pnpmRoot -Force | Out-Null
    $env:npm_config_cache = Join-Path $InstallRoot 'cache\npm'
    & $npm install --prefix $pnpmRoot --no-save --no-audit --no-fund "pnpm@$pnpmVersion"
    if ($LASTEXITCODE -ne 0) { throw "Could not install pinned pnpm $pnpmVersion." }
}
if (-not (Test-Path -LiteralPath $pnpmCli -PathType Leaf)) { throw "Pinned pnpm package was not installed: $pnpmCli" }

$oldSharpIgnoreGlobal = $env:SHARP_IGNORE_GLOBAL_LIBVIPS
$oldNodePath = $env:NODE_PATH
$env:SHARP_IGNORE_GLOBAL_LIBVIPS = 'true'
$env:NODE_PATH = Join-Path $ReleaseRoot 'runtime'
$store = Join-Path $InstallRoot 'cache\pnpm-store'
function Set-BuildScriptPolicy([string]$Project) {
    $workspaceFile = Join-Path $Project 'pnpm-workspace.yaml'
    $original = [IO.File]::ReadAllText($workspaceFile)
    $updated = $original
    foreach ($policy in @(
        @{ pattern = "(?m)^(\s*'@scarf/scarf':\s*)set this to true or false\s*$"; value = 'false' },
        @{ pattern = '(?m)^(\s*esbuild:\s*)set this to true or false\s*$'; value = 'true' },
        @{ pattern = '(?m)^(\s*msgpackr-extract:\s*)set this to true or false\s*$'; value = 'true' },
        @{ pattern = '(?m)^(\s*protobufjs:\s*)set this to true or false\s*$'; value = 'false' }
    )) {
        $updated = [regex]::Replace($updated, $policy.pattern, ('${1}' + $policy.value))
    }
    if ($updated -match '(?m):\s*set this to true or false\s*$') {
        throw "Unreviewed dependency build script in $workspaceFile"
    }
    if ($updated -ne $original) {
        [IO.File]::WriteAllText($workspaceFile, $updated, [Text.UTF8Encoding]::new($false))
    }
}
function Install-ProjectDependencies([string]$Project) {
    Push-Location -LiteralPath $Project
    try {
        Set-BuildScriptPolicy $Project
        $approval = @(& $node $pnpm @('config','get','allowBuilds') 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "Could not read pnpm build-script policy in $Project." }
        $policy = ($approval -join [Environment]::NewLine) | ConvertFrom-Json
        $effectivePolicy = @{}
        foreach ($entry in $policy.PSObject.Properties) { $effectivePolicy[$entry.Name] = $entry.Value }
        $expectedPolicy = if ([IO.Path]::GetFileName($Project) -eq 'server') {
            @{ '@scarf/scarf' = $false; esbuild = $true; 'msgpackr-extract' = $true; protobufjs = $false }
        } else { @{} }
        $invalidPolicy = @($expectedPolicy.Keys | Where-Object {
            -not $effectivePolicy.ContainsKey($_) -or $effectivePolicy[$_] -ne $expectedPolicy[$_]
        })
        if ($invalidPolicy.Count) {
            throw "pnpm build-script policy was not applied in $Project."
        }
        $output = @(& $node $pnpm @('install','--prod','--frozen-lockfile','--config.node-linker=hoisted','--os=win32','--cpu=x64','--network-concurrency=1','--store-dir',$store) 2>&1)
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $details = ($output | Select-Object -Last 20 | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
            throw "pnpm install failed in $Project (exit code $exitCode): $details"
        }
    } finally { Pop-Location }
}
try {
    foreach ($projectName in @('server','cli')) {
        $project = Join-Path $ReleaseRoot $projectName
        foreach ($name in @('package.json','pnpm-lock.yaml','pnpm-workspace.yaml')) {
            if (-not (Test-Path -LiteralPath (Join-Path $project $name) -PathType Leaf)) { throw "Portable $projectName dependency metadata is missing: $name" }
        }
        Install-ProjectDependencies $project
    }

    $customSharp = Join-Path $ReleaseRoot 'dependencies\sharp\lib'
    if (Test-Path -LiteralPath $customSharp -PathType Container) {
        $sharpLib = Join-Path $ReleaseRoot 'server\node_modules\@img\sharp-win32-x64\lib'
        if (-not (Test-Path -LiteralPath $sharpLib -PathType Container)) { throw "Installed Sharp runtime is missing: $sharpLib" }
        Get-ChildItem -LiteralPath $sharpLib -Filter '*.dll' -File -Recurse | Remove-Item -Force
        foreach ($dll in (Get-ChildItem -LiteralPath $customSharp -Filter '*.dll' -File -Recurse)) {
            $relative = $dll.FullName.Substring($customSharp.Length).TrimStart('\')
            $target = Join-Path $sharpLib $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            Copy-Item -LiteralPath $dll.FullName -Destination $target -Force
        }
        Remove-Item -LiteralPath $customSharp -Recurse -Force
    }
    $expectedState | ConvertTo-Json | Set-Content -Encoding utf8 -LiteralPath $statePath
} finally {
    $env:SHARP_IGNORE_GLOBAL_LIBVIPS = $oldSharpIgnoreGlobal
    $env:NODE_PATH = $oldNodePath
}
