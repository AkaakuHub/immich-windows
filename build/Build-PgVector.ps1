[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PostgresRoot,
    [string]$Destination
)
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
Assert-WindowsX64
$root = Get-RepositoryRoot
$v = (Read-JsonFile (Join-Path $root 'dependencies\versions.json')).pgvector
if (-not $Destination) { $Destination = Join-Path $root 'artifacts\native\postgres-extensions\vector' }
Assert-FileExists (Join-Path $PostgresRoot 'bin\pg_config.exe') | Out-Null
Assert-FileExists (Join-Path $PostgresRoot 'lib\postgres.lib') | Out-Null
$pgConfig = Join-Path $PostgresRoot 'bin\pg_config.exe'
$pgVersion = (& $pgConfig --version) -join "`n"
if ($LASTEXITCODE -ne 0) { throw "Could not query PostgreSQL version from $pgConfig" }
$requiredMajor = [int](Read-JsonFile (Join-Path $root 'dependencies\versions.json')).postgresql.major
if ($pgVersion -notmatch ("PostgreSQL\s+{0}\." -f $requiredMajor)) {
    throw "PostgreSQL $requiredMajor.x is required for pgvector; detected: $pgVersion"
}
Assert-Command cl.exe | Out-Null
Assert-Command nmake.exe | Out-Null
Assert-Command git.exe | Out-Null
$source = Join-Path $root '.work\pgvector'
if (-not (Test-Path -LiteralPath (Join-Path $source '.git'))) {
    if (Test-Path -LiteralPath $source) { throw "pgvector source cache is not a Git checkout: $source" }
    Invoke-Native git @('clone','--depth','1','--branch',"v$($v.version)",$v.repository,$source)
}
$actualCommit = (& git.exe -C $source rev-parse HEAD).Trim()
if ($v.commit -and $actualCommit -ne $v.commit) { throw "pgvector commit mismatch. Expected $($v.commit), got $actualCommit." }
$env:PGROOT = (Resolve-Path $PostgresRoot).Path
Invoke-Native nmake.exe @('/F','Makefile.win') $source
$Destination = New-CleanDirectory $Destination
Copy-Item (Join-Path $source 'vector.dll') $Destination -Force
Copy-Item (Join-Path $source 'vector.control') $Destination -Force
New-Item -ItemType Directory -Path (Join-Path $Destination 'sql') -Force | Out-Null
Copy-Item (Join-Path $source 'sql\vector--*.sql') (Join-Path $Destination 'sql') -Force
Assert-FileExists (Join-Path $Destination 'vector.dll') | Out-Null
Write-Host "pgvector $($v.version) staged at $Destination"
