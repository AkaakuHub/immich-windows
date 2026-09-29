param(
    [Parameter(Mandatory)]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$versions = Get-Content -Raw (Join-Path $root 'dependencies/versions.json') | ConvertFrom-Json
$media = $versions.sharpLibvips
$codecValue = @(
    $media.version,
    $media.commit,
    $media.libvipsRevision,
    $media.target,
    $media.variant,
    $media.jpeg,
    $media.hevc,
    $media.immichBaseImagesCommit,
    $media.immichLoaderPatch,
    $versions.sharp.version
) -join '-'
$postgresValue = @(
    $versions.postgresql.major,
    $versions.postgresql.version,
    $versions.postgresql.chocolateyVersion,
    $versions.pgvector.commit,
    $versions.vectorchord.commit,
    $versions.vectorchord.pgrx,
    $versions.vectorchord.rustToolchain
) -join '-'

Add-Content -LiteralPath $OutputPath -Value "codec=$codecValue"
Add-Content -LiteralPath $OutputPath -Value "postgres=$postgresValue"
