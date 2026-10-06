#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReleaseRoot,
    [Parameter(Mandatory)][string]$InstallRoot,
    [System.Collections.Generic.List[object]]$DependencyReusePlan
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$manifest = Get-Content -Raw -LiteralPath (Join-Path $ReleaseRoot 'manifest.json') | ConvertFrom-Json
Import-Module (Join-Path $PSScriptRoot '..\Common.psm1') -Force
$statePath = Join-Path $ReleaseRoot '.node-dependencies-installed.json'
$plannedInputs=@{}
foreach ($entry in $DependencyReusePlan) {
    if ($entry.relativePath -match '^(server|cli)[\\/]node_modules$') {
        $project=$Matches[1]
        if (-not $entry.PSObject.Properties['dependencyInputHash'] -or [string]$entry.dependencyInputHash -notmatch '^[0-9a-fA-F]{64}$') { throw 'Planned Node reuse is missing its checked dependency inputs.' }
        $plannedInputs[$project]=[string]$entry.dependencyInputHash
    }
}
$expectedState = [ordered]@{
    node = $manifest.dependencies.node.version
    pnpm = $manifest.dependencies.pnpm.version
    server = if ($plannedInputs.ContainsKey('server')) { $plannedInputs.server } else { Get-ImmichDependencyInputHash -ReleaseRoot $ReleaseRoot -Project server }
    cli = if ($plannedInputs.ContainsKey('cli')) { $plannedInputs.cli } else { Get-ImmichDependencyInputHash -ReleaseRoot $ReleaseRoot -Project cli }
}
$customSharp = Join-Path $ReleaseRoot 'dependencies\sharp\lib'
$stagedSharpDlls=@()
if (-not $plannedInputs.ContainsKey('server') -and (Test-Path -LiteralPath $customSharp -PathType Container)) {
    $customVersions = Join-Path (Split-Path -Parent $customSharp) 'versions.json'
    if (-not (Test-Path -LiteralPath $customVersions -PathType Leaf)) { throw "Custom Sharp version metadata is missing: $customVersions" }
    $stagedSharpDlls=@(Get-ChildItem -LiteralPath $customSharp -Filter '*.dll' -File -Recurse)
    $expectedDlls=@($manifest.nativeDependencyFiles.PSObject.Properties | Where-Object { $_.Name -like 'dependencies/sharp/lib/*.dll' })
    $stagedNames=@($stagedSharpDlls | ForEach-Object { 'dependencies/sharp/lib/'+[IO.Path]::GetRelativePath($customSharp,$_.FullName).Replace('\','/') } | Sort-Object)
    if (-not $expectedDlls.Count -or ($stagedNames -join "`n") -cne (($expectedDlls.Name | Sort-Object) -join "`n")) { throw 'Custom Sharp staging must contain the complete native DLL inventory.' }
}
$source = if ($null -ne $DependencyReusePlan) { Get-ImmichDependencySource -InstallRoot $InstallRoot -ReleaseRoot $ReleaseRoot } else { $null }
$installedState = Read-ImmichNodeDependencyState $statePath
$skip = @{}
$deferred = @{}
foreach ($project in @('server','cli')) {
    $modules = Join-Path $ReleaseRoot "$project\node_modules"
    $plannedModules = Get-ImmichDependencyReadPath -Path $modules -DependencyReusePlan $DependencyReusePlan
    $deferred[$project] = $plannedModules -ine $modules
    if ($deferred[$project]) {
        # Runtime preparation already proved this server tree reusable before
        # omitting its native staging. Keep this invocation read-only until stop.
        if (-not $source -or $plannedModules -ine (Join-Path $source "$project\node_modules") -or
            -not $plannedInputs.ContainsKey($project)) {
            throw "Planned $project Node dependency reuse no longer matches this update."
        }
        if ($project -eq 'server') {
            $transfer=@($DependencyReusePlan | Where-Object relativePath -eq 'server/node_modules')[0]
            $sharpFiles=[Collections.Generic.List[object]]::new()
            $previousManifest=Get-Content -Raw (Join-Path $source 'manifest.json') | ConvertFrom-Json
            $sharpUnchanged=Test-ImmichSharpInputsEqual $previousManifest $manifest
            foreach ($file in $manifest.nativeDependencyFiles.PSObject.Properties | Where-Object {$_.Name.StartsWith('dependencies/sharp/')}) {
                $staged=Join-Path $ReleaseRoot $file.Name
                if ($sharpUnchanged -or -not (Test-Path -LiteralPath $staged -PathType Leaf)) { continue }
                if ((Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash -ine $file.Value) { throw 'Staged Sharp checksum mismatch.' }
                $old=Join-Path $source $file.Name.Replace('dependencies/sharp/','server/node_modules/@img/sharp-win32-x64/')
                $sharpFiles.Add([pscustomobject]@{relativePath=$file.Name;sha256=[string]$file.Value;hadTarget=(Test-Path -LiteralPath $old -PathType Leaf)})
            }
            $previousManifest=Get-Content -Raw (Join-Path $source 'manifest.json') | ConvertFrom-Json
            foreach ($file in $previousManifest.nativeDependencyFiles.PSObject.Properties | Where-Object {$_.Name.StartsWith('dependencies/sharp/lib/')}) {
                if (-not $manifest.nativeDependencyFiles.PSObject.Properties[$file.Name]) {
                    $old=Join-Path $source $file.Name.Replace('dependencies/sharp/','server/node_modules/@img/sharp-win32-x64/')
                    $sharpFiles.Add([pscustomobject]@{relativePath=$file.Name;sha256=$null;hadTarget=(Test-Path -LiteralPath $old -PathType Leaf)})
                }
            }
            if ($sharpUnchanged) {
                foreach ($path in @($customSharp,(Join-Path (Split-Path -Parent $customSharp) 'versions.json'))) {
                    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
                }
            }
            $transfer | Add-Member -NotePropertyName sharpFiles -NotePropertyValue $sharpFiles.ToArray() -Force
        }
        $skip[$project] = $true
        continue
    }
    $skip[$project] = $installedState -and $installedState.PSObject.Properties[$project] -and
        [string]$installedState.$project -ceq [string]$expectedState[$project] -and
        [string]$installedState.node -eq [string]$expectedState.node -and
        [string]$installedState.pnpm -eq [string]$expectedState.pnpm -and
        (Test-Path -LiteralPath $modules -PathType Container) -and (Test-ImmichNodeProjectComplete $ReleaseRoot $project)
    if (-not $skip[$project] -and $source -and -not (Test-Path -LiteralPath $modules) -and
        (Test-ImmichNodeProjectReusable -PreviousRelease $source -CandidateRelease $ReleaseRoot -Project $project -Inputs $expectedState)) {
        Add-ImmichDependencyReuse -Plan $DependencyReusePlan -PreviousRelease $source -CandidateRelease $ReleaseRoot -RelativePath "$project/node_modules" -Label "$project Node packages"
        $DependencyReusePlan[-1] | Add-Member -NotePropertyName dependencyInputHash -NotePropertyValue ([string]$expectedState[$project])
        $skip[$project] = $true
        $deferred[$project] = $true
    }
}
$nodeRoot = Get-ImmichDependencyReadPath -Path (Join-Path $ReleaseRoot 'runtime\node') -DependencyReusePlan $DependencyReusePlan
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
        & $node $pnpmCli @('install','--prod','--frozen-lockfile','--prefer-offline','--config.node-linker=hoisted','--os=win32','--cpu=x64','--network-concurrency=1','--reporter=append-only','--store-dir',$store) 2>&1 | ForEach-Object {
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
function Copy-IndependentSharpFile([string]$Source,[string]$Destination) {
    # pnpm can hardlink package files to its shared store. Never overwrite an
    # existing file record, and retain staging until the whole injection succeeds.
    $temporary = Join-Path (Split-Path -Parent $Destination) ('.sharp-replacement-'+[guid]::NewGuid().ToString('N'))
    try {
        Copy-Item -LiteralPath $Source -Destination $temporary
        [IO.File]::Move($temporary,$Destination,$true)
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}
try {
    foreach ($projectName in @('server','cli')) {
        $project = Join-Path $ReleaseRoot $projectName
        foreach ($name in @('package.json','pnpm-lock.yaml','pnpm-workspace.yaml')) {
            if (-not (Test-Path -LiteralPath (Join-Path $project $name) -PathType Leaf)) { throw "Portable $projectName dependency metadata is missing: $name" }
        }
        if (-not $skip[$projectName]) { Install-ProjectDependencies $project }
    }

    if (-not $deferred['server'] -and (Test-Path -LiteralPath $customSharp -PathType Container)) {
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
            Copy-IndependentSharpFile -Source $dll.FullName -Destination $target
        }
        Copy-IndependentSharpFile -Source $customVersions -Destination (Join-Path (Split-Path -Parent $sharpLib) 'versions.json')
        Remove-Item -LiteralPath $customSharp -Recurse -Force
        Remove-Item -LiteralPath $customVersions -Force
    }
    $expectedState | ConvertTo-Json | Set-Content -Encoding utf8 -LiteralPath $statePath
} finally {
    $env:SHARP_IGNORE_GLOBAL_LIBVIPS = $oldSharpIgnoreGlobal
    $env:NODE_PATH = $oldNodePath
    $env:PATH = $oldPath
}
