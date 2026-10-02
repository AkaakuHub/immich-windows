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
    Write-Host 'PASS dependency reuse: pin identity, changed inputs, independent copies, Scripts exclusions, unsafe links.'
} finally {
    foreach($link in $links){[IO.Directory]::Delete($link)}
    if(Test-Path $base){Remove-Item -LiteralPath $base -Recurse -Force}
}
