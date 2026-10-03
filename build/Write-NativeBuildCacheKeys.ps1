#requires -Version 7.0
param(
    [Parameter(Mandatory)]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$versions = Get-Content -Raw (Join-Path $root 'dependencies/versions.json') | ConvertFrom-Json
Import-Module (Join-Path $PSScriptRoot 'NativeMediaValidation.psm1') -Force
# The cache selector and bundle verification share exactly one input identity.
$codecValue = (Get-NativeMediaBuildIdentity -RepositoryRoot $root).nativeBuildInputsSha256
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
