#requires -Version 7.0
# Real directory renames and recovery, without native programs or a network.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../runtime/Common.psm1') -Force
function Check([bool]$Value,[string]$Message) { if (-not $Value) { throw $Message } }
function Reject([scriptblock]$Action) { $failed=$false;try { & $Action } catch { $failed=$true };Check $failed 'Unsafe operation was accepted.' }
function Write-Fixture([string]$Path,[string]$Text) { [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path));[IO.File]::WriteAllText($Path,$Text) }
$base=Join-Path ([IO.Path]::GetTempPath()) ('dependency-transfer-'+[guid]::NewGuid().ToString('N'))
$old=Join-Path $base 'install/releases/old';$new=Join-Path $base 'install/releases/new'
try {
 [void][IO.Directory]::CreateDirectory($new)
 $plan=[Collections.Generic.List[object]]::new()
 foreach ($relative in @('runtime/node','runtime/ffmpeg')) {
  Write-Fixture (Join-Path $old "$relative/tree/deep/payload") "unchanged $relative"
  Add-ImmichDependencyReuse -Plan $plan -PreviousRelease $old -CandidateRelease $new -RelativePath $relative -Label $relative
 }
 Check ($plan.Count -eq 2) 'An empty plan was lost through parameter binding.'
 Check (-not (Test-Path (Join-Path $new runtime/node))) 'Planning copied dependency files.'
 Check ((Get-ImmichDependencyReadPath -Path (Join-Path $new 'runtime/node/tree/deep/payload') -DependencyReusePlan $plan) -eq (Join-Path $old 'runtime/node/tree/deep/payload')) 'Deferred read did not resolve the exact source.'
 Move-ImmichReusedDependencies $plan $old $new
 foreach ($relative in @('runtime/node','runtime/ffmpeg')) {
  Check (-not (Test-Path (Join-Path $old $relative))) 'Rename left an independent old tree.'
  Check ((Get-Content -Raw (Join-Path $new "$relative/tree/deep/payload")) -ceq "unchanged $relative") 'Rename changed the dependency.'
 }
 # Recover from the same serialized state a process crash leaves behind.
 $saved=($plan.ToArray() | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable)
 Move-ImmichReusedDependencies $saved $old $new -Restore
 Move-ImmichReusedDependencies $saved $old $new -Restore
 Check (Test-Path (Join-Path $old 'runtime/node/tree/deep/payload')) 'Recovery did not restore the source.'
 Check (-not (Test-Path (Join-Path $new 'runtime/node'))) 'Recovery copied instead of moving.'
 # Simulate interruption between directory renames; never need a per-file log.
 [void][IO.Directory]::CreateDirectory((Join-Path $new runtime))
 [IO.Directory]::Move((Join-Path $old 'runtime/node'),(Join-Path $new 'runtime/node'))
 Move-ImmichReusedDependencies $saved $old $new -Restore
 Check (Test-Path (Join-Path $old runtime/node)) 'Partial transfer was not recovered.'
 $bad=[pscustomobject]@{relativePath='../../outside';source=(Join-Path $base outside);destination=(Join-Path $new outside);label='bad'}
 Reject { Move-ImmichReusedDependencies @($bad) $old $new }
 $bad.relativePath='runtime/node';$bad.source=Join-Path $base outside
 Reject { Move-ImmichReusedDependencies @($bad) $old $new -Restore }
 Reject { Add-ImmichDependencyReuse $plan $old $new 'runtime/node' duplicate }
 Write-Host 'PASS dependency transfer: unchanged directories, no copy, bounded reads, serialized/partial/idempotent recovery, path rejection.'

 $manifest=@{immichVersion='v3.2.4';target='windows-x64-native';dependencies=@{python=@{version='3.11.14'}}}
 $distribution='machine-learning/python-runtime/cpython-3.11.14-windows-x86_64-none'
 foreach ($root in @($old,$new)) {
  Write-Fixture (Join-Path $root manifest.json) ($manifest | ConvertTo-Json -Depth 5)
  Write-Fixture (Join-Path $root 'machine-learning/requirements.txt') 'numpy==1.0'
 }
 Write-Fixture (Join-Path $old "$distribution/python.exe") python
 Write-Fixture (Join-Path $old "$distribution/Lib/site-packages/numpy/nested/data.txt") data
 Write-Fixture (Join-Path $old "$distribution/Scripts/old-path.exe") 'unused console entry point'
 $hash=(Get-FileHash (Join-Path $new 'machine-learning/requirements.txt')).Hash.ToLowerInvariant()
 Write-Fixture (Join-Path $old 'machine-learning/.dependencies-installed.json') (@{python='3.11.14';requirementsSha256=$hash}|ConvertTo-Json)
 $inputs=@{}
 Check (Test-ImmichPythonDependencyReusable $old $new -Inputs $inputs) 'Identical Python packages were not reusable.'
 Check ($inputs.requirementsSha256 -ceq $hash) 'Requirements input hash was not retained for the ML marker.'
 Write-Fixture (Join-Path $new 'machine-learning/requirements.txt') 'numpy==2.0'
 Check (-not (Test-ImmichPythonDependencyReusable $old $new)) 'Changed requirements were reused.'
 Write-Fixture (Join-Path $new 'machine-learning/requirements.txt') 'numpy==1.0'
 foreach ($badFile in @('pyvenv.cfg','Lib/site-packages/local.egg-link','Lib/site-packages/absolute.pth')) {
  $path=Join-Path $old "$distribution/$badFile"
  Write-Fixture $path 'C:\old\packages'
  Check (-not (Test-ImmichPythonDependencyReusable $old $new)) "Path-bound Python was reused: $badFile"
  Remove-Item -LiteralPath $path
 }
 Write-Fixture (Join-Path $old "$distribution/Lib/site-packages/relative.pth") './relative'
 Check (Test-ImmichPythonDependencyReusable $old $new) 'A relative Python path was rejected.'
 # Deferred ML installation writes its marker from the already-computed input;
 # it must not discover Python, run uv, or enumerate/copy the old package tree.
 Write-Fixture (Join-Path $new 'runtime/Common.psm1') (Get-Content -Raw (Join-Path $PSScriptRoot '../runtime/Common.psm1'))
 Write-Fixture (Join-Path $new 'installer/Install-MachineLearningDependencies.ps1') (Get-Content -Raw (Join-Path $PSScriptRoot '../packaging/Install-MachineLearningDependencies.ps1'))
 $manifest.dependencies.uv=@{version='0.12.18'}
 Write-Fixture (Join-Path $new manifest.json) ($manifest | ConvertTo-Json -Depth 5)
 $pythonPlan=[Collections.Generic.List[object]]::new()
 Add-ImmichDependencyReuse $pythonPlan $old $new $distribution Python
 $pythonPlan[0] | Add-Member -NotePropertyName requirementsSha256 -NotePropertyValue $hash
 & (Join-Path $new 'installer/Install-MachineLearningDependencies.ps1') -ReleaseRoot $new -InstallRoot (Join-Path $base install) -DependencyReusePlan $pythonPlan
 $state=Get-Content -Raw (Join-Path $new 'machine-learning/.dependencies-installed.json')|ConvertFrom-Json
 Check ($state.requirementsSha256 -ceq $hash) 'Deferred ML marker differs from its proven inputs.'
 Check (-not (Test-Path (Join-Path $new $distribution))) 'Deferred ML installer copied packages.'
 Write-Host 'PASS Python transfer eligibility: installed requirements, changed dependencies, bounded portability checks, module-only Scripts, no duplicate preparation.'
} finally { if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force } }
