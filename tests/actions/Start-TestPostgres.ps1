#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PostgresRoot,
    [Parameter(Mandatory)][string]$DataRoot,
    [Parameter(Mandatory)][string]$PasswordFile
)
$ErrorActionPreference = 'Stop'
$versions = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\..\dependencies\versions.json') | ConvertFrom-Json
$archiveName = 'postgresql-{0}-windows-x64-binaries.zip' -f ($versions.postgresql.chocolateyVersion -replace '\.(\d+)$', '-$1')
$postgres = Join-Path $PostgresRoot 'bin\postgres.exe'
if (-not (Test-Path -LiteralPath $postgres -PathType Leaf)) {
    $archive = Join-Path $env:RUNNER_TEMP $archiveName
    New-Item -ItemType Directory -Path $PostgresRoot -Force | Out-Null
    try {
        Invoke-WebRequest -Uri "https://get.enterprisedb.com/postgresql/$archiveName" -OutFile $archive
        & "$env:SystemRoot\System32\tar.exe" -xf $archive --strip-components=1 -C $PostgresRoot --exclude='pgsql/doc/*' --exclude='pgsql/include/*' --exclude='pgsql/StackBuilder/*' --exclude='pgsql/symbols/*' --exclude='pgsql/pgAdmin 4/*'
        if ($LASTEXITCODE -ne 0) { throw 'Could not extract PostgreSQL binaries.' }
    } finally {
        Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
    }
}
$detectedVersion = & $postgres --version
if ($LASTEXITCODE -ne 0 -or $detectedVersion -notmatch [regex]::Escape("PostgreSQL) $($versions.postgresql.version)")) {
    throw "Unexpected PostgreSQL runtime: $detectedVersion"
}
$password = [guid]::NewGuid().ToString('N')
[IO.File]::WriteAllText($PasswordFile, $password)
& (Join-Path $PostgresRoot 'bin\initdb.exe') -D $DataRoot -U postgres -A scram-sha-256 --pwfile=$PasswordFile --encoding=UTF8 --no-instructions
if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the PostgreSQL test database.' }
& icacls.exe $DataRoot /grant '*S-1-5-18:(OI)(CI)F' | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Could not grant the PostgreSQL service access to its test database.' }
& (Join-Path $PostgresRoot 'bin\pg_ctl.exe') register -D $DataRoot -N postgresql-x64-18 -U LocalSystem -S demand
if ($LASTEXITCODE -ne 0) { throw 'Could not register the PostgreSQL test service.' }
Start-Service postgresql-x64-18
(Get-Service postgresql-x64-18).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
$env:PGPASSWORD = $password
try {
    $ready = & (Join-Path $PostgresRoot 'bin\psql.exe') -h 127.0.0.1 -U postgres -d postgres -Atqc 'SELECT 1'
    if ($LASTEXITCODE -ne 0 -or $ready -ne '1') { throw 'PostgreSQL test service did not accept a connection.' }
} finally {
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
}
Write-Host "PostgreSQL $($versions.postgresql.version) test service is running."
