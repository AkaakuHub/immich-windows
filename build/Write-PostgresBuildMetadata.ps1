[CmdletBinding()]
param([string]$Destination)

Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
$root = Get-RepositoryRoot
if (-not $Destination) { $Destination = Join-Path $root 'artifacts\native' }
$versions = Read-JsonFile (Join-Path $root 'dependencies\versions.json')
$metadata = [ordered]@{
    postgresql = $versions.postgresql.version
    chocolateyVersion = $versions.postgresql.chocolateyVersion
    pgvector = $versions.pgvector.commit
    vectorchord = $versions.vectorchord.commit
    pgrx = $versions.vectorchord.pgrx
    rustToolchain = $versions.vectorchord.rustToolchain
}
$path = Join-Path $Destination 'postgres-extensions\build-inputs.json'
$metadata | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding utf8
