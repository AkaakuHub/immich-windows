[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MediaRoot,
    [string]$EnvFile='C:\ProgramData\Immich\immich.env',
    [string]$PostgresRoot='C:\Program Files\PostgreSQL\18',
    [int]$FilesystemSample=2000
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\packaging\Common.psm1') -Force

if(-not(Test-WindowsAbsolutePath $MediaRoot)){throw 'MediaRoot must be an absolute Windows drive or UNC path.'}
if($FilesystemSample -lt 0){throw 'FilesystemSample must be zero or greater.'}
$MediaRoot=$MediaRoot.TrimEnd([char[]]@('/','\'))
if(-not $MediaRoot){throw 'MediaRoot must not resolve to an empty path.'}

$envs=Read-EnvFile $EnvFile
$psql=Join-Path $PostgresRoot 'bin\psql.exe'
if(-not(Test-Path -LiteralPath $psql -PathType Leaf)){throw "psql.exe not found: $psql"}
$env:PGPASSWORD=[string]$envs.DB_PASSWORD

function Invoke-ImmichSql {
    param([Parameter(Mandatory)][string]$Sql)
    $args=@(
        '-X','--no-psqlrc','--set','ON_ERROR_STOP=1',
        '--set',"media_root=$MediaRoot",
        '-h',[string]$envs.DB_HOSTNAME,
        '-p',[string]$envs.DB_PORT,
        '-U',[string]$envs.DB_USERNAME,
        '-d',[string]$envs.DB_DATABASE_NAME,
        '-At'
    )
    $output=@($Sql | & $psql @args)
    if($LASTEXITCODE -ne 0){throw 'psql failed while verifying migrated paths.'}
    return $output
}

# Only Immich-managed files are required to be under IMMICH_MEDIA_LOCATION.
# External asset originals and their external sidecars deliberately live outside
# that root and are validated separately below.
$managedCountsSql=@'
WITH p AS (SELECT rtrim(:'media_root', '/' || chr(92)) AS root), paths AS (
  SELECT 'asset.originalPath'::text AS kind, a."originalPath" AS path
  FROM asset a
  WHERE a."isExternal" = false

  UNION ALL

  SELECT 'asset_file.path'::text AS kind, af.path
  FROM asset_file af
  JOIN asset a ON a.id = af."assetId"
  WHERE NOT (a."isExternal" = true AND af.type = 'sidecar')

  UNION ALL

  SELECT 'person.thumbnailPath'::text AS kind, pe."thumbnailPath"
  FROM person pe
  WHERE pe."thumbnailPath" IS NOT NULL AND pe."thumbnailPath" <> ''

  UNION ALL

  SELECT 'user.profileImagePath'::text AS kind, u."profileImagePath"
  FROM "user" u
  WHERE u."profileImagePath" IS NOT NULL AND u."profileImagePath" <> ''
), checked AS (
  SELECT kind, path, p.root,
    lower(left(path, length(p.root))) = lower(p.root)
    AND (
      length(path) = length(p.root)
      OR substring(path from length(p.root) + 1 for 1) IN ('/', chr(92))
    ) AS under_root
  FROM paths CROSS JOIN p
  WHERE path IS NOT NULL AND path <> ''
)
SELECT count(*) || '|' || count(*) FILTER (WHERE NOT under_root)
FROM checked;
'@

# Windows absolute path test implemented in SQL so every external database path
# is checked, not only the filesystem sample.
$externalCountsSql=@'
WITH external_paths AS (
  SELECT 'asset.originalPath'::text AS kind, a."originalPath" AS path
  FROM asset a
  WHERE a."isExternal" = true

  UNION ALL

  SELECT 'asset_file.sidecar'::text AS kind, af.path
  FROM asset_file af
  JOIN asset a ON a.id = af."assetId"
  WHERE a."isExternal" = true AND af.type = 'sidecar'

  UNION ALL

  SELECT 'library.importPaths'::text AS kind, item.path
  FROM library l
  CROSS JOIN LATERAL unnest(l."importPaths") item(path)
), checked AS (
  SELECT kind, path,
    (
      length(path) >= 3
      AND substring(path from 1 for 1) ~ '^[A-Za-z]$'
      AND substring(path from 2 for 1) = ':'
      AND substring(path from 3 for 1) IN ('/', chr(92))
    )
    OR left(path, 2) = chr(92) || chr(92) AS windows_absolute
  FROM external_paths
  WHERE path IS NOT NULL AND path <> ''
)
SELECT count(*) || '|' || count(*) FILTER (WHERE NOT windows_absolute)
FROM checked;
'@

try {
    $managedCounts=(Invoke-ImmichSql $managedCountsSql | Select-Object -First 1).Trim()
    if($managedCounts -notmatch '^(\d+)\|(\d+)$'){throw "Unexpected managed-path count response: $managedCounts"}
    $managedTotal=[int64]$Matches[1]
    $managedWrong=[int64]$Matches[2]
    if($managedWrong -ne 0){
        $badManagedSql=@'
WITH p AS (SELECT rtrim(:'media_root', '/' || chr(92)) AS root), paths AS (
  SELECT 'asset.originalPath'::text AS kind, a."originalPath" AS path FROM asset a WHERE a."isExternal" = false
  UNION ALL
  SELECT 'asset_file.path', af.path FROM asset_file af JOIN asset a ON a.id = af."assetId" WHERE NOT (a."isExternal" = true AND af.type = 'sidecar')
  UNION ALL
  SELECT 'person.thumbnailPath', pe."thumbnailPath" FROM person pe WHERE pe."thumbnailPath" IS NOT NULL AND pe."thumbnailPath" <> ''
  UNION ALL
  SELECT 'user.profileImagePath', u."profileImagePath" FROM "user" u WHERE u."profileImagePath" IS NOT NULL AND u."profileImagePath" <> ''
)
SELECT kind || '|' || path
FROM paths CROSS JOIN p
WHERE path IS NOT NULL AND path <> ''
  AND NOT (
    lower(left(path, length(p.root))) = lower(p.root)
    AND (length(path) = length(p.root) OR substring(path from length(p.root) + 1 for 1) IN ('/', chr(92)))
  )
LIMIT 20;
'@
        Invoke-ImmichSql $badManagedSql | ForEach-Object { Write-Error "Managed path outside media root: $_" }
        throw "$managedWrong of $managedTotal Immich-managed database paths are outside Windows media root $MediaRoot"
    }

    $externalCounts=(Invoke-ImmichSql $externalCountsSql | Select-Object -First 1).Trim()
    if($externalCounts -notmatch '^(\d+)\|(\d+)$'){throw "Unexpected external-path count response: $externalCounts"}
    $externalTotal=[int64]$Matches[1]
    $externalInvalid=[int64]$Matches[2]
    if($externalInvalid -ne 0){
        $badExternalSql=@'
WITH external_paths AS (
  SELECT 'asset.originalPath'::text AS kind, a."originalPath" AS path FROM asset a WHERE a."isExternal" = true
  UNION ALL
  SELECT 'asset_file.sidecar', af.path FROM asset_file af JOIN asset a ON a.id = af."assetId" WHERE a."isExternal" = true AND af.type = 'sidecar'
  UNION ALL
  SELECT 'library.importPaths', item.path FROM library l CROSS JOIN LATERAL unnest(l."importPaths") item(path)
)
SELECT kind || '|' || path
FROM external_paths
WHERE path IS NOT NULL AND path <> ''
  AND NOT (
    (length(path) >= 3 AND substring(path from 1 for 1) ~ '^[A-Za-z]$' AND substring(path from 2 for 1) = ':' AND substring(path from 3 for 1) IN ('/', chr(92)))
    OR left(path, 2) = chr(92) || chr(92)
  )
LIMIT 20;
'@
        Invoke-ImmichSql $badExternalSql | ForEach-Object { Write-Error "External path is not native Windows absolute: $_" }
        throw "$externalInvalid of $externalTotal external-library database paths are not native Windows absolute paths. Use Change-ExternalLibraryPath.ps1 for each old mount root."
    }

    # Every configured external-library root should exist before the first scan.
    $importPaths=@(Invoke-ImmichSql 'SELECT item.path FROM library l CROSS JOIN LATERAL unnest(l."importPaths") item(path) ORDER BY item.path;' | Where-Object { $_ })

    $managedPaths=@()
    $externalPaths=@()
    if($FilesystemSample -gt 0){
        $managedSampleSql=@'
SELECT path FROM (
  SELECT a."originalPath" AS path FROM asset a WHERE a."isExternal" = false
  UNION
  SELECT af.path FROM asset_file af JOIN asset a ON a.id = af."assetId" WHERE NOT (a."isExternal" = true AND af.type = 'sidecar')
  UNION
  SELECT pe."thumbnailPath" FROM person pe WHERE pe."thumbnailPath" IS NOT NULL AND pe."thumbnailPath" <> ''
  UNION
  SELECT u."profileImagePath" FROM "user" u WHERE u."profileImagePath" IS NOT NULL AND u."profileImagePath" <> ''
) p WHERE path IS NOT NULL AND path <> '' ORDER BY path LIMIT __LIMIT__;
'@
        $managedSampleSql=$managedSampleSql.Replace('__LIMIT__',[string]$FilesystemSample)
        $managedPaths=@(Invoke-ImmichSql $managedSampleSql | Where-Object { $_ })

        $externalSampleSql=@'
SELECT path FROM (
  SELECT a."originalPath" AS path FROM asset a WHERE a."isExternal" = true AND a."isOffline" = false
  UNION
  SELECT af.path FROM asset_file af JOIN asset a ON a.id = af."assetId" WHERE a."isExternal" = true AND a."isOffline" = false AND af.type = 'sidecar'
) p WHERE path IS NOT NULL AND path <> '' ORDER BY path LIMIT __LIMIT__;
'@
        $externalSampleSql=$externalSampleSql.Replace('__LIMIT__',[string]$FilesystemSample)
        $externalPaths=@(Invoke-ImmichSql $externalSampleSql | Where-Object { $_ })
    }
} finally {
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
}

$missingRoots=@($importPaths | Where-Object { -not(Test-WindowsAbsolutePath $_) -or -not(Test-Path -LiteralPath $_ -PathType Container) })
if($missingRoots.Count){
    $missingRoots | Select-Object -First 20 | ForEach-Object { Write-Error "Missing or invalid external library root: $_" }
    throw "$($missingRoots.Count) configured external-library import paths are unavailable on Windows."
}

$missingManaged=@($managedPaths | Where-Object { -not(Test-Path -LiteralPath $_) })
if($missingManaged.Count){
    $missingManaged | Select-Object -First 10 | ForEach-Object { Write-Error "Missing managed file: $_" }
    throw "$($missingManaged.Count) of $($managedPaths.Count) sampled Immich-managed paths are missing on Windows."
}

$missingExternal=@($externalPaths | Where-Object { -not(Test-Path -LiteralPath $_) })
if($missingExternal.Count){
    $missingExternal | Select-Object -First 10 | ForEach-Object { Write-Error "Missing online external file: $_" }
    throw "$($missingExternal.Count) of $($externalPaths.Count) sampled online external-library paths are missing on Windows."
}

Write-Host "Verified $managedTotal Immich-managed database paths under $MediaRoot."
Write-Host "Verified $externalTotal external-library database paths are native Windows absolute paths."
Write-Host "Verified $($importPaths.Count) external-library import roots exist."
if($FilesystemSample -gt 0){
    Write-Host "Verified filesystem existence for $($managedPaths.Count) managed and $($externalPaths.Count) online external sampled paths."
}
