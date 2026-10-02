#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReleaseRoot,
    [Parameter(Mandatory)][string]$InstallRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$manifest = Get-Content -Raw -LiteralPath (Join-Path $ReleaseRoot 'manifest.json') | ConvertFrom-Json
Import-Module (Join-Path $PSScriptRoot '..\Common.psm1') -Force
$statePath = Join-Path $ReleaseRoot '.node-dependencies-installed.json'
$expectedState = [ordered]@{
    node = $manifest.dependencies.node.version
    pnpm = $manifest.dependencies.pnpm.version
    server = Get-ImmichDependencyInputHash -ReleaseRoot $ReleaseRoot -Project server
    cli = Get-ImmichDependencyInputHash -ReleaseRoot $ReleaseRoot -Project cli
}
$customSharp = Join-Path $ReleaseRoot 'dependencies\sharp\lib'
$stagedSharpDlls=@()
$sharpReplacementFiles=@()
if (Test-Path -LiteralPath $customSharp -PathType Container) {
    $customVersions = Join-Path (Split-Path -Parent $customSharp) 'versions.json'
    if (-not (Test-Path -LiteralPath $customVersions -PathType Leaf)) { throw "Custom Sharp version metadata is missing: $customVersions" }
    $stagedSharpDlls=@(Get-ChildItem -LiteralPath $customSharp -Filter '*.dll' -File -Recurse)
    $expectedDlls=@($manifest.nativeDependencyFiles.PSObject.Properties | Where-Object { $_.Name -like 'dependencies/sharp/lib/*.dll' })
    $stagedNames=@($stagedSharpDlls | ForEach-Object { 'dependencies/sharp/lib/'+[IO.Path]::GetRelativePath($customSharp,$_.FullName).Replace('\','/') } | Sort-Object)
    if (-not $expectedDlls.Count -or ($stagedNames -join "`n") -cne (($expectedDlls.Name | Sort-Object) -join "`n")) { throw 'Custom Sharp staging must contain the complete native DLL inventory.' }
    $sharpReplacementFiles=@($stagedNames | ForEach-Object { $_.Replace('dependencies/sharp/','@img/sharp-win32-x64/') })
}
$source = Get-ImmichDependencySource -InstallRoot $InstallRoot -ReleaseRoot $ReleaseRoot
$sourceManifest = if ($source) { Get-Content -Raw (Join-Path $source 'manifest.json') | ConvertFrom-Json } else { $null }
function Read-DependencyState([string]$Path) {
    try { if (Test-Path -LiteralPath $Path) { return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json } }
    catch { Write-Warning "Ignoring invalid dependency completion marker: $Path" }
    return $null
}
function Test-SourceProjectInputs([string]$Project) {
    try { return (Get-ImmichDependencyInputHash -ReleaseRoot $source -Project $Project) -ceq [string]$expectedState[$Project] }
    catch { return $false }
}
function Test-NodeProjectComplete([string]$Root,[string]$Project) {
    try {
        $package=Get-Content -Raw -LiteralPath (Join-Path $Root "$Project\package.json") | ConvertFrom-Json
        foreach ($dependency in $package.dependencies.PSObject.Properties) {
            $metadata=Join-Path $Root "$Project\node_modules\$($dependency.Name)\package.json"
            if (-not (Test-Path -LiteralPath $metadata -PathType Leaf)) { return $false }
            $installed=Get-Content -Raw -LiteralPath $metadata | ConvertFrom-Json
            if (-not $installed.PSObject.Properties['name'] -or [string]$installed.name -cne $dependency.Name) { return $false }
            if ($installed.PSObject.Properties['main'] -and [string]$installed.main -and
                -not (Test-Path -LiteralPath (Join-Path (Split-Path $metadata) $installed.main))) {
                # Node also resolves extensionless files and directory indexes.
                $main=Join-Path (Split-Path $metadata) $installed.main
                if (-not (Test-Path "$main.js") -and -not (Test-Path "$main.json") -and -not (Test-Path "$main.node")) { return $false }
            }
        }
        return $true
    } catch { return $false }
}
$sourceState = if ($source) { Read-DependencyState (Join-Path $source '.node-dependencies-installed.json') } else { $null }
$sourceComplete = $sourceState -and $sourceState.PSObject.Properties['node'] -and $sourceState.PSObject.Properties['pnpm'] -and
    [string]$sourceState.node -eq [string]$manifest.dependencies.node.version -and
    [string]$sourceState.pnpm -eq [string]$manifest.dependencies.pnpm.version
$installedState = Read-DependencyState $statePath
$skip = @{}
foreach ($project in @('server','cli')) {
    $modules = Join-Path $ReleaseRoot "$project\node_modules"
    $skip[$project] = $installedState -and $installedState.PSObject.Properties[$project] -and
        [string]$installedState.$project -ceq [string]$expectedState[$project] -and
        [string]$installedState.node -eq [string]$expectedState.node -and
        [string]$installedState.pnpm -eq [string]$expectedState.pnpm -and
        (Test-Path -LiteralPath $modules -PathType Container) -and (Test-NodeProjectComplete $ReleaseRoot $project)
    if (-not $skip[$project] -and -not (Test-Path -LiteralPath $modules) -and $sourceComplete -and
        (Test-ImmichDependencyPinEqual $sourceManifest $manifest 'node') -and
        (Test-ImmichDependencyPinEqual $sourceManifest $manifest 'pnpm') -and
        (Test-SourceProjectInputs $project) -and (Test-NodeProjectComplete $source $project) -and
        (-not $sourceState.PSObject.Properties[$project] -or [string]$sourceState.$project -ceq [string]$expectedState[$project])) {
        try {
            # Staging already contains these complete replacements. Do not copy
            # the old DLLs into the candidate merely to discard them below.
            $exclude=if ($project -eq 'server') { $sharpReplacementFiles } else { @() }
            Copy-ImmichDependencyTree -Source (Join-Path $source "$project\node_modules") -Destination $modules -Label "$project Node packages" -ExcludeRelativeFiles $exclude
            $skip[$project] = $true
            Write-Host "Reused installed $project Node packages (dependency inputs unchanged)."
        } catch { Write-Warning "Cannot reuse $project Node packages. $($_.Exception.Message)" }
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
if (($skip.Values -contains $false) -and -not (Test-Path -LiteralPath $pnpmCli -PathType Leaf)) {
    New-Item -ItemType Directory -Path $pnpmRoot -Force | Out-Null
    $env:npm_config_cache = Join-Path $InstallRoot 'cache\npm'
    $pnpmProgress=Start-ImmichProgress -Key node -Detail "pnpm $pnpmVersion"
    & $npm install --prefix $pnpmRoot --no-save --no-audit --no-fund "pnpm@$pnpmVersion"
    if ($LASTEXITCODE -ne 0) { Update-ImmichProgress -State $pnpmProgress -Failed; throw "Could not install pinned pnpm $pnpmVersion." }
    Update-ImmichProgress -State $pnpmProgress -Finished
}
if (($skip.Values -contains $false) -and -not (Test-Path -LiteralPath $pnpmCli -PathType Leaf)) { throw "Pinned pnpm package was not installed: $pnpmCli" }

$oldSharpIgnoreGlobal = $env:SHARP_IGNORE_GLOBAL_LIBVIPS
$oldNodePath = $env:NODE_PATH
$oldPath = $env:PATH
$env:SHARP_IGNORE_GLOBAL_LIBVIPS = 'true'
$env:NODE_PATH = Join-Path $ReleaseRoot 'runtime'
$env:PATH = "$nodeRoot;$oldPath"
$store = Join-Path $InstallRoot 'cache\pnpm-store'
function Install-ProjectDependencies([string]$Project) {
    Push-Location -LiteralPath $Project
    $progress=Start-ImmichProgress -Key node -Detail (Split-Path -Leaf $Project)
    try {
        $output = [Collections.Generic.Queue[string]]::new()
        & $node $pnpmCli @('install','--prod','--frozen-lockfile','--config.node-linker=hoisted','--os=win32','--cpu=x64','--network-concurrency=1','--reporter=append-only','--store-dir',$store) 2>&1 | ForEach-Object {
            $line=[string]$_
            Write-Host $line
            $output.Enqueue($line)
            if ($output.Count -gt 20) { [void]$output.Dequeue() }
        }
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $details = ($output | Select-Object -Last 20 | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
            throw "pnpm install failed in $Project (exit code $exitCode): $details"
        }
        Update-ImmichProgress -State $progress -Finished
    } catch {
        Update-ImmichProgress -State $progress -Failed
        throw
    } finally { Pop-Location }
}
try {
    foreach ($projectName in @('server','cli')) {
        $project = Join-Path $ReleaseRoot $projectName
        foreach ($name in @('package.json','pnpm-lock.yaml','pnpm-workspace.yaml')) {
            if (-not (Test-Path -LiteralPath (Join-Path $project $name) -PathType Leaf)) { throw "Portable $projectName dependency metadata is missing: $name" }
        }
        if (-not $skip[$projectName]) { Install-ProjectDependencies $project }
    }

    if (Test-Path -LiteralPath $customSharp -PathType Container) {
        $sharpLib = Join-Path $ReleaseRoot 'server\node_modules\@img\sharp-win32-x64\lib'
        if (-not (Test-Path -LiteralPath $sharpLib -PathType Container)) { throw "Installed Sharp runtime is missing: $sharpLib" }
        foreach ($dll in (Get-ChildItem -LiteralPath $sharpLib -Filter '*.dll' -File -Recurse)) {
            $relative='dependencies/sharp/lib/'+[IO.Path]::GetRelativePath($sharpLib,$dll.FullName).Replace('\','/')
            if ($relative -notin $stagedNames) { Remove-Item -LiteralPath $dll.FullName -Force }
        }
        foreach ($dll in $stagedSharpDlls) {
            $relative = [IO.Path]::GetRelativePath($customSharp,$dll.FullName)
            $target = Join-Path $sharpLib $relative
            $expected=$manifest.nativeDependencyFiles.PSObject.Properties['dependencies/sharp/lib/'+$relative.Replace('\','/')].Value
            if ((Test-Path -LiteralPath $target -PathType Leaf) -and (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash -ieq $expected) { continue }
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            Copy-Item -LiteralPath $dll.FullName -Destination $target -Force
        }
        Copy-Item -LiteralPath $customVersions -Destination (Join-Path (Split-Path -Parent $sharpLib) 'versions.json') -Force
        Remove-Item -LiteralPath $customSharp -Recurse -Force
        Remove-Item -LiteralPath $customVersions -Force
    }
    $expectedState | ConvertTo-Json | Set-Content -Encoding utf8 -LiteralPath $statePath
} finally {
    $env:SHARP_IGNORE_GLOBAL_LIBVIPS = $oldSharpIgnoreGlobal
    $env:NODE_PATH = $oldNodePath
    $env:PATH = $oldPath
}
