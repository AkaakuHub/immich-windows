#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OldRoot,
    [Parameter(Mandatory)][string]$NewRoot,
    [string]$EnvFile='C:\ProgramData\Immich\immich.env',
    [string]$PostgresRoot='C:\Program Files\PostgreSQL\18',
    [string]$RollbackBackup,
    [int]$FilesystemSample=500,
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\runtime\Common.psm1') -Force

if([string]::IsNullOrWhiteSpace($OldRoot)){throw 'OldRoot must not be empty.'}
if(-not(Test-WindowsAbsolutePath $NewRoot)){throw 'NewRoot must be an absolute Windows drive or UNC path.'}
if(-not(Test-Path -LiteralPath $NewRoot -PathType Container)){throw "NewRoot does not exist as a directory: $NewRoot"}
if($FilesystemSample -lt 0){throw 'FilesystemSample must be zero or greater.'}

$OldRoot=$OldRoot.TrimEnd([char[]]@('/','\'))
$NewRoot=$NewRoot.TrimEnd([char[]]@('/','\'))
if(-not $OldRoot){throw 'OldRoot must not resolve to an empty path.'}
if(-not $NewRoot){throw 'NewRoot must not resolve to an empty path.'}

$envs=Read-EnvFile $EnvFile
$psql=Join-Path $PostgresRoot 'bin\psql.exe'
if(-not(Test-Path -LiteralPath $psql -PathType Leaf)){throw "psql.exe not found: $psql"}

function Invoke-ImmichSql {
    param([Parameter(Mandatory)][string]$Sql)
    $args=@(
        '-X','--no-psqlrc','--set','ON_ERROR_STOP=1',
        '--set',"old_root=$OldRoot",
        '--set',"new_root=$NewRoot",
        '-h',[string]$envs.DB_HOSTNAME,
        '-p',[string]$envs.DB_PORT,
        '-U',[string]$envs.DB_USERNAME,
        '-d',[string]$envs.DB_DATABASE_NAME,
        '-At'
    )
    $previousPassword=$env:PGPASSWORD
    try {
        $env:PGPASSWORD=[string]$envs.DB_PASSWORD
        $output=@($Sql | & $psql @args)
        if($LASTEXITCODE -ne 0){throw 'psql failed while migrating external library paths.'}
    } finally { $env:PGPASSWORD=$previousPassword }
    return $output
}

function Assert-ImmichApplicationStopped {
    if ([string]$envs.IMMICH_WINDOWS_INSTALL_SCOPE -eq 'CurrentUser') {
        $installRoot=Split-Path -Parent (Split-Path -Parent ([string]$envs.IMMICH_BUILD_DATA))
        $dataRoot=Split-Path -Parent (Resolve-Path -LiteralPath $EnvFile).Path
        foreach ($name in @('ImmichServer','ImmichMachineLearning')) {
            if (Get-ImmichUserProcess -InstallRoot $installRoot -DataRoot $dataRoot -Name $name) { throw "$name must be stopped before changing external library paths." }
        }
        return
    }
    if ([string]$envs.IMMICH_WINDOWS_INSTALL_SCOPE -ne 'AllUsers') { throw 'Unknown installation scope in the env file.' }
    foreach($name in @('ImmichServer','ImmichMachineLearning')){
        $service=Get-Service -Name $name -ErrorAction SilentlyContinue
        if($service -and $service.Status -ne 'Stopped'){
            throw "$name must be stopped before changing external library paths. Current state: $($service.Status)"
        }
    }
}

# Prefix matching deliberately avoids LIKE/regex so '%' and '_' in real paths
# cannot change matching semantics. A path matches only the exact root or a
# child separated by either POSIX '/' or Windows '\\'.
$countSql=@'
WITH p AS (
  SELECT rtrim(:'old_root', '/' || chr(92)) AS old_root
),
asset_count AS (
  SELECT count(*) AS n
  FROM asset a, p
  WHERE a."isExternal" = true
    AND left(a."originalPath", length(p.old_root)) = p.old_root
    AND (
      length(a."originalPath") = length(p.old_root)
      OR substring(a."originalPath" from length(p.old_root) + 1 for 1) IN ('/', chr(92))
    )
),
sidecar_count AS (
  SELECT count(*) AS n
  FROM asset_file af
  JOIN asset a ON a.id = af."assetId"
  CROSS JOIN p
  WHERE a."isExternal" = true
    AND af.type = 'sidecar'
    AND left(af.path, length(p.old_root)) = p.old_root
    AND (
      length(af.path) = length(p.old_root)
      OR substring(af.path from length(p.old_root) + 1 for 1) IN ('/', chr(92))
    )
),
import_count AS (
  SELECT count(*) AS n
  FROM library l
  CROSS JOIN LATERAL unnest(l."importPaths") item(path)
  CROSS JOIN p
  WHERE left(item.path, length(p.old_root)) = p.old_root
    AND (
      length(item.path) = length(p.old_root)
      OR substring(item.path from length(p.old_root) + 1 for 1) IN ('/', chr(92))
    )
)
SELECT (SELECT n FROM asset_count) || '|' ||
       (SELECT n FROM sidecar_count) || '|' ||
       (SELECT n FROM import_count);
'@

$counts=(Invoke-ImmichSql $countSql | Select-Object -First 1).Trim()
if($counts -notmatch '^(\d+)\|(\d+)\|(\d+)$'){throw "Unexpected migration count response: $counts"}
$assetCount=[int64]$Matches[1]
$sidecarCount=[int64]$Matches[2]
$importCount=[int64]$Matches[3]

Write-Host "External-library path migration preview"
Write-Host "  Old root: $OldRoot"
Write-Host "  New root: $NewRoot"
Write-Host "  External asset originals: $assetCount"
Write-Host "  External sidecars:        $sidecarCount"
Write-Host "  Library import paths:     $importCount"

$previewSql=@'
WITH p AS (SELECT rtrim(:'old_root', '/' || chr(92)) AS old_root)
SELECT l.id || '|' || l.name || '|' || item.path
FROM library l
CROSS JOIN LATERAL unnest(l."importPaths") item(path)
CROSS JOIN p
WHERE left(item.path, length(p.old_root)) = p.old_root
  AND (
    length(item.path) = length(p.old_root)
    OR substring(item.path from length(p.old_root) + 1 for 1) IN ('/', chr(92))
  )
ORDER BY l.name, item.path
LIMIT 25;
'@
$preview=@(Invoke-ImmichSql $previewSql)
if($preview.Count){
    Write-Host '  Matching library import paths:'
    $preview | ForEach-Object { Write-Host "    $_" }
}

if(($assetCount + $sidecarCount + $importCount) -eq 0){
    Write-Host 'No database paths matched OldRoot; no changes are required.'
    return
}

if(-not $Apply){
    Write-Host 'Dry run only. Re-run with -Apply after verifying the preview.'
    return
}

Assert-ImmichApplicationStopped
if(-not $RollbackBackup){throw 'RollbackBackup must point to the final logical database dump before applying external-library path changes.'}
$backupPath=(Resolve-Path -LiteralPath $RollbackBackup).Path
if(-not(Test-Path -LiteralPath $backupPath -PathType Leaf)){throw "Rollback backup does not exist: $backupPath"}

$applySql=@'
BEGIN;

WITH p AS (
  SELECT
    rtrim(:'old_root', '/' || chr(92)) AS old_root,
    rtrim(:'new_root', '/' || chr(92)) AS new_root
),
matched AS (
  SELECT
    a.id,
    a."originalPath" AS old_path,
    p.old_root,
    p.new_root,
    substring(a."originalPath" from length(p.old_root) + 1) AS remainder
  FROM asset a, p
  WHERE a."isExternal" = true
    AND left(a."originalPath", length(p.old_root)) = p.old_root
    AND (
      length(a."originalPath") = length(p.old_root)
      OR substring(a."originalPath" from length(p.old_root) + 1 for 1) IN ('/', chr(92))
    )
)
UPDATE asset a
SET "originalPath" = m.new_root ||
  CASE
    WHEN m.remainder = '' THEN ''
    ELSE chr(92) || replace(
      CASE WHEN left(m.remainder, 1) IN ('/', chr(92)) THEN substring(m.remainder from 2) ELSE m.remainder END,
      '/', chr(92)
    )
  END
FROM matched m
WHERE a.id = m.id;

WITH p AS (
  SELECT
    rtrim(:'old_root', '/' || chr(92)) AS old_root,
    rtrim(:'new_root', '/' || chr(92)) AS new_root
),
matched AS (
  SELECT
    af.id,
    af.path AS old_path,
    p.old_root,
    p.new_root,
    substring(af.path from length(p.old_root) + 1) AS remainder
  FROM asset_file af
  JOIN asset a ON a.id = af."assetId"
  CROSS JOIN p
  WHERE a."isExternal" = true
    AND af.type = 'sidecar'
    AND left(af.path, length(p.old_root)) = p.old_root
    AND (
      length(af.path) = length(p.old_root)
      OR substring(af.path from length(p.old_root) + 1 for 1) IN ('/', chr(92))
    )
)
UPDATE asset_file af
SET path = m.new_root ||
  CASE
    WHEN m.remainder = '' THEN ''
    ELSE chr(92) || replace(
      CASE WHEN left(m.remainder, 1) IN ('/', chr(92)) THEN substring(m.remainder from 2) ELSE m.remainder END,
      '/', chr(92)
    )
  END
FROM matched m
WHERE af.id = m.id;

WITH p AS (
  SELECT
    rtrim(:'old_root', '/' || chr(92)) AS old_root,
    rtrim(:'new_root', '/' || chr(92)) AS new_root
),
rewritten AS (
  SELECT
    l.id,
    array_agg(
      CASE
        WHEN left(item.path, length(p.old_root)) = p.old_root
          AND (
            length(item.path) = length(p.old_root)
            OR substring(item.path from length(p.old_root) + 1 for 1) IN ('/', chr(92))
          )
        THEN p.new_root ||
          CASE
            WHEN substring(item.path from length(p.old_root) + 1) = '' THEN ''
            ELSE chr(92) || replace(
              CASE
                WHEN left(substring(item.path from length(p.old_root) + 1), 1) IN ('/', chr(92))
                  THEN substring(substring(item.path from length(p.old_root) + 1) from 2)
                ELSE substring(item.path from length(p.old_root) + 1)
              END,
              '/', chr(92)
            )
          END
        ELSE item.path
      END
      ORDER BY item.ordinality
    ) AS import_paths
  FROM library l
  CROSS JOIN LATERAL unnest(l."importPaths") WITH ORDINALITY item(path, ordinality)
  CROSS JOIN p
  GROUP BY l.id, p.old_root, p.new_root
)
UPDATE library l
SET "importPaths" = r.import_paths
FROM rewritten r
WHERE l.id = r.id
  AND l."importPaths" IS DISTINCT FROM r.import_paths;

COMMIT;
'@
Invoke-ImmichSql $applySql | Out-Host

$remaining=(Invoke-ImmichSql $countSql | Select-Object -First 1).Trim()
if($remaining -ne '0|0|0'){
    throw "External-library migration committed but old-root paths remain: $remaining. Restore $backupPath before retrying."
}

if($FilesystemSample -gt 0){
    $sampleSql=@'
WITH p AS (SELECT rtrim(:'new_root', '/' || chr(92)) AS new_root), candidates AS (
  SELECT a."originalPath" AS path
  FROM asset a, p
  WHERE a."isExternal" = true
    AND left(a."originalPath", length(p.new_root)) = p.new_root
    AND (
      length(a."originalPath") = length(p.new_root)
      OR substring(a."originalPath" from length(p.new_root) + 1 for 1) IN ('/', chr(92))
    )
  UNION
  SELECT af.path
  FROM asset_file af
  JOIN asset a ON a.id = af."assetId"
  CROSS JOIN p
  WHERE a."isExternal" = true AND af.type = 'sidecar'
    AND left(af.path, length(p.new_root)) = p.new_root
    AND (
      length(af.path) = length(p.new_root)
      OR substring(af.path from length(p.new_root) + 1 for 1) IN ('/', chr(92))
    )
)
SELECT path FROM candidates ORDER BY path LIMIT :sample_limit;
'@
    # psql variables cannot be used as a LIMIT placeholder through this helper,
    # so replace a validated integer token locally.
    $sampleSql=$sampleSql.Replace(':sample_limit',[string]$FilesystemSample)
    $sample=@(Invoke-ImmichSql $sampleSql | Where-Object { $_ })
    $missing=@($sample | Where-Object { -not(Test-Path -LiteralPath $_) })
    if($missing.Count){
        $missing | Select-Object -First 10 | ForEach-Object { Write-Error "Missing migrated external file: $_" }
        throw "$($missing.Count) of $($sample.Count) sampled migrated external paths do not exist. Database backup: $backupPath"
    }
    Write-Host "Verified filesystem existence for $($sample.Count) migrated external paths."
}

Write-Host 'External-library database path migration completed successfully.'
Write-Host "Rollback backup: $backupPath"
