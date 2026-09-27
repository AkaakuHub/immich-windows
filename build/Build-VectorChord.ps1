[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PostgresRoot,
    [string]$Destination,
    [switch]$InstallCargoPgrx
)
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
Assert-WindowsX64
$root = Get-RepositoryRoot
$v = (Read-JsonFile (Join-Path $root 'dependencies\versions.json')).vectorchord
$pg = (Read-JsonFile (Join-Path $root 'dependencies\versions.json')).postgresql
if (-not $Destination) { $Destination = Join-Path $root 'artifacts\native\postgres-extensions\vchord' }
$pgConfig = Assert-FileExists (Join-Path $PostgresRoot 'bin\pg_config.exe')
$expectedPgMajor = [int](Read-JsonFile (Join-Path $root 'dependencies\versions.json')).postgresql.major
$pgVersionText = (& $pgConfig --version).Trim()
if ($pgVersionText -notmatch '^PostgreSQL\s+(\d+)(?:\.|$)') { throw "Could not parse PostgreSQL version from: $pgVersionText" }
if ([int]$Matches[1] -ne $expectedPgMajor) { throw "PostgreSQL major mismatch. Expected $expectedPgMajor, found $pgVersionText." }
Assert-Command git.exe | Out-Null
Assert-Command cargo.exe | Out-Null
Assert-Command rustup.exe | Out-Null
Assert-Command cl.exe | Out-Null
if (-not $env:LIBCLANG_PATH) { throw 'LIBCLANG_PATH must point to the LLVM bin directory containing libclang.dll.' }
Assert-FileExists (Join-Path $env:LIBCLANG_PATH 'libclang.dll') | Out-Null
$clang = Assert-FileExists (Join-Path $env:LIBCLANG_PATH 'clang.exe')

# VectorChord 1.1.1 supports PostgreSQL 18, but its x86_64 FP16 C shim explicitly
# requires Clang/GCC. Keep the PostgreSQL/MSVC ABI while forcing the cc crate to
# use LLVM clang, matching the verified native Windows PG18 build recipe.
$env:CC = $clang
$env:CC_x86_64_pc_windows_msvc = $clang
$clangxx = Join-Path $env:LIBCLANG_PATH 'clang++.exe'
if (Test-Path -LiteralPath $clangxx) {
    $env:CXX = $clangxx
    $env:CXX_x86_64_pc_windows_msvc = $clangxx
}

Invoke-Native rustup.exe @('toolchain','install',$v.rustToolchain,'--profile','minimal')
$hasPgrx = $false
try {
    $pgrxVersion = (& cargo.exe pgrx --version 2>$null) -join "`n"
    $hasPgrx = $LASTEXITCODE -eq 0 -and $pgrxVersion -match [regex]::Escape($v.pgrx)
} catch { $hasPgrx = $false }
if (-not $hasPgrx) {
    if (-not $InstallCargoPgrx) { throw "cargo-pgrx $($v.pgrx) is required. Re-run with -InstallCargoPgrx." }
    Invoke-Native cargo.exe @("+$($v.rustToolchain)",'install','--locked','cargo-pgrx','--version',$v.pgrx)
}

$source = Join-Path $root '.work\VectorChord'
if (-not (Test-Path -LiteralPath (Join-Path $source '.git'))) {
    if (Test-Path -LiteralPath $source) { throw "VectorChord source cache is not a Git checkout: $source" }
    Invoke-Native git @('clone','--depth','1','--branch',$v.version,$v.repository,$source)
}
$actualCommit = (& git.exe -C $source rev-parse HEAD).Trim()
if ($v.commit -and $actualCommit -ne $v.commit) { throw "VectorChord commit mismatch. Expected $($v.commit), got $actualCommit." }

$pgMajor = [string]$pg.major
$pgFeature = "pg$pgMajor"
$env:PGRX_PG_CONFIG_PATH = $pgConfig
$env:PG_CONFIG = $pgConfig
Invoke-Native cargo.exe @("+$($v.rustToolchain)",'pgrx','init',"--$pgFeature",$pgConfig) $source

# VectorChord >=1.1 ships an upstream xtask that is Windows-aware and emits a
# complete extension layout (DLL, control, install/upgrade SQL). Use it instead
# of cargo-pgrx package, matching the verified PG18 Windows build procedure.
Invoke-Native cargo.exe @("+$($v.rustToolchain)",'run','-p','xtask','--release','--','build') $source
$packageRoot = Join-Path $source 'build'
$dll = Assert-FileExists (Join-Path $packageRoot 'pkglibdir\vchord.dll')
$control = Assert-FileExists (Join-Path $packageRoot 'sharedir\extension\vchord.control')
$sql = @(Get-ChildItem -LiteralPath (Join-Path $packageRoot 'sharedir\extension') -Filter 'vchord--*.sql' -File)
if (-not $sql.Count) { throw 'VectorChord build did not contain extension SQL files.' }

$Destination = New-CleanDirectory $Destination
Copy-Item $dll $Destination -Force
Copy-Item $control $Destination -Force
New-Item -ItemType Directory -Path (Join-Path $Destination 'sql') -Force | Out-Null
$sql | ForEach-Object { Copy-Item $_.FullName (Join-Path $Destination 'sql') -Force }
Write-Host "VectorChord $($v.version) for PostgreSQL $pgMajor staged at $Destination"
