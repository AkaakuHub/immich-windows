#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../runtime/Common.psm1') -Force
function Check([bool]$Value,[string]$Message) { if (-not $Value) { throw $Message } }
function Reject([scriptblock]$Action) { $failed=$false; try { & $Action | Out-Null } catch { $failed=$true }; Check $failed 'Unsafe reuse accepted.' }
function Write-Fixture([string]$Path,[string]$Text) { [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)); [IO.File]::WriteAllText($Path,$Text) }
$base=Join-Path ([IO.Path]::GetTempPath()) ('reuse-tests-'+[guid]::NewGuid().ToString('N'))
$links=@()
try {
    $a='{"target":"windows-x64-native","dependencies":{"node":{"version":"24.15.0","asset":"node.zip","architecture":"win-x64"}}}'|ConvertFrom-Json
    $b='{"dependencies":{"node":{"architecture":"win-x64","asset":"node.zip","version":"24.15.0"}},"target":"windows-x64-native"}'|ConvertFrom-Json
    Check (Test-ImmichDependencyPinEqual $a $b node) 'JSON order must not affect identity.'
    $b.dependencies.node.asset='changed.zip'
    Check (-not (Test-ImmichDependencyPinEqual $a $b node)) 'Changed asset was reused.'
    $b.dependencies.node.asset='node.zip';$b.target='windows-arm64-native'
    Check (-not (Test-ImmichDependencyPinEqual $a $b node)) 'Wrong target was reused.'
    Check (-not (Test-ImmichDependencyPinEqual $a $b missing)) 'Missing pin matched.'
    $old=Join-Path $base 'install/releases/old';$new=Join-Path $base 'install/releases/new'
    foreach ($root in @($old,$new)) {
        foreach ($project in @('server','cli')) {
            foreach ($file in @('package.json','pnpm-lock.yaml','pnpm-workspace.yaml')) { Write-Fixture (Join-Path $root "$project/$file") 'same' }
        }
        Write-Fixture (Join-Path $root 'server/.immich/plugin-sdk/index.js') 'same'
    }
    Check (Test-ImmichDependencyInputsEqual $old $new server) 'Identical inputs did not match.'
    Write-Fixture (Join-Path $new 'server/pnpm-lock.yaml') 'changed'
    Check (-not (Test-ImmichDependencyInputsEqual $old $new server)) 'Changed lock reused.'
    Write-Fixture (Join-Path $new 'server/pnpm-lock.yaml') 'same'
    Write-Fixture (Join-Path $new 'server/.immich/plugin-sdk/index.js') 'changed'
    Check (-not (Test-ImmichDependencyInputsEqual $old $new server)) 'Changed SDK reused.'
    Check (Test-ImmichDependencyInputsEqual $old $new cli) 'Unchanged CLI was invalidated by server change.'
    $tree=Join-Path $base tree;$copy=Join-Path $base copy
    Write-Fixture (Join-Path $tree 'Lib/data.txt') 'original'
    Write-Fixture (Join-Path $tree 'Scripts/tool.exe') 'old-launcher'
    Copy-ImmichDependencyTree $tree $copy -ExcludeDirectoryNames Scripts
    Check (-not (Test-Path (Join-Path $copy Scripts))) 'Copied path-bound launcher.'
    Write-Fixture (Join-Path $copy 'Lib/data.txt') 'new'
    Check ((Get-Content -Raw (Join-Path $tree 'Lib/data.txt')) -ceq 'original') 'Donor was modified.'
    Reject { Copy-ImmichDependencyTree $tree $copy }
    Reject { Copy-ImmichDependencyTree $tree $tree }
    Reject { Copy-ImmichDependencyTree $tree (Join-Path $tree child) }
    $linked=Join-Path $base linked
    New-Item -ItemType Directory -Path $linked | Out-Null
    $link=Join-Path $linked alias
    New-Item -ItemType $(if($IsWindows){'Junction'}else{'SymbolicLink'}) -Path $link -Target $tree | Out-Null
    $links+=$link
    $rejected=Join-Path $base rejected
    Reject { Copy-ImmichDependencyTree $linked $rejected }
    Check (-not (Test-Path $rejected)) 'Rejected link copy created candidate.'
    Reject { Copy-ImmichDependencyTree (Join-Path $link Lib) $rejected }

    # The portability check shares the copy's preflight inventory. A rejected
    # runtime must never create a partial candidate or modify the donor.
    $pythonTree=Join-Path $base 'portable-python'
    Write-Fixture (Join-Path $pythonTree 'Lib/site-packages/relative.pth') './local-package'
    Write-Fixture (Join-Path $pythonTree 'Scripts/launcher.exe') 'path-bound launcher, excluded'
    Copy-ImmichDependencyTree $pythonTree (Join-Path $base 'portable-copy') -ExcludeDirectoryNames Scripts -PythonSourceRelease $old
    foreach ($bad in @(
        @{Name='pyvenv.cfg';Text='home = C:\old'},
        @{Name='bad.egg-link';Text='C:\old'},
        @{Name='absolute.pth';Text='C:\old\packages'},
        @{Name='absolute.pth';Text='/old/packages'},
        @{Name='absolute.pth';Text='\\server\share'},
        @{Name='absolute.pth';Text="import sys; sys.path.append('$old')"}
    )) {
        $badPath=Join-Path $pythonTree ('Lib/site-packages/'+$bad.Name)
        Write-Fixture $badPath $bad.Text
        Reject { Copy-ImmichDependencyTree $pythonTree $rejected -ExcludeDirectoryNames Scripts -PythonSourceRelease $old }
        Check (-not (Test-Path $rejected)) 'Rejected Python reuse created a candidate.'
        Remove-Item -LiteralPath $badPath
    }
    $nativeTree=Join-Path $base 'native-tree'
    Write-Fixture (Join-Path $nativeTree '@img/sharp-win32-x64/lib/replace.dll') 'old DLL'
    Write-Fixture (Join-Path $nativeTree '@img/sharp-win32-x64/lib/sharp.node') 'binding'
    Write-Fixture (Join-Path $nativeTree 'other/replace.dll') 'unrelated DLL'
    $nativeCopy=Join-Path $base 'native-copy'
    Copy-ImmichDependencyTree $nativeTree $nativeCopy -ExcludeRelativeFiles '@img/sharp-win32-x64/lib/replace.dll'
    Check (-not (Test-Path (Join-Path $nativeCopy '@img/sharp-win32-x64/lib/replace.dll'))) 'Copied a staged Sharp replacement unnecessarily.'
    Check (Test-Path (Join-Path $nativeCopy '@img/sharp-win32-x64/lib/sharp.node')) 'Excluded the Sharp Node binding.'
    Check (Test-Path (Join-Path $nativeCopy 'other/replace.dll')) 'Excluded a same-named unrelated DLL.'

    # Discovery is bounded to supported layouts. Nested executables and uv's
    # alias junction must not create ambiguity or redirect to another runtime.
    $pythonRelease=Join-Path $base 'python-release'
    Write-Fixture (Join-Path $pythonRelease 'manifest.json') '{"dependencies":{"python":{"version":"3.11.14"}}}'
    Check ($null -eq (Get-ImmichPythonExecutable $pythonRelease -AllowMissing)) 'Missing runtime could not be bootstrapped.'
    Reject { Get-ImmichPythonExecutable $pythonRelease }
    $pythonRoot=Join-Path $pythonRelease 'machine-learning/python-runtime'
    $distribution=Join-Path $pythonRoot 'cpython-3.11.14-windows-x86_64-none'
    $interpreter=Join-Path $distribution 'python.exe'
    Write-Fixture $interpreter 'interpreter'
    Write-Fixture (Join-Path $distribution 'Lib/site-packages/unused/python.exe') 'not an interpreter'
    Write-Fixture (Join-Path $distribution 'Scripts/python.exe') 'path-bound launcher'
    $alias=Join-Path $pythonRoot 'cpython-3.11-windows-x86_64-none'
    New-Item -ItemType $(if($IsWindows){'Junction'}else{'SymbolicLink'}) -Path $alias -Target $distribution | Out-Null
    $links+=$alias
    Check ((Get-ImmichPythonExecutable $pythonRelease).FullName -eq $interpreter) 'Pinned interpreter or alias handling changed.'
    Write-Fixture (Join-Path $pythonRoot 'python.exe') 'legacy interpreter'
    Reject { Get-ImmichPythonExecutable $pythonRelease }
    Remove-Item -LiteralPath (Join-Path $pythonRoot 'python.exe')
    $wrong=Join-Path $pythonRoot 'cpython-3.12.0-windows-x86_64-none/python.exe'
    Write-Fixture $wrong 'wrong version'
    Reject { Get-ImmichPythonExecutable $pythonRelease }
    Remove-Item -LiteralPath (Split-Path $wrong) -Recurse
    [IO.Directory]::Delete($alias);$links=@($links | Where-Object { $_ -ne $alias })
    Remove-Item -LiteralPath $distribution -Recurse
    Write-Fixture (Join-Path $pythonRoot 'python.exe') 'legacy interpreter'
    Check ((Get-ImmichPythonExecutable $pythonRelease).FullName -eq (Join-Path $pythonRoot 'python.exe')) 'Legacy flat interpreter was rejected.'

    $zipSource=Join-Path $base 'zip-source'
    Write-Fixture (Join-Path $zipSource 'dependencies/sharp/lib/needed.dll') 'selected bytes'
    Write-Fixture (Join-Path $zipSource 'dependencies/postgres-extensions/unused.dll') 'unused bytes'
    $archive=Join-Path $base 'native.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($zipSource,$archive)
    $extracted=Join-Path $base 'extracted'
    Expand-ImmichNativePayload $archive $extracted @('dependencies/sharp/lib/needed.dll')
    Check ((Get-Content -Raw (Join-Path $extracted 'dependencies/sharp/lib/needed.dll')) -ceq 'selected bytes') 'Selected native entry changed.'
    Check (-not (Test-Path (Join-Path $extracted 'dependencies/postgres-extensions'))) 'Expanded unused native payload.'
    foreach ($invalid in @('../escape.dll','/escape.dll','C:/escape.dll','a\escape.dll')) {
        Reject { Expand-ImmichNativePayload $archive $extracted @($invalid) }
    }
    Reject { Expand-ImmichNativePayload $archive $extracted @('missing.dll') }
    Reject { Expand-ImmichNativePayload $archive $extracted @('same.dll','SAME.dll') }
    $duplicateZip=Join-Path $base 'duplicate.zip'
    $zip=[IO.Compression.ZipFile]::Open($duplicateZip,[IO.Compression.ZipArchiveMode]::Create)
    try { [void]$zip.CreateEntry('same.dll');[void]$zip.CreateEntry('same.dll') } finally { $zip.Dispose() }
    Reject { Expand-ImmichNativePayload $duplicateZip $extracted @('same.dll') }

    # Run the real Node installer against completed fixture dependencies. Its
    # native tools are deliberately non-executable: no npm/pnpm work is needed.
    $nodeRelease=Join-Path $base 'node-release'
    $nodeInstall=Join-Path $base 'node-install'
    foreach ($project in @('server','cli')) {
        Write-Fixture (Join-Path $nodeRelease "$project/package.json") '{"dependencies":{}}'
        foreach ($metadata in @('pnpm-lock.yaml','pnpm-workspace.yaml')) { Write-Fixture (Join-Path $nodeRelease "$project/$metadata") 'fixture' }
        [void][IO.Directory]::CreateDirectory((Join-Path $nodeRelease "$project/node_modules"))
    }
    Write-Fixture (Join-Path $nodeRelease 'server/.immich/plugin-sdk/index.js') 'sdk fixture'
    foreach ($tool in @('node.exe','npm.cmd')) { Write-Fixture (Join-Path $nodeRelease "runtime/node/$tool") 'must not execute' }
    $stage=Join-Path $nodeRelease 'dependencies/sharp/lib'
    $lib=Join-Path $nodeRelease 'server/node_modules/@img/sharp-win32-x64/lib'
    $inventory=[ordered]@{}
    foreach ($name in @('same.dll','changed.dll','last.dll')) {
        Write-Fixture (Join-Path $stage $name) "expected $name"
        $inventory["dependencies/sharp/lib/$name"]=(Get-FileHash -LiteralPath (Join-Path $stage $name) -Algorithm SHA256).Hash
        Write-Fixture (Join-Path $lib $name) $(if($name -eq 'same.dll'){"expected $name"}else{'old bytes'})
    }
    Write-Fixture (Join-Path $lib 'obsolete.dll') 'stale DLL'
    Write-Fixture (Join-Path $lib 'sharp.node') 'preserved binding'
    Write-Fixture (Join-Path $nodeRelease 'dependencies/sharp/versions.json') '{"vips":"fixture"}'
    # Fresh pnpm installs can hardlink both binaries and metadata to the store.
    # Injection must replace the candidate directory entry, not shared bytes.
    $sharpStore = Join-Path $base 'sharp-store'
    Write-Fixture (Join-Path $sharpStore 'changed.dll') 'original store DLL'
    Write-Fixture (Join-Path $sharpStore 'last.dll') 'original last DLL'
    Write-Fixture (Join-Path $sharpStore 'versions.json') '{"vips":"original-store"}'
    Remove-Item -LiteralPath (Join-Path $lib 'changed.dll')
    New-Item -ItemType HardLink -Path (Join-Path $lib 'changed.dll') -Target (Join-Path $sharpStore 'changed.dll') | Out-Null
    Remove-Item -LiteralPath (Join-Path $lib 'last.dll')
    New-Item -ItemType HardLink -Path (Join-Path $lib 'last.dll') -Target (Join-Path $sharpStore 'last.dll') | Out-Null
    $installedVersions = Join-Path (Split-Path -Parent $lib) 'versions.json'
    New-Item -ItemType HardLink -Path $installedVersions -Target (Join-Path $sharpStore 'versions.json') | Out-Null
    Write-Fixture (Join-Path $nodeRelease 'manifest.json') (@{dependencies=@{node=@{version='24.15.0'};pnpm=@{version='10.0.0'}};nativeDependencyFiles=$inventory}|ConvertTo-Json -Depth 6)
    $completion=@{node='24.15.0';pnpm='10.0.0';server=(Get-ImmichDependencyInputHash $nodeRelease server);cli=(Get-ImmichDependencyInputHash $nodeRelease cli)}
    Write-Fixture (Join-Path $nodeRelease '.node-dependencies-installed.json') ($completion|ConvertTo-Json)
    $nodeInstaller=Join-Path $PSScriptRoot '../runtime/launchers/Install-NodeDependencies.ps1'
    & {
        $copyState=@{Fail=$true;Calls=[Collections.Generic.List[string]]::new()}
        function Copy-Item {
            param([string]$LiteralPath,[string]$Destination,[switch]$Force)
            $copyState.Calls.Add((Split-Path -Leaf $LiteralPath))
            if ($copyState.Fail -and $LiteralPath -like '*last.dll') {
                [IO.File]::WriteAllText($Destination,'partial transfer')
                throw 'Injected Sharp copy failure.'
            }
            Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
        }
        Reject { & $nodeInstaller -ReleaseRoot $nodeRelease -InstallRoot $nodeInstall }
        Check (@($copyState.Calls | Where-Object { $_ -eq 'same.dll' }).Count -eq 0) 'Rewrote an identical Sharp DLL.'
        Check (Test-Path (Join-Path $stage 'changed.dll')) 'A partial injection consumed reusable staging.'
        Check (Test-Path (Join-Path $stage 'last.dll')) 'A partial injection lost the remaining staged DLL.'
        Check ((Get-Content -Raw (Join-Path $sharpStore 'changed.dll')) -ceq 'original store DLL') 'Sharp DLL injection modified the pnpm store.'
        Check ((Get-Content -Raw (Join-Path $lib 'last.dll')) -ceq 'original last DLL') 'A failed copy partially overwrote the installed DLL.'
        Check ((Get-Content -Raw (Join-Path $sharpStore 'versions.json')) -ceq '{"vips":"original-store"}') 'Failed injection modified shared Sharp metadata.'
        Check (@(Get-ChildItem -LiteralPath $lib -Filter '.sharp-replacement-*' -Force).Count -eq 0) 'Failed injection left a temporary replacement.'
        $copyState.Fail=$false
        if ($IsWindows) {
            # An in-use destination must fail publication, never fall back to a
            # write-through copy or lose the retained retry source.
            $locked = [IO.File]::Open((Join-Path $lib 'last.dll'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            try { Reject { & $nodeInstaller -ReleaseRoot $nodeRelease -InstallRoot $nodeInstall } }
            finally { $locked.Dispose() }
            Check ((Get-Content -Raw (Join-Path $lib 'last.dll')) -ceq 'original last DLL') 'Failed publication replaced the old DLL.'
            Check (Test-Path (Join-Path $stage 'last.dll')) 'Failed publication consumed retry staging.'
            Check (@(Get-ChildItem -LiteralPath $lib -Filter '.sharp-replacement-*' -Force).Count -eq 0) 'Failed publication left a temporary replacement.'
        }
        & $nodeInstaller -ReleaseRoot $nodeRelease -InstallRoot $nodeInstall
        foreach ($name in @('same.dll','changed.dll','last.dll')) {
            Check ((Get-Content -Raw (Join-Path $lib $name)) -ceq "expected $name") 'Sharp retry did not install the complete DLL set.'
        }
        Check (@($copyState.Calls | Where-Object { $_ -eq 'changed.dll' }).Count -eq 1) 'Retry rewrote a previously completed DLL.'
        Check (-not (Test-Path (Join-Path $lib 'obsolete.dll'))) 'Retained a stale Sharp DLL.'
        Check ((Get-Content -Raw (Join-Path $lib 'sharp.node')) -ceq 'preserved binding') 'Removed the Sharp Node binding.'
        Check ((Get-Content -Raw (Join-Path $sharpStore 'changed.dll')) -ceq 'original store DLL') 'Retry modified the pnpm DLL store.'
        Check ((Get-Content -Raw (Join-Path $sharpStore 'last.dll')) -ceq 'original last DLL') 'Retry modified the pnpm last-DLL store.'
        Check ((Get-Content -Raw (Join-Path $sharpStore 'versions.json')) -ceq '{"vips":"original-store"}') 'Sharp metadata injection modified the pnpm store.'
        Check ((Get-Content -Raw $installedVersions) -ceq '{"vips":"fixture"}') 'Sharp metadata was not replaced.'
        Write-Fixture (Join-Path $lib 'changed.dll') 'later candidate change'
        Write-Fixture $installedVersions '{"vips":"later-candidate"}'
        Check ((Get-Content -Raw (Join-Path $sharpStore 'changed.dll')) -ceq 'original store DLL') 'Injected DLL retained a hardlink to the store.'
        Check ((Get-Content -Raw (Join-Path $sharpStore 'versions.json')) -ceq '{"vips":"original-store"}') 'Injected metadata retained a hardlink to the store.'
        Check (@(Get-ChildItem -LiteralPath (Split-Path -Parent $lib) -Filter '.sharp-replacement-*' -Recurse -Force).Count -eq 0) 'Successful injection left a temporary replacement.'
        Check (-not (Test-Path $stage)) 'Successful injection retained staging.'
    }
    Check ((Get-ImmichProgressText copy ja-JP) -eq (Get-ImmichProgressText copy ja_JP)) 'Japanese regional tags differ.'
    Check ((Get-ImmichProgressText copy fr-FR) -eq (Get-ImmichProgressText copy en-US)) 'Unsupported locale must use English.'
    $state=Start-ImmichProgress -Key copy -Detail 'progress fixture' 6>$null
    Check ($state -is [System.Collections.IDictionary]) 'Progress polluted success output.'
    $quiet=@(Update-ImmichProgress -State $state -Completed 1 -Total 4 6>&1)
    Check ($quiet.Count -eq 0) 'Progress output was not throttled.'
    $tick=@(Update-ImmichProgress -State $state -Completed 2 -Total 4 -Force 6>&1)
    Check ($tick.Count -eq 1 -and ([string]$tick[0]).Contains('2/4')) 'Actual progress count missing.'
    $finish=@(Update-ImmichProgress -State $state -Completed 4 -Total 4 -Finished 6>&1)
    Check ($finish.Count -eq 1 -and $state.Finished) 'Final progress missing.'
    $again=@(Update-ImmichProgress -State $state -Finished 6>&1)
    Check ($again.Count -eq 0) 'Completed progress emitted twice.'
    Write-Host 'PASS dependency reuse: input identity, independent copies, portable Python, bounded discovery, precise Sharp exclusions, selective ZIP extraction, unsafe links.'
} finally {
    foreach($link in $links){[IO.Directory]::Delete($link)}
    if(Test-Path $base){Remove-Item -LiteralPath $base -Recurse -Force}
}
