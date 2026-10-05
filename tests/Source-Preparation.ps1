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
$metadataPatchPath = Join-Path $root 'metadata-patches/date.patch'
$pwsh = (Get-Process -Id $PID).Path
$environment = @{}
foreach ($name in @('GIT_CONFIG_NOSYSTEM','GIT_CONFIG_GLOBAL','GIT_ATTR_NOSYSTEM')) {
    $environment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Write-File([string]$Path, [string]$Text) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path, $Text)
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
    $script:preparationOutput = $text
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
    Write-File (Join-Path $origin 'server/Dockerfile') ("FROM ghcr.io/immich-app/base-server-dev:202609281550@sha256:" + ('1' * 64) + " AS builder`nFROM ghcr.io/immich-app/base-server-prod:202609281550@sha256:" + ('2' * 64) + "`n")
    Write-File (Join-Path $origin 'value.txt') "original`n"
    Write-File (Join-Path $origin 'metadata.txt') "fallback`n"
    Write-File (Join-Path $origin 'order.txt') "original`n"
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
    $patch += "diff --git a/order.txt b/order.txt`n--- a/order.txt`n+++ b/order.txt`n@@ -1 +1 @@`n-original`n+windows`n"
    Write-File $patchPath $patch
    Write-File (Join-Path $root 'metadata-patches/series') "date.patch`n"
    $metadataPatch = "diff --git a/metadata.txt b/metadata.txt`n--- a/metadata.txt`n+++ b/metadata.txt`n@@ -1 +1 @@`n-fallback`n+localTimeA`n"
    $metadataPatch += "diff --git a/order.txt b/order.txt`n--- a/order.txt`n+++ b/order.txt`n@@ -1 +1 @@`n-windows`n+metadata`n"
    Write-File $metadataPatchPath $metadataPatch

    Prepare 'Prepared Immich'
    Check ((Get-Content -Raw (Join-Path $source 'value.txt')) -ceq "patchedA`n") 'Initial patch was not applied.'
    Check ((Get-Content -Raw (Join-Path $source 'metadata.txt')) -ceq "localTimeA`n") 'Metadata patch was not applied.'
    Check ((Get-Content -Raw (Join-Path $source 'order.txt')) -ceq "metadata`n") 'Metadata patches did not follow Windows patches.'
    $state = Get-Content -Raw $statePath | ConvertFrom-Json
    Check (($state.patches -join ',') -ceq 'patches/change.patch,metadata-patches/date.patch') 'Both ordered patch stacks must be recorded.'
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

    # Metadata patch bytes must invalidate the same preparation state, even when
    # the filename, length, timestamp and Windows patch series are unchanged.
    $metadataMtime = (Get-Item $metadataPatchPath).LastWriteTimeUtc
    $metadataLength = (Get-Item $metadataPatchPath).Length
    Write-File $metadataPatchPath ($metadataPatch.Replace('localTimeA', 'localTimeB'))
    (Get-Item $metadataPatchPath).LastWriteTimeUtc = $metadataMtime
    Check ((Get-Item $metadataPatchPath).Length -eq $metadataLength) 'Metadata mutation did not preserve length.'
    Prepare 'Prepared Immich'
    Check ((Get-Content -Raw (Join-Path $source 'metadata.txt')) -ceq "localTimeB`n") 'Metadata patch content change was reused.'
    Prepare 'Reusing prepared Immich'

    Write-Pin $otherCommit
    Prepare 'Source does not match pinned tag/commit' -Reject
    Check ((Get-Content -Raw (Join-Path $source 'value.txt')) -ceq "original`n") 'Recognized generated changes were not safely restored.'
    Write-Pin $commit
    Prepare 'Prepared Immich'
    Invoke-Git @('-C', $source, 'tag', '-d', 'v1.0.0') | Out-Null
    Prepare 'Prepared Immich'
    Check ((Invoke-Git @('-C', $source, 'describe', '--tags', '--exact-match', 'HEAD')) -eq 'v1.0.0') 'Missing pinned tag was silently reused.'

    # Preserve Windows state-file bytes even when this fixture runs on Unix.
    $validState = (Get-Content -Raw $statePath).Replace("`r`n", "`n").Replace("`n", "`r`n")
    Write-File $statePath $validState
    Check ((Get-Content -Raw $statePath) -ceq $validState) 'Fixture changed CRLF source-state bytes.'
    Prepare 'Reusing prepared Immich'
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
    # Stage every generated patch file so this exercises the staged-only guard.
    Invoke-Git @('-C', $source, 'add', 'value.txt', 'metadata.txt', 'order.txt') | Out-Null
    Prepare 'staged changes' -Reject
    Check (((Invoke-Git @('-C', $source, 'diff', '--cached', '--name-only')) -join ',') -ceq 'metadata.txt,order.txt,value.txt') 'Staged edits were discarded.'
    Invoke-Git @('-C', $source, 'restore', '--staged', '--', '.') | Out-Null

    # User edits in the metadata-patched file are protected by the same trust proof.
    Write-File (Join-Path $source 'metadata.txt') "user metadata edit`n"
    Prepare 'unrecognized changes' -Reject
    Check ((Get-Content -Raw (Join-Path $source 'metadata.txt')) -ceq "user metadata edit`n") 'A metadata-file edit was overwritten.'
    Write-File (Join-Path $source 'metadata.txt') "localTimeB`n"

    # Missing, unlisted and duplicate metadata entries fail before touching source.
    $metadataSeriesPath = Join-Path $root 'metadata-patches/series'
    Remove-Item -LiteralPath $metadataSeriesPath
    Prepare 'Patch series file is missing' -Reject
    Write-File $metadataSeriesPath "# empty list`n"
    Prepare 'Unlisted patch files exist' -Reject
    Write-File $metadataSeriesPath "date.patch`ndate.patch`n"
    Prepare 'Duplicate patch entries' -Reject
    Write-File $metadataSeriesPath "date.patch`n"
    Prepare 'Reusing prepared Immich'

    # A failed replacement patch must not leave partially prepared source or
    # advertise new state; the last state remains unusable until preparation succeeds.
    $badPatch = Join-Path $root 'metadata-patches/bad.patch'
    Write-File $badPatch ($patch.Replace('-original', '-does-not-exist'))
    Write-File $metadataSeriesPath "date.patch`nbad.patch`n"
    Prepare 'Command failed with exit code' -Reject
    Check (@(Invoke-Git @('-C', $source, 'status', '--porcelain')).Count -eq 0) "Failed patch left source dirty.`n$preparationOutput"
    $stateAfterFailure = Get-Content -Raw $statePath
    Check ($stateAfterFailure -ceq $validState) "Failed patch changed saved state.`nBefore: $validState`nAfter: $stateAfterFailure`n$preparationOutput"
    Remove-Item -LiteralPath $badPatch
    Write-File $metadataSeriesPath "date.patch`n"
    Prepare 'Prepared Immich'
    Prepare 'Reusing prepared Immich'

    # Production runtime pins deliberately differ from stale mise development pins.
    $depsPath = Join-Path $root 'dependencies/versions.json'
    $deps = Get-Content -Raw $depsPath | ConvertFrom-Json -AsHashtable
    $deps.node.version = '24.21.0'
    $deps.ffmpeg.version = '7.1.4-3'
    $deps.upstreamRuntime = @{
        schemaVersion = 1; immichCommit = $commit; nodeVersion = '24.21.0'; ffmpegVersion = '7.1.4-3'
        developmentTools = @{node='24.0.0';ffmpeg='7.0.0'}
        baseImages = @{commit=('b' * 40);tag='202609281550';images=@{
            dev=@{tag='202609281550';digest=('1' * 64)};prod=@{tag='202609281550';digest=('2' * 64)}
        }}
        sourceSha256 = @{}
    }
    foreach ($name in @('mise.toml','server/package.json','server/Dockerfile')) {
        $deps.upstreamRuntime.sourceSha256[$name] = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $source $name)).Hash.ToLowerInvariant()
    }
    Write-File $depsPath ($deps | ConvertTo-Json -Depth 10)
    Prepare 'Reusing prepared Immich'
    $deps.upstreamRuntime.nodeVersion = '24.15.0'
    Write-File $depsPath ($deps | ConvertTo-Json -Depth 10)
    Prepare 'Production runtime pins do not match' -Reject
    $deps.upstreamRuntime.nodeVersion = '24.21.0'
    $deps.upstreamRuntime.baseImages.images.prod.digest = '3' * 64
    Write-File $depsPath ($deps | ConvertTo-Json -Depth 10)
    Prepare 'base image pin differs' -Reject
    $deps.upstreamRuntime.baseImages.images.prod.digest = '2' * 64
    $deps.upstreamRuntime.sourceSha256['mise.toml'] = '0' * 64
    Write-File $depsPath ($deps | ConvertTo-Json -Depth 10)
    Prepare 'Upstream runtime source changed' -Reject
    $deps.upstreamRuntime.sourceSha256['mise.toml'] = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $source 'mise.toml')).Hash.ToLowerInvariant()
    Write-File $depsPath ($deps | ConvertTo-Json -Depth 10)
    Prepare 'Reusing prepared Immich'

    $source = Join-Path $base 'not-a-checkout'
    Write-File (Join-Path $source 'notes.txt') 'keep this directory'
    Prepare 'Could not inspect the source commit' -Reject
    Check ((Get-Content -Raw (Join-Path $source 'notes.txt')) -ceq 'keep this directory') 'A non-Git destination was changed.'
    Write-Host 'PASS source preparation: both ordered stacks, content identity, commit/tag pins, safe resets, local edits, patch failure recovery.'
} finally {
    foreach ($name in $environment.Keys) {
        if ($null -eq $environment[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($name, $environment[$name], 'Process') }
    }
    if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
}
