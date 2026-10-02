#requires -Version 7.0
# Exercise the unchanged preparation script against a tiny local Git upstream.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$base = Join-Path ([IO.Path]::GetTempPath()) ('source-preparation-' + [guid]::NewGuid().ToString('N'))
$root = Join-Path $base 'port'
$origin = Join-Path $base 'origin'
$source = Join-Path $base 'source'
$statePath = Join-Path $root '.work/source-state.json'
$patchPath = Join-Path $root 'patches/change.patch'
$pwsh = (Get-Process -Id $PID).Path
$environment = @{}
foreach ($name in @('GIT_CONFIG_NOSYSTEM','GIT_CONFIG_GLOBAL','GIT_ATTR_NOSYSTEM')) {
    $environment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Write-File([string]$Path, [string]$Text) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path, $Text.Replace("`r`n", "`n"))
}
function Invoke-Git([string[]]$Arguments) {
    $output = & git @Arguments 2>&1
    Check ($LASTEXITCODE -eq 0) "Fixture Git failed: $Arguments`n$($output -join "`n")"
    return $output
}
function Prepare([string]$Expected, [switch]$Reject) {
    $output = & $pwsh -NoLogo -NoProfile -File (Join-Path $base 'run.ps1') (Join-Path $root 'build/Prepare-Source.ps1') $source 2>&1
    $code = $LASTEXITCODE
    $text = $output -join "`n"
    Check (($code -ne 0) -eq [bool]$Reject) "Unexpected preparation exit ${code}:`n$text"
    Check ($text.Contains($Expected)) "Missing result '$Expected':`n$text"
}
function Write-Pin([string]$Commit) {
    Write-File (Join-Path $root 'upstream.json') (@{ repository = $origin; version = 'v1.0.0'; commit = $Commit } | ConvertTo-Json)
}

try {
    $env:GIT_CONFIG_NOSYSTEM = '1'
    $env:GIT_CONFIG_GLOBAL = Join-Path $base 'no-global-config'
    $env:GIT_ATTR_NOSYSTEM = '1'
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'build'))
    foreach ($file in @('Prepare-Source.ps1','Common.psm1')) {
        Copy-Item -LiteralPath (Join-Path $repo "build/$file") -Destination (Join-Path $root "build/$file")
    }
    # This fixture uses only portable Git/file operations. Isolate the Windows
    # entry-point check in a child process without changing production code.
    Write-File (Join-Path $base 'run.ps1') @'
param($Script, $Source)
$ErrorActionPreference = 'Stop'
$env:OS = 'Windows_NT'
& $Script -Destination $Source
'@
    Write-File (Join-Path $root 'dependencies/versions.json') @'
{"node":{"version":"24.0.0"},"pnpm":{"version":"10.0.0"},"extismJs":{"version":"1.0.0"},"binaryen":{"version":"123"},"ffmpeg":{"version":"7.0.0"},"sharp":{"version":"1.0.0"}}
'@
    Write-File (Join-Path $origin 'mise.toml') @'
node = "24.0.0"
pnpm = "10.0.0"
"github:extism/js-pdk" = "v1.0.0"
"github:webassembly/binaryen" = "version_123"
[tools."github:jellyfin/jellyfin-ffmpeg"]
version = "7.0.0"
'@
    Write-File (Join-Path $origin 'server/package.json') '{"version":"1.0.0","dependencies":{"sharp":"^1.0.0"}}'
    Write-File (Join-Path $origin 'value.txt') "original`n"
    Invoke-Git @('init', '--quiet', $origin) | Out-Null
    Invoke-Git @('-C', $origin, 'add', '.') | Out-Null
    Invoke-Git @('-C', $origin, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '-m', 'Pinned source') | Out-Null
    $commit = (Invoke-Git @('-C', $origin, 'rev-parse', 'HEAD')).Trim()
    Invoke-Git @('-C', $origin, 'tag', 'v1.0.0') | Out-Null
    Invoke-Git @('-C', $origin, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '--allow-empty', '-m', 'Different source') | Out-Null
    $otherCommit = (Invoke-Git @('-C', $origin, 'rev-parse', 'HEAD')).Trim()
    Write-Pin $commit
    Write-File (Join-Path $root 'patches/series') "change.patch`n"
    $patch = "diff --git a/value.txt b/value.txt`n--- a/value.txt`n+++ b/value.txt`n@@ -1 +1 @@`n-original`n+patchedA`n"
    Write-File $patchPath $patch

    Prepare 'Prepared Immich'
    Check ((Get-Content -Raw (Join-Path $source 'value.txt')) -ceq "patchedA`n") 'Initial patch was not applied.'
    $initialState = Get-Content -Raw $statePath
    Prepare 'Reusing prepared Immich'
    Check ((Get-Content -Raw $statePath) -ceq $initialState) 'Reuse rewrote source state.'

    (Get-Item $patchPath).LastWriteTimeUtc = [datetime]'2000-01-01Z'
    Prepare 'Reusing prepared Immich'
    Check ((Get-Content -Raw $statePath) -ceq $initialState) 'Identical patch bytes with another timestamp invalidated reuse.'
    $mtime = (Get-Item $patchPath).LastWriteTimeUtc
    $length = (Get-Item $patchPath).Length
    Write-File $patchPath ($patch.Replace('patchedA', 'patchedB'))
    (Get-Item $patchPath).LastWriteTimeUtc = $mtime
    Check ((Get-Item $patchPath).Length -eq $length) 'Patch mutation did not preserve length.'
    Prepare 'Prepared Immich'
    Check ((Get-Content -Raw (Join-Path $source 'value.txt')) -ceq "patchedB`n") 'Same-length, same-time patch change was reused.'

    Write-Pin $otherCommit
    Prepare 'Source does not match pinned tag/commit' -Reject
    Check ((Get-Content -Raw (Join-Path $source 'value.txt')) -ceq "original`n") 'Recognized generated changes were not safely restored.'
    Write-Pin $commit
    Prepare 'Prepared Immich'
    Invoke-Git @('-C', $source, 'tag', '-d', 'v1.0.0') | Out-Null
    Prepare 'Prepared Immich'
    Check ((Invoke-Git @('-C', $source, 'describe', '--tags', '--exact-match', 'HEAD')) -eq 'v1.0.0') 'Missing pinned tag was silently reused.'

    $validState = Get-Content -Raw $statePath
    $legacyState = $validState | ConvertFrom-Json
    $legacyState.PSObject.Properties.Remove('appliedDiff')
    Write-File $statePath ($legacyState | ConvertTo-Json -Depth 5)
    Prepare 'unrecognized changes' -Reject
    Check ((Get-Content -Raw (Join-Path $source 'value.txt')) -ceq "patchedB`n") 'Unproven legacy changes were overwritten.'
    Write-File $statePath $validState
    Write-File (Join-Path $source 'value.txt') "user edit`n"
    Prepare 'unrecognized changes' -Reject
    Check ((Get-Content -Raw (Join-Path $source 'value.txt')) -ceq "user edit`n") 'A user edit was overwritten.'
    Write-File (Join-Path $source 'value.txt') "patchedB`n"
    Write-File (Join-Path $source 'notes.txt') 'user notes'
    Prepare 'unrecognized changes' -Reject
    Check ((Get-Content -Raw (Join-Path $source 'notes.txt')) -ceq 'user notes') 'An untracked file was overwritten.'
    Remove-Item -LiteralPath (Join-Path $source 'notes.txt')
    Invoke-Git @('-C', $source, 'add', 'value.txt') | Out-Null
    Prepare 'staged changes' -Reject
    Check ((Invoke-Git @('-C', $source, 'diff', '--cached', '--name-only')) -eq 'value.txt') 'Staged edits were discarded.'
    Invoke-Git @('-C', $source, 'restore', '--staged', '--', '.') | Out-Null

    # A failed replacement patch must not leave partially prepared source or
    # advertise new state; the last state remains unusable until preparation succeeds.
    $badPatch = Join-Path $root 'patches/bad.patch'
    Write-File $badPatch ($patch.Replace('-original', '-does-not-exist'))
    Write-File (Join-Path $root 'patches/series') "change.patch`nbad.patch`n"
    Prepare 'Command failed with exit code' -Reject
    Check (@(Invoke-Git @('-C', $source, 'status', '--porcelain')).Count -eq 0) 'Failed patch left source dirty.'
    Check ((Get-Content -Raw $statePath) -ceq $validState) 'Failed patch recorded successful preparation.'
    Remove-Item -LiteralPath $badPatch
    Write-File (Join-Path $root 'patches/series') "change.patch`n"
    Prepare 'Prepared Immich'
    Prepare 'Reusing prepared Immich'

    $source = Join-Path $base 'not-a-checkout'
    Write-File (Join-Path $source 'notes.txt') 'keep this directory'
    Prepare 'Could not inspect the source commit' -Reject
    Check ((Get-Content -Raw (Join-Path $source 'notes.txt')) -ceq 'keep this directory') 'A non-Git destination was changed.'
    Write-Host 'PASS source preparation: content identity, commit/tag pins, safe resets, local edits, patch failure recovery.'
} finally {
    foreach ($name in $environment.Keys) { [Environment]::SetEnvironmentVariable($name, $environment[$name], 'Process') }
    if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
}
