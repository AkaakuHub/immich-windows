#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackageRoot,
    [string]$PostgresRoot = 'C:\Program Files\PostgreSQL\18',
    [string]$PostgresService = 'postgresql-x64-18',
    [string]$AdminUser = 'postgres',
    [string]$DatabaseName = 'immich',
    [string]$DatabaseHost = '127.0.0.1',
    [ValidateRange(1,65535)][int]$DatabasePort = 5432,
    [Parameter(Mandatory)][string]$AdminPassword,
    [switch]$RecoveryRestore
)

$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\runtime\Common.psm1') -Force
Assert-Administrator

$ext = Join-Path $PackageRoot 'dependencies\postgres-extensions'
$pgBin = Join-Path $PostgresRoot 'bin'
$psql = Join-Path $pgBin 'psql.exe'
if (-not (Test-Path -LiteralPath $psql -PathType Leaf)) { throw "PostgreSQL 18 was not found at $PostgresRoot" }

function Get-PackagedExtensionVersion {
    param([Parameter(Mandatory)][string]$ExtensionName)
    $control = Join-Path $ext "$ExtensionName\$ExtensionName.control"
    if (-not (Test-Path -LiteralPath $control -PathType Leaf)) { throw "Missing packaged control file: $control" }
    $match = Select-String -LiteralPath $control -Pattern "default_version\s*=\s*'([^']+)'" | Select-Object -First 1
    if (-not $match) { throw "Could not determine default_version from $control" }
    return $match.Matches[0].Groups[1].Value
}

function Assert-NoExtensionDowngrade {
    param([string]$ExtensionName, [string]$InstalledVersion, [string]$PackagedVersion)
    if (-not $InstalledVersion -or $InstalledVersion -eq $PackagedVersion) { return }
    try {
        $installed = [version]$InstalledVersion
        $packaged = [version]$PackagedVersion
        if ($installed -gt $packaged) {
            throw "Refusing to replace $ExtensionName $InstalledVersion with older packaged version $PackagedVersion. Build an immich-windows release with a compatible extension instead."
        }
    } catch [System.Management.Automation.RuntimeException] {
        throw
    } catch {
        throw "Could not safely compare $ExtensionName versions '$InstalledVersion' and '$PackagedVersion'. Refusing to replace a loaded PostgreSQL extension."
    }
}

$packagedVersions = [ordered]@{
    vector = Get-PackagedExtensionVersion 'vector'
    vchord = Get-PackagedExtensionVersion 'vchord'
}
$installedVersions = [ordered]@{ vector = ''; vchord = '' }

# Query the live server before replacing any DLL. vchord is preloaded and its DLL
# is locked by postgres.exe on Windows, so all validation must happen before the
# service is stopped and the binary files are touched.
$env:PGPASSWORD = $AdminPassword
try {
    $databaseEscaped = $DatabaseName.Replace("'", "''")
    $databaseExistsOutput = & $psql -h $DatabaseHost -p $DatabasePort -U $AdminUser -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname = '$databaseEscaped'"
    if ($LASTEXITCODE -ne 0) { throw 'Could not check whether the Immich database exists.' }
    $databaseExists = ConvertTo-TrimmedOutput -Output $databaseExistsOutput

    if ($databaseExists -eq '1') {
        foreach ($extension in @('vector', 'vchord')) {
            $installedVersionOutput = & $psql -h $DatabaseHost -p $DatabasePort -U $AdminUser -d $DatabaseName -Atqc "SELECT extversion FROM pg_extension WHERE extname='$extension'"
            if ($LASTEXITCODE -ne 0) { throw "Could not query installed version of PostgreSQL extension $extension." }
            $installedVersions[$extension] = ConvertTo-TrimmedOutput -Output $installedVersionOutput
            if (-not $RecoveryRestore) {
                Assert-NoExtensionDowngrade -ExtensionName $extension -InstalledVersion $installedVersions[$extension] -PackagedVersion $packagedVersions[$extension]
            }
        }
    }

    $currentOutput = & $psql -h $DatabaseHost -p $DatabasePort -U $AdminUser -d postgres -Atqc 'SHOW shared_preload_libraries'
    if ($LASTEXITCODE -ne 0) { throw 'Could not read shared_preload_libraries.' }
    $current = ConvertTo-TrimmedOutput -Output $currentOutput
    $libs = @($current -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $installedFilesMatch = @('vector','vchord') | ForEach-Object {
        $extension = $_
        foreach ($pair in @(@("$extension.dll", "lib\$extension.dll"), @("$extension.control", "share\extension\$extension.control"))) {
            $source = Join-Path $ext "$extension\$($pair[0])"
            $target = Join-Path $PostgresRoot $pair[1]
            (Test-Path -LiteralPath $target -PathType Leaf) -and ((Get-FileHash $source -Algorithm SHA256).Hash -eq (Get-FileHash $target -Algorithm SHA256).Hash)
        }
    }
    if (-not $RecoveryRestore -and $databaseExists -eq '1' -and
        $installedVersions.vector -eq $packagedVersions.vector -and
        $installedVersions.vchord -eq $packagedVersions.vchord -and
        $libs -contains 'vchord' -and $installedFilesMatch -notcontains $false) {
        Write-Host 'PostgreSQL extensions already match the package; retaining the running service.'
        return
    }
    if ($libs -notcontains 'vchord') {
        $libs += 'vchord'
        $joined = $libs -join ','
        & $psql -h $DatabaseHost -p $DatabasePort -U $AdminUser -d postgres -v ON_ERROR_STOP=1 -c "ALTER SYSTEM SET shared_preload_libraries = '$joined';"
        if ($LASTEXITCODE -ne 0) { throw 'Failed to configure shared_preload_libraries.' }
    }
} finally {
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
}

$service = Get-Service -Name $PostgresService -ErrorAction Stop
$wasRunning = $service.Status -eq 'Running'
$backupRoot = Join-Path $env:TEMP ("immich-windows-pgext-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null

try {
    if ($wasRunning) {
        Stop-Service -Name $PostgresService -Force
        (Get-Service -Name $PostgresService).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
    }

    # Back up replaceable files so a copy error cannot leave PostgreSQL with a
    # half-updated native extension. Versioned SQL files are additive and are not
    # removed here.
    foreach ($extension in @('vector', 'vchord')) {
        foreach ($relative in @("lib\$extension.dll", "share\extension\$extension.control")) {
            $existing = Join-Path $PostgresRoot $relative
            if (Test-Path -LiteralPath $existing -PathType Leaf) {
                $backup = Join-Path $backupRoot $relative
                New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force | Out-Null
                Copy-Item -LiteralPath $existing -Destination $backup -Force
            }
        }
    }

    foreach ($name in @('vector', 'vchord')) {
        $src = Join-Path $ext $name
        if (-not (Test-Path -LiteralPath $src -PathType Container)) { throw "Missing packaged PostgreSQL extension: $name" }
        Get-ChildItem $src -Filter '*.dll' -File | Copy-Item -Destination (Join-Path $PostgresRoot 'lib') -Force
        Get-ChildItem $src -Filter '*.control' -File | Copy-Item -Destination (Join-Path $PostgresRoot 'share\extension') -Force
        if (Test-Path (Join-Path $src 'sql')) {
            Get-ChildItem (Join-Path $src 'sql') -Filter '*.sql' -File | Copy-Item -Destination (Join-Path $PostgresRoot 'share\extension') -Force
        }
    }
} catch {
    foreach ($file in Get-ChildItem -LiteralPath $backupRoot -File -Recurse -ErrorAction SilentlyContinue) {
        $relative = [IO.Path]::GetRelativePath($backupRoot, $file.FullName)
        $target = Join-Path $PostgresRoot $relative
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force -ErrorAction SilentlyContinue
    }
    throw
} finally {
    if ($wasRunning -and (Get-Service -Name $PostgresService).Status -ne 'Running') {
        Start-Service -Name $PostgresService
        (Get-Service -Name $PostgresService).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
    }
    Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if (-not $wasRunning) {
    Write-Host "PostgreSQL service $PostgresService was stopped before installation; extension files were updated but SQL reconciliation is deferred until the service is started."
    return
}

Start-Sleep -Seconds 2
if ($RecoveryRestore) {
    Write-Host 'PostgreSQL extension binaries were restored from the paired previous release. SQL extension reconciliation is intentionally deferred until the pre-upgrade database backup is restored.'
    return
}
$env:PGPASSWORD = $AdminPassword
try {
    if ($databaseExists -eq '1') {
        $vchordChanged = $false
        foreach ($extension in @('vector', 'vchord')) {
            $installedOutput = & $psql -h $DatabaseHost -p $DatabasePort -U $AdminUser -d $DatabaseName -Atqc "SELECT extversion FROM pg_extension WHERE extname='$extension'"
            if ($LASTEXITCODE -ne 0) { throw "Could not query installed version of PostgreSQL extension $extension after restart." }
            $installed = ConvertTo-TrimmedOutput -Output $installedOutput
            if (-not $installed) { continue }
            $availableOutput = & $psql -h $DatabaseHost -p $DatabasePort -U $AdminUser -d $DatabaseName -Atqc "SELECT default_version FROM pg_available_extensions WHERE name='$extension'"
            $available = ConvertTo-TrimmedOutput -Output $availableOutput
            if ($LASTEXITCODE -ne 0 -or -not $available) { throw "Packaged PostgreSQL extension $extension is not available after installation." }
            Assert-NoExtensionDowngrade -ExtensionName $extension -InstalledVersion $installed -PackagedVersion $available
            if ($installed -ne $available) {
                Write-Host "Updating PostgreSQL extension ${extension}: $installed -> $available"
                & $psql -h $DatabaseHost -p $DatabasePort -U $AdminUser -d $DatabaseName -v ON_ERROR_STOP=1 -c "ALTER EXTENSION $extension UPDATE;"
                if ($LASTEXITCODE -ne 0) { throw "ALTER EXTENSION $extension UPDATE failed." }
                if ($extension -eq 'vchord') { $vchordChanged = $true }
            }
        }
        if ($vchordChanged) {
            $reindex = @'
DO $$
BEGIN
  IF to_regclass('face_index') IS NOT NULL THEN EXECUTE 'REINDEX INDEX face_index'; END IF;
  IF to_regclass('clip_index') IS NOT NULL THEN EXECUTE 'REINDEX INDEX clip_index'; END IF;
END
$$;
'@
            & $psql -h $DatabaseHost -p $DatabasePort -U $AdminUser -d $DatabaseName -v ON_ERROR_STOP=1 -c $reindex
            if ($LASTEXITCODE -ne 0) { throw 'VectorChord index rebuild failed after extension update.' }
        }
    }
} finally {
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
}

Write-Host 'PostgreSQL extension binaries installed while postgres.exe was stopped, vchord preload configured, and installed extensions reconciled.'
