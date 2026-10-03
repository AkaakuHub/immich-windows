#requires -Version 7.0
[CmdletBinding()]
param([string]$Destination)

Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
Assert-WindowsX64
$root = Get-RepositoryRoot
$upstream = Read-JsonFile (Join-Path $root 'upstream.json')
Assert-Command git | Out-Null

if (-not $Destination) { $Destination = Join-Path $root '.work\immich' }

if (-not (Test-Path $Destination)) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    Invoke-Native git @('clone', '--depth=1', '--branch', $upstream.version, $upstream.repository, $Destination)
}

$commit = (& git -C $Destination rev-parse HEAD)
if ($LASTEXITCODE -ne 0) { throw "Could not inspect the source commit: $Destination" }
$commit = $commit.Trim()
$actualTag = (& git -C $Destination describe --tags --exact-match HEAD 2>$null)
$tagMatches = $LASTEXITCODE -eq 0 -and $actualTag -eq $upstream.version

$seriesPath = Join-Path $root 'patches\series'
if (-not (Test-Path -LiteralPath $seriesPath -PathType Leaf)) { throw "Patch series file is missing: $seriesPath" }
$series = @(
    Get-Content -LiteralPath $seriesPath |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') }
)
$patches = @()
foreach ($relative in $series) {
    if ($relative -match '(^|[\/])\.\.([\/]|$)') { throw "Patch series entry escapes patches/: $relative" }
    $patch = Get-Item -LiteralPath (Join-Path (Join-Path $root 'patches') $relative) -ErrorAction Stop
    if ($patch.Extension -ne '.patch') { throw "Patch series entry is not a .patch file: $relative" }
    $patches += $patch
}
$allPatches = @(Get-ChildItem -LiteralPath (Join-Path $root 'patches') -Recurse -Filter '*.patch' -File)
$listed = @($patches | ForEach-Object { $_.FullName.ToLowerInvariant() })
$unlisted = @($allPatches | Where-Object { $_.FullName.ToLowerInvariant() -notin $listed })
if ($unlisted.Count) {
    throw "Unlisted patch files exist. Add them to patches/series or remove them:`n$($unlisted.FullName -join "`n")"
}

$patchNames = @($patches | ForEach-Object { $_.FullName.Substring($root.Length + 1).Replace('\','/') })
$patchFiles = @($patches | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash })
$expectedChangedFiles = [System.Collections.Generic.List[string]]::new()
foreach ($patch in $patches) {
    foreach ($line in Get-Content -LiteralPath $patch.FullName) {
        if ($line -match '^\+\+\+ b/(.+)$') { $expectedChangedFiles.Add($Matches[1]) }
    }
}
$expectedChangedFiles = @($expectedChangedFiles | Sort-Object -Unique)
$actualChangedFiles = @(& git -C $Destination diff --name-only | Sort-Object -Unique)
if ($LASTEXITCODE -ne 0) { throw "Could not inspect the pinned source worktree: $Destination" }
$untrackedFiles = @(& git -C $Destination ls-files --others --exclude-standard)
if ($LASTEXITCODE -ne 0) { throw "Could not inspect untracked source files: $Destination" }
$stagedFiles = @(& git -C $Destination diff --cached --name-only)
if ($LASTEXITCODE -ne 0) { throw "Could not inspect staged source files: $Destination" }
$actualDiff = (@(& git -C $Destination diff --binary) -join "`n")
if ($LASTEXITCODE -ne 0) { throw "Could not inspect source changes: $Destination" }
$statePath = Join-Path $root '.work\source-state.json'
$stateMatches = $false
$oldState = $null
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    $oldState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $samePatches = ($oldState.patches -join "`n") -ceq ($patchNames -join "`n")
    $samePatchFiles = ($oldState.patchFiles -join "`n") -ceq ($patchFiles -join "`n")
    $sameFiles = ($oldState.patchedFiles -join "`n") -ceq ($expectedChangedFiles -join "`n")
    $stateMatches = $oldState.version -eq $upstream.version -and
        $oldState.commit -eq $commit -and $commit -eq $upstream.commit -and $tagMatches -and
        $samePatches -and $samePatchFiles -and $sameFiles
}

function Assert-UpstreamVersions {
    $mise = Get-Content -Raw -LiteralPath (Join-Path $Destination 'mise.toml')
    $server = Read-JsonFile (Join-Path $Destination 'server\package.json')
    $versions = Read-JsonFile (Join-Path $root 'dependencies\versions.json')
    if ("v$($server.version)" -ne $upstream.version) { throw "Server package version differs from $($upstream.version)." }
    # mise pins development tools; the released server uses the separately pinned
    # production base image. Keep that distinction explicit when runtime metadata exists.
    $productionPins = $versions.PSObject.Properties['upstreamRuntime']
    if ($productionPins) {
        $runtime = $versions.upstreamRuntime
        if ($runtime.schemaVersion -ne 1 -or $runtime.immichCommit -ne $upstream.commit -or
            $runtime.baseImages.commit -notmatch '^[0-9a-f]{40}$' -or
            $runtime.nodeVersion -ne $versions.node.version -or $runtime.ffmpegVersion -ne $versions.ffmpeg.version) {
            throw 'Production runtime pins do not match the immutable upstream source.'
        }
        $dockerfile = Get-Content -Raw -LiteralPath (Join-Path $Destination 'server/Dockerfile')
        foreach ($kind in @('dev','prod')) {
            $image = $runtime.baseImages.images.$kind
            $reference = "ghcr.io/immich-app/base-server-${kind}:$($image.tag)@sha256:$($image.digest)"
            if ($image.tag -ne $runtime.baseImages.tag -or $image.digest -notmatch '^[0-9a-f]{64}$' -or
                -not $dockerfile.Contains($reference)) { throw 'Production base image pin differs from the upstream Dockerfile.' }
        }
        foreach ($property in $runtime.sourceSha256.PSObject.Properties) {
            if ($property.Name -notin @('mise.toml','server/package.json','server/Dockerfile','machine-learning/pyproject.toml','machine-learning/uv.lock')) {
                throw 'Unexpected upstream runtime source path.'
            }
            $text = (Get-Content -Raw -LiteralPath (Join-Path $Destination $property.Name)).Replace("`r`n","`n")
            $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text))).ToLowerInvariant()
            if ($hash -cne $property.Value) { throw "Upstream runtime source changed: $($property.Name)" }
        }
    }
    foreach ($name in @('node','pnpm')) {
        $match = [regex]::Match($mise, "(?m)^$name = `"([^`"]+)`"\r?$")
        $expected = if ($productionPins -and $name -eq 'node') { $runtime.developmentTools.node } else { $versions.$name.version }
        if (-not $match.Success -or $match.Groups[1].Value -ne $expected) {
            throw "Update dependencies/versions.json: $name differs from the pinned upstream mise.toml."
        }
    }
    foreach ($tool in @(
        @{ upstream = 'github:extism/js-pdk'; local = 'extismJs'; prefix = 'v' },
        @{ upstream = 'github:webassembly/binaryen'; local = 'binaryen'; prefix = 'version_' }
    )) {
        $pattern = '(?m)^"' + [regex]::Escape($tool.upstream) + '" = "([^\"]+)"\r?$'
        $match = [regex]::Match($mise, $pattern)
        if (-not $match.Success -or $match.Groups[1].Value -ne "$($tool.prefix)$($versions.($tool.local).version)") {
            throw "Update dependencies/versions.json: $($tool.local) differs from the pinned upstream mise.toml."
        }
    }
    $ffmpeg = [regex]::Match($mise, '(?m)^\[tools\."github:jellyfin/jellyfin-ffmpeg"\]\r?\nversion = "([^"]+)"\r?$')
    $expectedFfmpeg = if ($productionPins) { $runtime.developmentTools.ffmpeg } else { $versions.ffmpeg.version }
    if (-not $ffmpeg.Success -or $ffmpeg.Groups[1].Value -ne $expectedFfmpeg) {
        throw 'Update dependencies/versions.json: FFmpeg differs from the pinned upstream mise.toml.'
    }
    if ($server.dependencies.sharp.TrimStart('^','~') -ne $versions.sharp.version) {
        throw 'Update dependencies/versions.json: Sharp differs from the pinned upstream server package.'
    }
}

if ($stateMatches -and
    ($actualChangedFiles -join "`n") -ceq ($expectedChangedFiles -join "`n") -and
    $untrackedFiles.Count -eq 0 -and $stagedFiles.Count -eq 0 -and
    $oldState.appliedDiff -ceq $actualDiff) {
    Assert-UpstreamVersions
    Write-Host "Reusing prepared Immich $($upstream.version) at $commit"
    Write-Output $Destination
    return
}

if ($actualChangedFiles.Count -gt 0 -or $untrackedFiles.Count -gt 0) {
    $generated = $null -ne $oldState -and $oldState.commit -eq $commit -and
        ($actualChangedFiles -join "`n") -ceq ($oldState.patchedFiles -join "`n") -and
        $untrackedFiles.Count -eq 0 -and $stagedFiles.Count -eq 0 -and
        $null -ne $oldState.appliedDiff -and $oldState.appliedDiff -ceq $actualDiff
    if (-not $generated) { throw "Source checkout has unrecognized changes; refusing to overwrite it: $Destination" }
    Invoke-Native git @('-C', $Destination, 'restore', '--worktree', '--', '.')
}
if ($stagedFiles.Count -gt 0) { throw "Source checkout has staged changes; refusing to overwrite it: $Destination" }

if ($commit -ne $upstream.commit -or -not $tagMatches) {
    Invoke-Native git @('-C', $Destination, 'fetch', '--depth=1', 'origin', 'tag', $upstream.version)
    Invoke-Native git @('-C', $Destination, 'checkout', '--detach', $upstream.version)
    $commit = (& git -C $Destination rev-parse HEAD).Trim()
}
$actualTag = (& git -C $Destination describe --tags --exact-match HEAD 2>$null)
if ($LASTEXITCODE -ne 0 -or $actualTag -ne $upstream.version -or $commit -ne $upstream.commit) {
    throw "Source does not match pinned tag/commit $($upstream.version) $($upstream.commit). Found $actualTag $commit."
}
Assert-UpstreamVersions

try {
    foreach ($patch in $patches) {
        Write-Host "Checking patch $($patch.FullName)"
        Invoke-Native git @('-C', $Destination, 'apply', '--check', '--whitespace=error-all', $patch.FullName)
        Invoke-Native git @('-C', $Destination, 'apply', '--whitespace=error-all', $patch.FullName)
    }
} catch {
    Invoke-Native git @('-C', $Destination, 'restore', '--worktree', '--', '.')
    throw
}

$state = [ordered]@{
    version = $upstream.version
    commit = $commit
    preparedAtUtc = [DateTime]::UtcNow.ToString('o')
    patches = $patchNames
    patchFiles = $patchFiles
    patchedFiles = $expectedChangedFiles
    appliedDiff = (@(& git -C $Destination diff --binary) -join "`n")
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $statePath) | Out-Null
$state | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 -LiteralPath $statePath
Write-Host "Prepared Immich $($upstream.version) at $commit"
Write-Output $Destination
