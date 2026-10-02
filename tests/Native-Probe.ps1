#requires -Version 7.0
# Isolated regression tests: only disposable child processes and fixture files.
# Never connect to an Immich server, database, Redis, or Windows service.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Import-Module (Join-Path $repo 'runtime/Native-Probe.psm1') -Force
$base = Join-Path ([IO.Path]::GetTempPath()) ('immich-native-probe-' + [guid]::NewGuid().ToString('N'))
$pwsh = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
$previous = @{}
foreach ($name in @('G_DEBUG','OS','IMMICH_NATIVE_TEST_MODE')) { $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Expect-Failure([scriptblock]$Action, [string]$Expected) {
    $failure = $null
    try { & $Action | Out-Null } catch { $failure = $_.Exception.Message }
    Check ($null -ne $failure -and $failure -like $Expected) "Expected failure '$Expected'; got '$failure'."
}

try {
    New-Item -ItemType Directory -Path $base | Out-Null
    $child = Join-Path $base 'child probe.ps1'
    @'
param([string]$Mode, [string]$Value)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$argumentCodeUnits = [int[]][char[]]$Value -join ','
if ($Mode -eq 'critical-zero') {
    # Simulate a launcher overriding its inherited env and a native logger which
    # returns success despite the critical (the original release regression).
    $env:G_DEBUG = 'gc-friendly'
    [Console]::Error.WriteLine('(process:123): GLib-CRITICAL **: TLS callback not invoked')
} elseif ($Mode -eq 'critical-stdout') {
    [Console]::Out.WriteLine('(process:123): GLib-GObject-CRITICAL **: fixture critical')
} elseif ($Mode -eq 'fatal') {
    if ($env:G_DEBUG -notmatch 'fatal-criticals') { exit 99 }
    [Console]::Error.WriteLine('native fatal-criticals termination fixture')
    exit 27
} elseif ($Mode -eq 'silent-failure') {
    exit 28
} elseif ($Mode -eq 'large') {
    # Exceed typical pipe buffers on both streams; the parent must drain both.
    [Console]::Error.Write(('e' * 262144))
    $Value = 'o' * 262144
} else {
    [Console]::Error.WriteLine('ordinary diagnostic')
}
[Console]::Out.Write((@{ debug = $env:G_DEBUG; value = $Value; argumentCodeUnits = $argumentCodeUnits } | ConvertTo-Json -Compress))
'@ | Set-Content -LiteralPath $child
    $oldStderr = [Console]::Error
    $capturedStderr = [IO.StringWriter]::new()
    try {
        [Console]::SetError($capturedStderr)
        foreach ($debug in @($null, 'gc-friendly,fatal-warnings')) {
            if ($null -eq $debug) { Remove-Item Env:G_DEBUG -ErrorAction SilentlyContinue }
            else { [Environment]::SetEnvironmentVariable('G_DEBUG', $debug, 'Process') }
            $expectedParent = [Environment]::GetEnvironmentVariable('G_DEBUG', 'Process')
            $raw = @(Invoke-ImmichNativeProbe -FilePath $pwsh -ArgumentList @('-NoProfile','-NonInteractive','-File',$child,'ok',"space ' and ü") -ProbeName fixture)
            Check ($raw.Count -eq 1) 'Diagnostics polluted the stdout success stream.'
            $report = $raw[0] | ConvertFrom-Json
            Check ($report.argumentCodeUnits -ceq ([int[]][char[]]"space ' and ü" -join ',')) 'Native argument quoting changed.'
            Check ($report.value -ceq "space ' and ü") "UTF-8 output changed (received code units: $([int[]][char[]]$report.value -join ','))."
            $expectedDebug = (@($debug,'fatal-criticals') | Where-Object { $_ }) -join ','
            Check ($report.debug -ceq $expectedDebug) 'Child G_DEBUG did not preserve flags and enable fatal-criticals.'
            Check ([Environment]::GetEnvironmentVariable('G_DEBUG', 'Process') -ceq $expectedParent) 'Successful probe changed parent G_DEBUG.'
            foreach ($case in @(
                @{ Mode='critical-zero'; Expected='*GLib critical/error diagnostic*exit code 0*TLS callback not invoked*' },
                @{ Mode='critical-stdout'; Expected='*GLib critical/error diagnostic*exit code 0*' },
                @{ Mode='fatal'; Expected='*exit code 27*native fatal-criticals termination fixture*' },
                @{ Mode='silent-failure'; Expected='*exit code 28*' }
            )) {
                Expect-Failure { Invoke-ImmichNativeProbe -FilePath $pwsh -ArgumentList @('-NoProfile','-NonInteractive','-File',$child,$case.Mode) -ProbeName fixture 6>$null } $case.Expected
                Check ([Environment]::GetEnvironmentVariable('G_DEBUG', 'Process') -ceq $expectedParent) 'Failed probe changed parent G_DEBUG.'
            }
            Expect-Failure { Invoke-ImmichNativeProbe -FilePath (Join-Path $base 'missing-executable') -ProbeName missing } '*'
            Check ([Environment]::GetEnvironmentVariable('G_DEBUG', 'Process') -ceq $expectedParent) 'Launch failure changed parent G_DEBUG.'
        }
        $large = Invoke-ImmichNativeProbe -FilePath $pwsh -ArgumentList @('-NoProfile','-NonInteractive','-File',$child,'large') -ProbeName 'large streams'
        Check (($large | ConvertFrom-Json).value.Length -eq 262144) 'Large stdout was truncated.'
        Check ($capturedStderr.ToString().Contains('ordinary diagnostic')) 'Useful stderr was discarded.'
        Check ($capturedStderr.ToString().Contains(('e' * 262144))) 'Large stderr was truncated.'
    } finally { [Console]::SetError($oldStderr); $capturedStderr.Dispose() }

    # Exercise the actual build qualification script with a fixture-only Sharp
    # module. No codecs, image content, downloads, or server services are needed.
    $fixtureRepo = Join-Path $base 'repository'
    foreach ($directory in @('build','runtime','dependencies','.tools/node','application/server/node_modules/sharp','application/server/node_modules/.pnpm/@img+sharp-win32-x64@fixture/node_modules/@img/sharp-win32-x64/lib','fixtures')) {
        New-Item -ItemType Directory -Path (Join-Path $fixtureRepo $directory) -Force | Out-Null
    }
    foreach ($file in @('build/Common.psm1','build/Test-SharpCapabilities.ps1','runtime/Native-Probe.psm1')) { Copy-Item -LiteralPath (Join-Path $repo $file) -Destination (Join-Path $fixtureRepo $file) }
    $node = (Get-Command node -CommandType Application -ErrorAction Stop).Source
    Copy-Item -LiteralPath $node -Destination (Join-Path $fixtureRepo '.tools/node/node.exe')
    @{ node = @{ version = (& $node --version).Trim().TrimStart('v') } } | ConvertTo-Json | Set-Content (Join-Path $fixtureRepo 'dependencies/versions.json')
    '{}' | Set-Content (Join-Path $fixtureRepo 'application/server/package.json')
    @'
if (!process.env.G_DEBUG.includes('fatal-criticals')) throw new Error('Missing child fatal-criticals');
if (process.env.IMMICH_NATIVE_TEST_MODE === 'critical') {
  console.error('(process:123): GLib-CRITICAL **: TLS callback not invoked');
}
if (process.env.IMMICH_NATIVE_TEST_MODE === 'fatal') {
  console.error('native fatal fixture');
  process.exit(27);
}
function sharp() {
  return { metadata: async () => ({ format: 'fixture', width: 128, height: 128 }),
    clone() { return this; }, resize() { return this; }, jpeg() { return this; },
    toBuffer: async () => Buffer.alloc(0) };
}
sharp.versions = { sharp: 'fixture', vips: 'fixture' };
sharp.format = {};
module.exports = sharp;
'@ | Set-Content (Join-Path $fixtureRepo 'application/server/node_modules/sharp/index.js')
    $fixtures = @('one.jpg','two.jpg','one.png','one.webp','one.avif','one.heic','two.heic','three.heic','one.dng','one.jxl') | ForEach-Object {
        $path = Join-Path $fixtureRepo "fixtures/$_"
        Set-Content -LiteralPath $path 'fixture only'
        $path
    }
    $env:OS = 'Windows_NT' # Satisfy the platform guard for this isolated fixture.
    $app = Join-Path $fixtureRepo 'application'
    $qualify = Join-Path $fixtureRepo 'build/Test-SharpCapabilities.ps1'
    $env:G_DEBUG = 'gc-friendly'
    $oldPath = $env:PATH
    $env:IMMICH_NATIVE_TEST_MODE = 'ok'
    & $qualify -ApplicationRoot $app -Fixture $fixtures 3>$null 6>$null
    Check ((Get-Content -Raw (Join-Path $app 'sharp-libvips-qualification.json') | ConvertFrom-Json).productionQualified) 'Clean fixture matrix failed qualification.'
    foreach ($mode in @('critical','fatal')) {
        # Leave prior successful markers to verify that failed requalification
        # cannot retain either a smoke-pass or production-qualified marker.
        'stale' | Set-Content (Join-Path $app 'sharp-libvips-smoke.json')
        'stale' | Set-Content (Join-Path $app 'sharp-libvips-qualification.json')
        $env:IMMICH_NATIVE_TEST_MODE = $mode
        $expected = if ($mode -eq 'critical') { '*GLib critical/error diagnostic*exit code 0*TLS callback not invoked*' } else { '*exit code 27*native fatal fixture*' }
        Expect-Failure { & $qualify -ApplicationRoot $app -Fixture $fixtures 3>$null 6>$null } $expected
        Check (-not (Test-Path (Join-Path $app 'sharp-libvips-qualification.json'))) 'A failed native probe retained production qualification.'
        Check (-not (Test-Path (Join-Path $app 'sharp-libvips-smoke.json'))) 'A failed native probe retained the smoke marker.'
        Check ($env:PATH -ceq $oldPath -and $env:G_DEBUG -ceq 'gc-friendly') 'Build qualification did not preserve the caller environment.'
    }

    # The real schema-check wrapper imports an isolated admin stub. Its changes
    # to G_DEBUG and its stderr must never escape detection or alter the caller.
    $install = Join-Path $base 'install with spaces'
    $migration = Join-Path $install 'current/migration'
    $launchers = Join-Path $install 'current/runtime/launchers'
    New-Item -ItemType Directory -Path $migration,$launchers -Force | Out-Null
    Copy-Item (Join-Path $repo 'migration/Schema-Check.ps1') $migration
    @'
param($EnvFile, $Arguments)
$env:G_DEBUG = 'overridden by admin env loader'
if ($env:IMMICH_NATIVE_TEST_MODE -eq 'critical') {
    [Console]::Error.WriteLine('(process:123): GLib-CRITICAL **: TLS callback not invoked during schema import: ü')
} elseif ($env:IMMICH_NATIVE_TEST_MODE -eq 'drift') {
    Write-Output 'Detected schema drift'
} else { Write-Output 'schema-check fixture OK: ü' }
exit 0
'@ | Set-Content (Join-Path $launchers 'immich-admin.ps1')
    # Reproduce the Windows OEM writer on every OS. The production schema script
    # must select UTF-8 itself, and restore the caller's code page on success and
    # on schema drift. Arguments remain separate -File tokens, never shell code.
    $schemaHost = Join-Path $base 'schema OEM host.ps1'
    @'
param($Schema, $InstallRoot)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::GetEncoding(437)
try { & $Schema -EnvFile 'unused.env' -InstallRoot $InstallRoot }
finally {
    if ([Console]::OutputEncoding.CodePage -ne 437) { throw 'Schema-check failed to restore the caller output encoding.' }
}
'@ | Set-Content -LiteralPath $schemaHost
    $schemaArgs = @('-NoLogo','-NoProfile','-NonInteractive','-File',$schemaHost,'-Schema',(Join-Path $migration 'Schema-Check.ps1'),'-InstallRoot',$install)
    $env:IMMICH_NATIVE_TEST_MODE = 'ok'
    $schemaOutput = Invoke-ImmichNativeProbe -FilePath $pwsh -ArgumentList $schemaArgs -ProbeName 'Immich schema-check'
    Check ($schemaOutput -match 'schema-check fixture OK: ü') 'Clean schema-check failed or its UTF-8 output was corrupted.'
    $env:IMMICH_NATIVE_TEST_MODE = 'critical'
    Expect-Failure { Invoke-ImmichNativeProbe -FilePath $pwsh -ArgumentList $schemaArgs -ProbeName 'Immich schema-check' 6>$null } '*GLib critical/error diagnostic*exit code 0*TLS callback not invoked during schema import: ü*'
    $env:IMMICH_NATIVE_TEST_MODE = 'drift'
    Expect-Failure { Invoke-ImmichNativeProbe -FilePath $pwsh -ArgumentList $schemaArgs -ProbeName 'Immich schema-check' 6>$null } '*exit code 1*Immich schema-check failed*'
    Check ($env:G_DEBUG -ceq 'gc-friendly') 'Schema-check changed parent G_DEBUG.'

    # Keep both installed smoke call sites on the tested native gate.
    $tokens = $null; $parseErrors = $null
    $smoke = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'tests/Smoke-Windows.ps1'), [ref]$tokens, [ref]$parseErrors)
    Check ($parseErrors.Count -eq 0) 'Smoke-Windows.ps1 does not parse.'
    $probes = @($smoke.FindAll({ param($ast) $ast -is [Management.Automation.Language.CommandAst] -and $ast.GetCommandName() -eq 'Invoke-ImmichNativeProbe' }, $true))
    Check ($probes.Count -eq 2) 'Installed smoke must gate Sharp and schema-check.'
    Check (@($probes | Where-Object { $_.Extent.Text -match 'Sharp/libvips runtime capability test' -and $_.Extent.Text -match '\$node' }).Count -eq 1) 'Sharp smoke bypassed the native probe gate.'
    Check (@($probes | Where-Object { $_.Extent.Text -match 'Immich schema-check' -and $_.Extent.Text -match 'pwsh.exe' -and $_.Extent.Text -match 'Schema-Check.ps1' }).Count -eq 1) 'Schema-check must use an isolated PowerShell child.'
    $sharpCommand = ($probes | Where-Object { $_.Extent.Text -match 'Sharp/libvips runtime capability test' }).Extent.Text
    foreach ($fixturesForSmoke in @(@{ Values=$null; Count=3 }, @{ Values=@('one image.jpg','two.png'); Count=5 })) {
        $call = & {
            param($Command, $Fixtures, $Root)
            function Invoke-ImmichNativeProbe {
                param($FilePath, $ArgumentList, $ProbeName)
                [pscustomobject]@{ Arguments=$ArgumentList }
            }
            $node='fixture-node'; $probe='fixture-code'; $current=$Root; $SharpFixture=$Fixtures
            & ([scriptblock]::Create($Command))
        } $sharpCommand $fixturesForSmoke.Values $base
        Check ($call.Arguments.Count -eq $fixturesForSmoke.Count) 'Sharp smoke added an empty fixture argument or lost explicit fixtures.'
        Check ($call.Arguments[0] -eq '-e' -and $call.Arguments[1] -eq 'fixture-code') 'Sharp smoke changed its Node probe arguments.'
    }
    Write-Host 'Native probe regression tests passed: critical exit-zero rejection, fatal exit, JSON/stderr, environment isolation, pipe draining, Sharp qualification, and schema import.'
} finally {
    foreach ($name in $previous.Keys) {
        if ($null -eq $previous[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
    }
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}
