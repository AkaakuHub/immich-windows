#requires -Version 7.0
[CmdletBinding()]
param([string]$SourceRoot)
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}

$scriptRoots=@('build','packaging','migration','runtime','tests')
$parseErrors=@()
$scriptFiles=@()
foreach($dir in $scriptRoots){
    $path=Join-Path $root $dir
    if(-not(Test-Path $path)){continue}
    foreach($file in Get-ChildItem -LiteralPath $path -Recurse -File | Where-Object {$_.Extension -in @('.ps1','.psm1')}){
        $scriptFiles += $file
        $tokens=$null;$errors=$null
        [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
        foreach($parseIssue in @($errors)){$parseErrors += "$($file.FullName):$($parseIssue.Extent.StartLineNumber): $($parseIssue.Message)"}
    }
}
if($parseErrors.Count){throw "PowerShell parse errors:`n$($parseErrors -join "`n")"}

$commonModule=Join-Path $root 'build\Common.psm1'
Import-Module $commonModule -Force
foreach($helper in @('Get-CachedDownload','Expand-ZipClean','Assert-FileExists','Invoke-Native')){
    $command=Get-Command $helper -ErrorAction SilentlyContinue
    Assert-True ($null -ne $command) "build/Common.psm1 did not export required helper: $helper"
}

foreach($requiredFile in @('packaging/Recover-Upgrade.ps1','packaging/Update.ps1','migration/New-DatabaseBackup.ps1','migration/Import-Database.ps1')){
    Assert-True (Test-Path -LiteralPath (Join-Path $root $requiredFile) -PathType Leaf) "Missing release recovery component: $requiredFile"
}

$runtimeCommon=Join-Path $root 'runtime\Common.psm1'
Import-Module $runtimeCommon -Force
$envRoundTrip=Join-Path ([IO.Path]::GetTempPath()) ("immich-windows-env-"+[guid]::NewGuid().ToString('N')+".env")
try {
    $expectedPassword=' leading=middle trailing '
    Write-EnvFile -Path $envRoundTrip -Values ([ordered]@{DB_PASSWORD=$expectedPassword;DB_DATABASE_NAME='immich'})
    $parsedEnv=Read-EnvFile $envRoundTrip
    Assert-True ([string]$parsedEnv.DB_PASSWORD -ceq $expectedPassword) 'Env parsing must preserve password whitespace and embedded equals signs exactly.'
    [IO.File]::WriteAllText($envRoundTrip, "# source env`r`nexport DB_PASSWORD=`" leading=middle trailing # literal `"`r`nDB_HOSTNAME=database`r`n", [Text.UTF8Encoding]::new($false))
    $parsedEnv=Read-EnvFile $envRoundTrip
    Assert-True ([string]$parsedEnv.DB_PASSWORD -ceq ' leading=middle trailing # literal ') 'Env parsing must preserve quoted passwords and ignore export/comment lines.'
    Assert-True ([string]$parsedEnv.DB_HOSTNAME -ceq 'database') 'Env parsing must read unquoted source values.'
} finally { Remove-Item -LiteralPath $envRoundTrip -Force -ErrorAction SilentlyContinue }

$upstream=Get-Content -Raw -LiteralPath (Join-Path $root 'upstream.json')|ConvertFrom-Json
Assert-True ($upstream.version -match '^v[0-9]+\.[0-9]+\.[0-9]+$') "Invalid upstream version: $($upstream.version)"
Assert-True ($upstream.commit -match '^[0-9a-f]{40}$') 'upstream.json must pin a full 40-character commit SHA.'

$packageTag = Get-WindowsReleaseVersion $upstream
$legacy = [pscustomobject]@{ schemaVersion=1; immichVersion='v3.2.2' }
$revision1 = [pscustomobject]@{ schemaVersion=2; immichVersion='v3.2.2'; windowsRevision=1; packageVersion='v3.2.2.1' }
$revision2 = [pscustomobject]@{ schemaVersion=2; immichVersion='v3.2.2'; windowsRevision=2; packageVersion='v3.2.2.2' }
$revision10 = [pscustomobject]@{ schemaVersion=2; immichVersion='v3.2.2'; windowsRevision=10; packageVersion='v3.2.2.10' }
$nextUpstream = [pscustomobject]@{ schemaVersion=2; immichVersion='v3.2.3'; windowsRevision=1; packageVersion='v3.2.3.1' }
Assert-True ((Get-WindowsPackageVersion $legacy) -lt (Get-WindowsPackageVersion $revision1)) 'Legacy installs must update to revision 1.'
Assert-True ((Get-WindowsPackageVersion $revision1) -lt (Get-WindowsPackageVersion $revision2)) 'Same-upstream revisions must compare numerically.'
Assert-True ((Get-WindowsPackageVersion $revision2) -lt (Get-WindowsPackageVersion $revision10)) 'Revision 10 must follow revision 2.'
Assert-True ((Get-WindowsPackageVersion $revision10) -lt (Get-WindowsPackageVersion $nextUpstream)) 'A newer upstream version must follow any previous revision.'
foreach ($invalid in @(
    [pscustomobject]@{ schemaVersion=2; immichVersion='v3.2.2' },
    [pscustomobject]@{ schemaVersion=2; immichVersion='v3.2.2'; windowsRevision=0; packageVersion='v3.2.2.0' },
    [pscustomobject]@{ schemaVersion=2; immichVersion='v3.2.2'; windowsRevision=1; packageVersion='v3.2.2.2' }
)) {
    $rejected=$false
    try { Get-WindowsPackageVersion $invalid | Out-Null } catch { $rejected=$true }
    Assert-True $rejected 'Invalid or conflicting revision metadata must be rejected.'
}

# Cheap content-comparison regression: no extra dump for ML-only changes; DB-facing changes require it.
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('immich-db-policy-'+[guid]::NewGuid().ToString('N'))
try {
    $left=Join-Path $fixtureRoot old
    $right=Join-Path $fixtureRoot new
    foreach ($directory in @($left,$right)) {
        New-Item -ItemType Directory $directory -Force | Out-Null
        $manifest=[ordered]@{immichVersion='v3.2.2';upstreamCommit=('a'*40);dependencies=[ordered]@{node=@{version='24.15.0'};postgresql=@{version='18.3'};pgvector=@{version='0.8.2'};vectorchord=@{version='0.4.3'}}}
        $manifest|ConvertTo-Json -Depth 10|Set-Content (Join-Path $directory 'manifest.json')
        foreach ($name in @('server/package.json','server/pnpm-lock.yaml','server/pnpm-workspace.yaml','server/dist/main.js','server/.immich/plugin-sdk/index.js','dependencies/postgres-extensions/vector/vector.dll','runtime/vc-runtime/runtime.dll','runtime/node/node.exe','machine-learning/app.py')) {
            $path=Join-Path $directory $name
            New-Item -ItemType Directory (Split-Path $path) -Force|Out-Null
            Set-Content $path 'identical payload'
        }
    }
    Assert-True (Test-ImmichDatabasePayloadEqual $left $right) 'Identical server and DB payloads should not require an upgrade-only dump.'
    Set-Content (Join-Path $right 'machine-learning/app.py') 'DirectML-only change'
    Assert-True (Test-ImmichDatabasePayloadEqual $left $right) 'ML-only changes must not force a DB dump.'
    foreach ($name in @('server/dist/main.js','server/pnpm-lock.yaml','dependencies/postgres-extensions/vector/vector.dll','runtime/node/node.exe')) {
        $path=Join-Path $right $name
        Set-Content $path 'changed database-facing payload'
        Assert-True (-not (Test-ImmichDatabasePayloadEqual $left $right)) "DB-facing change must require backup: $name"
        Set-Content $path 'identical payload'
    }
    Remove-Item (Join-Path $right 'server/pnpm-lock.yaml')
    Assert-True (-not (Test-ImmichDatabasePayloadEqual $left $right)) 'Missing proof must not skip the DB backup.'
} finally { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue }

$seriesPath=Join-Path $root 'patches/series'
Assert-True (Test-Path -LiteralPath $seriesPath -PathType Leaf) 'patches/series is required.'
$series=@(Get-Content -LiteralPath $seriesPath|ForEach-Object{$_.Trim()}|Where-Object{$_ -and -not $_.StartsWith('#')})
$listed=@($series|ForEach-Object{(Join-Path (Join-Path $root 'patches') $_)})
$all=@(Get-ChildItem -LiteralPath (Join-Path $root 'patches') -Recurse -Filter '*.patch' -File|Select-Object -ExpandProperty FullName)
Assert-True ($all.Count -eq $listed.Count) 'Every .patch file must be listed exactly once in patches/series.'
foreach($file in $listed){Assert-True (Test-Path -LiteralPath $file -PathType Leaf) "Missing patch file: $file"}
foreach($file in $all){Assert-True ($file -in $listed) "Unlisted patch file: $file"}

# Parse each patch without requiring an upstream working tree. This catches malformed
# unified-diff hunk headers before the networked Prepare-Source CI stage.
foreach($relative in $series){
    $patch=Join-Path (Join-Path $root 'patches') $relative
    $output=& git apply --numstat -- $patch 2>&1
    Assert-True ($LASTEXITCODE -eq 0) "Malformed patch file: $relative`n$($output -join "`n")"
}

# This repository is a distribution/patch layer, not an Immich source fork.
foreach($forbiddenRoot in @('server','web','mobile','machine-learning','packages','docker')){
    Assert-True (-not(Test-Path -LiteralPath (Join-Path $root $forbiddenRoot))) "Upstream Immich source directory must not be tracked at repository root: $forbiddenRoot"
}
Assert-True (-not(Test-Path -LiteralPath (Join-Path $root '.gitmodules'))) 'Do not add Immich as a git submodule; source is fetched from the pinned tag at build time.'

$versions=Get-Content -Raw -LiteralPath (Join-Path $root 'dependencies/versions.json')|ConvertFrom-Json
Assert-True ([int]$versions.postgresql.major -eq ([version]$versions.postgresql.version).Major) 'PostgreSQL major and version differ.'
foreach($name in @('node','pnpm','sharp','pgvector','vectorchord','sharpLibvips')){
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$versions.$name.version)) "Missing dependency version: $name"
}
$mediaPatch=Join-Path $root ([string]$versions.sharpLibvips.immichLoaderPatch)
Assert-True (Test-Path -LiteralPath $mediaPatch -PathType Leaf) 'Pinned Immich base-image libvips loader patch is missing.'

Write-Host "Static repository audit passed for $($scriptFiles.Count) PowerShell files."

if ($SourceRoot) {
    $policyTest = @'
import ast
import sys
import time
from pathlib import Path
from threading import Lock
from types import SimpleNamespace
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import Mock

source = Path(sys.argv[1]) / 'machine-learning/immich_ml/sessions/ort.py'
tree = ast.parse(source.read_text(encoding='utf-8'))
cls = next(n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == 'OrtSession')
module = ast.Module(body=[ast.ImportFrom(module='__future__', names=[ast.alias(name='annotations')], level=0), cls], type_ignores=[])
seq, parallel = SimpleNamespace(name='SEQ'), SimpleNamespace(name='PARALLEL')
class Options:
    def __init__(self):
        self.enable_mem_pattern = True
        self.execution_mode = parallel
        self.inter_op_num_threads = 4
        self.intra_op_num_threads = 3
        self.entries = {}
    def add_session_config_entry(self, key, value):
        self.entries[key] = value
settings = SimpleNamespace(accelerator='directml', device_id='2', model_arena=True, model_inter_op_threads=4, model_intra_op_threads=3)
factory = Mock()
ort = SimpleNamespace(InferenceSession=factory, SessionOptions=Options, ExecutionMode=SimpleNamespace(ORT_SEQUENTIAL=seq, ORT_PARALLEL=parallel), get_available_providers=lambda: ['CPUExecutionProvider','DmlExecutionProvider'])
globals_ = dict(Path=Path, Lock=Lock, log=Mock(), ort=ort, settings=settings)
exec(compile(ast.fix_missing_locations(module), str(source), 'exec'), globals_)
Session=globals_['OrtSession']
def fresh(providers=None, options=None):
    factory.reset_mock(return_value=True, side_effect=True)
    factory.return_value.get_providers.return_value=['DmlExecutionProvider']
    return Session('model.onnx', providers=providers, sess_options=options)
def raises(fn, typ):
    try: fn()
    except typ: return
    raise AssertionError(f'Expected {typ.__name__}')

s=fresh()
kw=factory.call_args.kwargs
assert kw['enable_fallback'] is False
assert kw['providers']==['DmlExecutionProvider']
assert kw['provider_options']==[{'device_id':'2'}]
assert kw['sess_options'].enable_mem_pattern is False
assert kw['sess_options'].execution_mode is seq
assert kw['sess_options'].entries=={'session.disable_cpu_ep_fallback':'1'}
custom=Options();s=fresh(options=custom)
assert custom.enable_mem_pattern is False and custom.execution_mode is seq
assert custom.entries['session.disable_cpu_ep_fallback']=='1'
raises(lambda: fresh(['CPUExecutionProvider']), ValueError)
raises(lambda: fresh(['DmlExecutionProvider','CPUExecutionProvider']), ValueError)
ort.get_available_providers=lambda:['CPUExecutionProvider']
raises(lambda: fresh(), RuntimeError)
assert factory.call_count==0
ort.get_available_providers=lambda:['CPUExecutionProvider','DmlExecutionProvider']
factory.reset_mock();factory.side_effect=RuntimeError('provider init failure')
raises(lambda:Session('model.onnx'),RuntimeError)
assert factory.call_count==1 and factory.call_args.kwargs['enable_fallback'] is False
s=fresh();s.session.run.side_effect=RuntimeError('execution failure')
raises(lambda:s.run(None,{}),RuntimeError)
assert factory.call_count==1 and s.session.run.call_count==1
s=fresh();gate=Lock();active=0;peak=0
def run(*args):
    global active,peak
    with gate:
        active+=1;peak=max(peak,active)
    time.sleep(.01)
    with gate: active-=1
    return []
s.session.run.side_effect=run
with ThreadPoolExecutor(max_workers=4) as pool:
    list(pool.map(lambda _:s.run(None,{}),range(8)))
assert peak==1
settings.accelerator='cpu';s=fresh()
assert s.providers==['CPUExecutionProvider'] and s._run_lock is None
assert s.sess_options.enable_mem_pattern is True and not s.sess_options.entries
settings.accelerator='directml'
factory.reset_mock(return_value=True,side_effect=True)
factory.return_value.get_providers.return_value=['CPUExecutionProvider']
raises(lambda:Session('model.onnx'),RuntimeError)
print('DirectML policy: 11 cases passed (mocked ORT; no hardware inference claim).')
'@
    & python -c $policyTest $SourceRoot
    if ($LASTEXITCODE -ne 0) { throw 'DirectML policy tests failed.' }
}
