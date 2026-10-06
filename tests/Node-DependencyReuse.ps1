#requires -Version 7.0
# Tiny local fixtures only. Invalid tool executables ensure reuse runs no npm/pnpm.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../runtime/Common.psm1') -Force
function Check([bool]$Value,[string]$Message) { if (-not $Value) { throw $Message } }
function Write-Fixture([string]$Path,[string]$Text) { [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)); [IO.File]::WriteAllText($Path,$Text) }
$base=Join-Path ([IO.Path]::GetTempPath()) ('node-reuse-'+[guid]::NewGuid().ToString('N'))
$current=Join-Path $base 'current'
$standaloneNode=$null
try {
    $old=Join-Path $base 'releases/v3.2.2.1';$new=Join-Path $base 'releases/v3.2.2.2'
    $manifest=@{target='windows-x64-native';dependencies=@{node=@{version='24.15.0';asset='node.zip'};pnpm=@{version='11.22.0'}};nativeDependencyFiles=@{'dependencies/sharp/lib/custom.dll'=('a'*64);'dependencies/sharp/versions.json'=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('{}')))};nativeDependencyMetadata=@{'dependencies/sharp/versions.json'='e30='}}
    $manifestText=$manifest|ConvertTo-Json -Depth 6
    Write-Fixture (Join-Path $old 'server/node_modules/@img/sharp-win32-x64/versions.json') '{}'
    foreach ($root in @($old,$new)) {
        Write-Fixture (Join-Path $root 'manifest.json') $manifestText
        foreach ($project in @('server','cli')) {
            Write-Fixture (Join-Path $root "$project/package.json") '{"dependencies":{"demo":"1.0.0"}}'
            foreach ($name in @('pnpm-lock.yaml','pnpm-workspace.yaml')) { Write-Fixture (Join-Path $root "$project/$name") 'same' }
        }
        Write-Fixture (Join-Path $root 'server/.immich/plugin-sdk/index.js') 'same sdk'
    }
    foreach ($project in @('server','cli')) {
        Write-Fixture (Join-Path $old "$project/node_modules/demo/package.json") '{"name":"demo","main":"index.js"}'
        Write-Fixture (Join-Path $old "$project/node_modules/demo/index.js") 'unchanged package'
    }
    foreach ($name in @('node.exe','npm.cmd')) { Write-Fixture (Join-Path $old "runtime/node/$name") 'must not execute' }
    $state=@{node='24.15.0';pnpm='11.22.0';server=(Get-ImmichDependencyInputHash $old server);cli=(Get-ImmichDependencyInputHash $old cli)}
    Write-Fixture (Join-Path $old '.node-dependencies-installed.json') ($state|ConvertTo-Json)
    Check (Test-ImmichNodeProjectReusable $old $new server) 'Identical server dependencies were not reusable.'
    Write-Fixture (Join-Path $new 'server/pnpm-lock.yaml') 'changed lock'
    Check (-not (Test-ImmichNodeProjectReusable $old $new server)) 'Changed lockfile was reused.'
    Write-Fixture (Join-Path $new 'server/pnpm-lock.yaml') 'same'
    $manifest.nativeDependencyFiles['dependencies/sharp/lib/custom.dll']='c'*64
    Write-Fixture (Join-Path $new 'manifest.json') ($manifest|ConvertTo-Json -Depth 6)
    Check (Test-ImmichNodeProjectReusable $old $new server) 'A Sharp-only change reinstalled unchanged Node dependencies.'
    Check (Test-ImmichNodeProjectReusable $old $new cli) 'Sharp changes invalidated the independent CLI.'
    Write-Fixture (Join-Path $new 'manifest.json') $manifestText
    $linkType=if($IsWindows){'Junction'}else{'SymbolicLink'}
    New-Item -ItemType $linkType -Path $current -Target $old | Out-Null
    $plan=[Collections.Generic.List[object]]::new()
    Add-ImmichDependencyReuse -Plan $plan -PreviousRelease $old -CandidateRelease $new -RelativePath 'runtime/node' -Label Node
    Add-ImmichDependencyReuse -Plan $plan -PreviousRelease $old -CandidateRelease $new -RelativePath 'server/node_modules' -Label 'server Node packages'
    $plan[-1] | Add-Member -NotePropertyName dependencyInputHash -NotePropertyValue $state.server
    # A resume may leave incomplete obsolete staging; it is not needed for a
    # fully reusable server tree and must not trigger a scan or reinjection.
    Write-Fixture (Join-Path $new 'dependencies/sharp/lib/partial.dll') 'redundant staging'
    Write-Fixture (Join-Path $new 'dependencies/sharp/versions.json') '{}'
    & (Join-Path $PSScriptRoot '../runtime/launchers/Install-NodeDependencies.ps1') -ReleaseRoot $new -InstallRoot $base -DependencyReusePlan $plan
    Check ($plan.Count -eq 3) 'The unchanged CLI was not added to the deferred plan.'
    foreach ($project in @('server','cli')) {
        Check (-not (Test-Path -LiteralPath (Join-Path $new "$project/node_modules"))) 'Preparation copied or moved a dependency tree before shutdown.'
        Check ((Get-Content -Raw -LiteralPath (Join-Path $old "$project/node_modules/demo/index.js")) -ceq 'unchanged package') 'Preparation changed the running dependencies.'
    }
    Check (-not (Test-Path -LiteralPath (Join-Path $base 'tools'))) 'Unchanged dependencies bootstrapped package managers.'
    Check (-not (Test-Path -LiteralPath (Join-Path $new 'dependencies/sharp/lib'))) 'Unchanged Sharp retained redundant DLL staging.'
    Check (-not (Test-Path -LiteralPath (Join-Path $new 'dependencies/sharp/versions.json'))) 'Unchanged Sharp retained redundant metadata staging.'
    Check (Test-Path -LiteralPath (Join-Path $new '.node-dependencies-installed.json')) 'Prepared dependency inputs were not recorded.'

    # Standalone preparation does not inspect current or copy its dependencies.
    # An invalid current shape would throw if the old source lookup still ran.
    [IO.Directory]::Delete($current)
    [void][IO.Directory]::CreateDirectory($current)
    $standalone=Join-Path $base 'releases/standalone'
    Write-Fixture (Join-Path $standalone 'manifest.json') $manifestText
    foreach ($project in @('server','cli')) {
        Write-Fixture (Join-Path $standalone "$project/package.json") '{"dependencies":{}}'
        foreach ($name in @('pnpm-lock.yaml','pnpm-workspace.yaml')) { Write-Fixture (Join-Path $standalone "$project/$name") 'same' }
    }
    Write-Fixture (Join-Path $standalone 'server/.immich/plugin-sdk/index.js') 'same sdk'
    foreach ($name in @('node.exe','npm.cmd')) { Write-Fixture (Join-Path $standalone "runtime/node/$name") 'fixture executable' }
    Write-Fixture (Join-Path $base 'tools/pnpm/11.22.0/node_modules/pnpm/bin/pnpm.cjs') 'existing manager'
    $standaloneNode=Join-Path $standalone 'runtime/node/node.exe'
    $managerCalls=[Collections.Generic.List[object]]::new()
    $managerStub={
        # PowerShell functions receive the native argument array as one value;
        # flatten it the same way native-command argument passing does.
        $managerCalls.Add(@($args | ForEach-Object { $_ }))
        [void][IO.Directory]::CreateDirectory((Join-Path $PWD.Path 'node_modules'))
        $global:LASTEXITCODE=0
    }.GetNewClosure()
    Set-Item "function:global:$standaloneNode" $managerStub
    & (Join-Path $PSScriptRoot '../runtime/launchers/Install-NodeDependencies.ps1') -ReleaseRoot $standalone -InstallRoot $base
    Check ($managerCalls.Count -eq 2) 'Standalone preparation did not use pnpm for both projects.'
    foreach ($arguments in $managerCalls) {
        Check ($arguments -contains '--prefer-offline') 'pnpm cache-first behavior was removed.'
        Check ($arguments -contains '--frozen-lockfile') 'pnpm lockfile enforcement was removed.'
        Check ($arguments -contains (Join-Path $base 'cache/pnpm-store')) 'pnpm did not use the existing shared store.'
    }
    [IO.Directory]::Delete($current)
    New-Item -ItemType $linkType -Path $current -Target $old | Out-Null
    $changedPlan=[Collections.Generic.List[object]]::new()
    $manifest.nativeDependencyFiles['dependencies/sharp/lib/custom.dll']='c'*64
    Write-Fixture (Join-Path $new 'manifest.json') ($manifest|ConvertTo-Json -Depth 6)
    $payload='new native bytes'
    $manifest.nativeDependencyFiles['dependencies/sharp/lib/custom.dll']=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($payload)))
    Write-Fixture (Join-Path $new 'manifest.json') ($manifest|ConvertTo-Json -Depth 6)
    Write-Fixture (Join-Path $new 'dependencies/sharp/lib/custom.dll') $payload
    Write-Fixture (Join-Path $old 'server/node_modules/@img/sharp-win32-x64/lib/custom.dll') 'old native bytes'
    Add-ImmichDependencyReuse $changedPlan $old $new 'runtime/node' Node
    Add-ImmichDependencyReuse $changedPlan $old $new 'server/node_modules' Server
    $changedPlan[-1] | Add-Member -NotePropertyName dependencyInputHash -NotePropertyValue $state.server
    & (Join-Path $PSScriptRoot '../runtime/launchers/Install-NodeDependencies.ps1') -ReleaseRoot $new -InstallRoot $base -DependencyReusePlan $changedPlan
    Check ($changedPlan[1].sharpFiles.Count -eq 1) 'A Sharp-only update did not record exactly the changed DLL.'
    Check ((Get-Content -Raw (Join-Path $old 'server/node_modules/@img/sharp-win32-x64/lib/custom.dll')) -ceq 'old native bytes') 'Preparation changed the running DLL.'
    $nativeEntry=$changedPlan[1].sharpFiles[0]
    $nativePath=$nativeEntry.relativePath
    $nativeEntry.relativePath='dependencies/sharp/lib/../outside.dll'
    $rejected=$false
    try { Move-ImmichReusedDependencies $changedPlan $old $new } catch { $rejected=$true }
    Check ($rejected -and (Test-Path (Join-Path $old 'runtime/node'))) 'Invalid Sharp path moved dependencies before validation.'
    $nativeEntry.relativePath=$nativePath
    $linked=Join-Path $old 'server/node_modules/@img/sharp-win32-x64/lib/linked'
    New-Item -ItemType $linkType -Path $linked -Target $base | Out-Null
    $changedPlan[1].sharpFiles+=@([pscustomobject]@{relativePath='dependencies/sharp/lib/linked/new.dll';sha256=('a'*64);hadTarget=$false})
    $rejected=$false
    try { Move-ImmichReusedDependencies $changedPlan $old $new } catch { $rejected=$true }
    Check ($rejected -and (Test-Path (Join-Path $old 'runtime/node'))) 'Linked Sharp path moved dependencies before validation.'
    [IO.Directory]::Delete($linked)
    $changedPlan[1].sharpFiles=@($nativeEntry)
    Move-ImmichReusedDependencies $changedPlan $old $new
    Check ((Get-Content -Raw (Join-Path $new 'server/node_modules/@img/sharp-win32-x64/lib/custom.dll')) -ceq $payload) 'Changed DLL was not moved after shutdown.'
    Check (-not (Test-Path (Join-Path $new 'dependencies/sharp/lib/custom.dll'))) 'Changed DLL was copied instead of moved.'
    $saved=$changedPlan.ToArray()|ConvertTo-Json -Depth 8|ConvertFrom-Json -AsHashtable
    Move-ImmichReusedDependencies $saved $old $new -Restore
    Move-ImmichReusedDependencies $saved $old $new -Restore
    Check ((Get-Content -Raw (Join-Path $old 'server/node_modules/@img/sharp-win32-x64/lib/custom.dll')) -ceq 'old native bytes') 'Recovery did not restore the previous DLL.'
    Check ((Get-Content -Raw (Join-Path $new 'dependencies/sharp/lib/custom.dll')) -ceq $payload) 'Recovery lost the changed DLL for retry.'
    Write-Fixture (Join-Path $old 'server/node_modules/@img/sharp-win32-x64/lib/obsolete.dll') 'old obsolete'
    Write-Fixture (Join-Path $old 'server/node_modules/@img/sharp-win32-x64/versions.json') 'old metadata'
    foreach ($path in @('lib/added.dll','versions.json')) {
        $staged=Join-Path $new "dependencies/sharp/$path"
        Write-Fixture $staged "new $path"
        $changedPlan[1].sharpFiles+=@([pscustomobject]@{relativePath="dependencies/sharp/$path";sha256=(Get-FileHash $staged).Hash;hadTarget=($path -eq 'versions.json')})
    }
    $changedPlan[1].sharpFiles+=@([pscustomobject]@{relativePath='dependencies/sharp/lib/obsolete.dll';sha256=$null;hadTarget=$true})
    $saved=$changedPlan.ToArray()|ConvertTo-Json -Depth 8|ConvertFrom-Json -AsHashtable
    if ($IsWindows) {
        $locked=[IO.File]::Open((Join-Path $new 'dependencies/sharp/versions.json'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try {
            $rejected=$false
            try { Move-ImmichReusedDependencies $changedPlan $old $new } catch { $rejected=$true }
            Check $rejected 'Locked staging did not fail the transfer.'
            Move-ImmichReusedDependencies $saved $old $new -Restore
        } finally { $locked.Dispose() }
        Check ((Get-Content -Raw (Join-Path $old 'server/node_modules/@img/sharp-win32-x64/versions.json')) -ceq 'old metadata') 'Failure after backing up metadata lost the old file.'
    }
    Move-ImmichReusedDependencies $changedPlan $old $new
    Check (-not (Test-Path (Join-Path $new 'server/node_modules/@img/sharp-win32-x64/lib/obsolete.dll'))) 'Sharp transfer retained obsolete DLLs.'
    Move-ImmichReusedDependencies $saved $old $new -Restore
    Move-ImmichReusedDependencies $saved $old $new -Restore
    Check ((Get-Content -Raw (Join-Path $old 'server/node_modules/@img/sharp-win32-x64/lib/obsolete.dll')) -ceq 'old obsolete') 'Recovery lost a removed DLL.'
    Check (-not (Test-Path (Join-Path $old 'server/node_modules/@img/sharp-win32-x64/lib/added.dll'))) 'Recovery retained a new DLL in the old runtime.'
    Check ((Get-Content -Raw (Join-Path $new 'dependencies/sharp/lib/added.dll')) -ceq 'new lib/added.dll') 'Recovery lost new DLL staging.'
    Write-Fixture (Join-Path $old 'manifest.json') (Get-Content -Raw (Join-Path $new 'manifest.json'))
    Remove-Item (Join-Path $old 'server/node_modules/@img/sharp-win32-x64/lib/custom.dll')
    Remove-Item (Join-Path $new 'dependencies/sharp/versions.json'),(Join-Path $new 'dependencies/sharp/lib/added.dll')
    & (Join-Path $PSScriptRoot '../runtime/launchers/Install-NodeDependencies.ps1') -ReleaseRoot $new -InstallRoot $base -DependencyReusePlan $changedPlan
    Check ($changedPlan[1].sharpFiles.Count -eq 1 -and -not $changedPlan[1].sharpFiles[0].hadTarget) 'Equal manifests discarded staging for a missing installed DLL.'
    Move-ImmichReusedDependencies $changedPlan $old $new
    Check ((Get-Content -Raw (Join-Path $new 'server/node_modules/@img/sharp-win32-x64/lib/custom.dll')) -ceq $payload) 'Missing DLL was not repaired during dependency transfer.'
    Move-ImmichReusedDependencies $changedPlan $old $new -Restore
    Write-Host 'PASS Node dependencies: unchanged trees deferred; changed lock rejected; Sharp-only changes transferred; standalone uses existing pnpm store without reading current'
} finally {
    if ($standaloneNode) { Remove-Item "function:global:$standaloneNode" -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $current) { [IO.Directory]::Delete($current) }
    if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
}
