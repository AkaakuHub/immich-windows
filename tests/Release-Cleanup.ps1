#requires -Version 7.0
# Disposable filesystem fixtures; no live media, services, or databases are used.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Import-Module (Join-Path $repo 'runtime/Common.psm1') -Force
. (Join-Path $repo 'packaging/Remove-ObsoleteReleases.ps1')
$base=Join-Path ([IO.Path]::GetTempPath()) ('immich-release-cleanup-'+[guid]::NewGuid().ToString('N'))
$previousPgData=$env:PGDATA
$env:PGDATA=$null
function Check([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function New-Release([string]$Root,[string]$Version) {
    $path=Join-Path $Root "releases/$Version"
    New-Item -ItemType Directory (Join-Path $path 'server/dist') -Force | Out-Null
    $parts=$Version.TrimStart('v').Split('.')
    $manifest=[ordered]@{schemaVersion=1;immichVersion=('v'+($parts[0..2] -join '.'));target='windows-x64-native'}
    if ($parts.Count -eq 4) { $manifest.schemaVersion=2;$manifest.windowsRevision=[int]$parts[3];$manifest.packageVersion=$Version }
    $manifest | ConvertTo-Json | Set-Content (Join-Path $path 'manifest.json')
    Set-Content (Join-Path $path 'server/dist/main.js') app
    return $path
}
function New-Link([string]$Path,[string]$Target) {
    New-Item -ItemType $(if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }) -Path $Path -Target $Target | Out-Null
}
function New-Case([string]$Name) {
    $case=Join-Path $base $Name
    $root=Join-Path $case install
    $data=Join-Path $case data
    New-Item -ItemType Directory (Join-Path $data state) -Force | Out-Null
    $current=New-Release $root 'v3.2.2.9'
    $old=New-Release $root 'v3.2.2.8'
    New-Link (Join-Path $root current) $current
    @{status='qualified';candidateRelease=$current;previousRelease=$old;databaseBackup=(Join-Path $data 'backup.dump')} | ConvertTo-Json | Set-Content (Join-Path $data 'state/upgrade-recovery.json')
    Set-Content (Join-Path $data 'backup.dump') database
    Set-Content (Join-Path $data 'immich.env') "IMMICH_MEDIA_LOCATION=$(Join-Path $case media)`nMACHINE_LEARNING_CACHE_FOLDER=$(Join-Path $data models)"
    return [pscustomobject]@{Root=$root;Data=$data;Current=$current;Old=$old;Path=$case}
}
function Invoke-Cleanup($Case) {
    Remove-ImmichObsoleteReleases -InstallRoot $Case.Root -DataRoot $Case.Data -CurrentReleasePath $Case.Current -PreviousReleasePath $Case.Old
}
try {
    $case=New-Case exact-previous
    $legacy=New-Release $case.Root 'v3.2.2'
    $accumulated=New-Release $case.Root 'v3.1.0.7'
    $legacyZero=Join-Path $case.Root 'releases/v3.2.2.0'
    Copy-Item $legacy $legacyZero -Recurse
    foreach ($path in @((Join-Path $case.Path media),(Join-Path $case.Data models),(Join-Path $case.Root 'cache/pnpm-store'),(Join-Path $case.Root common))) {
        New-Item -ItemType Directory $path -Force | Out-Null
        Set-Content (Join-Path $path sentinel) preserved
    }
    # Real junctions on Windows (symlinks on Linux), including a loop and an
    # external media target. Their contents must never be traversed or deleted.
    New-Link (Join-Path $case.Old external-media) (Join-Path $case.Path media)
    New-Link (Join-Path $case.Old loop) $case.Old
    New-Link (Join-Path $case.Old active-code) $case.Current
    $result=Invoke-Cleanup $case
    Check ($result.Status -eq 'completed' -and $result.RemovedReleases.Count -eq 1 -and -not (Test-Path $case.Old)) 'The exact previous release was not removed.'
    foreach ($path in @($legacy,$legacyZero,$accumulated)) { Check (Test-Path -LiteralPath $path) "Unrelated historical release was deleted: $path" }
    foreach ($path in @((Join-Path $case.Path 'media/sentinel'),(Join-Path $case.Data 'models/sentinel'),(Join-Path $case.Data 'backup.dump'),(Join-Path $case.Data 'immich.env'),(Join-Path $case.Root 'cache/pnpm-store/sentinel'),(Join-Path $case.Root 'common/sentinel'),(Join-Path $case.Current 'server/dist/main.js'))) { Check (Test-Path -LiteralPath $path) "Preserved data disappeared: $path" }
    Check ((Get-CurrentReleaseTarget $case.Root) -eq $case.Current) 'Cleanup changed the active current junction.'
    Check ((Invoke-Cleanup $case).RemovedReleases.Count -eq 0) 'Repeated cleanup did additional work.'
    Write-Host 'PASS cleanup: only exact previous release removed; historical releases, current/shared data, and real directory link targets retained'

    foreach ($key in @('IMMICH_MEDIA_LOCATION','MACHINE_LEARNING_CACHE_FOLDER','POSTGRES_ROOT','PGDATA','IMMICH_CONFIG_FILE','HF_HUB_CACHE')) {
        $case=New-Case $key
        $protected=Join-Path $case.Old protected
        New-Item -ItemType Directory $protected | Out-Null
        Set-Content (Join-Path $protected sentinel) preserved
        Add-Content (Join-Path $case.Data 'immich.env') "$key=$protected"
        $result=Invoke-Cleanup $case
        Check ($result.Status -eq 'skipped' -and $result.RetainedReleases.Count -eq 1 -and (Test-Path (Join-Path $protected sentinel))) "$key inside an old release was not protected."
    }
    $case=New-Case linked-data
    $protected=Join-Path $case.Old photos
    New-Item -ItemType Directory $protected | Out-Null
    Set-Content (Join-Path $protected sentinel) preserved
    $alias=Join-Path $case.Path media-alias
    New-Link $alias $protected
    Add-Content (Join-Path $case.Data 'immich.env') "IMMICH_MEDIA_LOCATION=$alias"
    Check ((Invoke-Cleanup $case).RetainedReleases.Count -eq 1 -and (Test-Path (Join-Path $protected sentinel))) 'A data alias into an old release was not protected.'
    $case=New-Case nested-data-root
    $inside=Join-Path $case.Old user-data
    Move-Item $case.Data $inside
    $case.Data=$inside
    Check ((Invoke-Cleanup $case).RetainedReleases.Count -eq 1 -and (Test-Path (Join-Path $inside 'immich.env'))) 'DataRoot inside an old release was deleted.'
    $case=New-Case env-file-inside-previous
    $insideEnv=Join-Path $case.Old immich.env
    Copy-Item (Join-Path $case.Data immich.env) $insideEnv
    $result=Remove-ImmichObsoleteReleases -InstallRoot $case.Root -DataRoot $case.Data -CurrentReleasePath $case.Current -PreviousReleasePath $case.Old -EnvFile $insideEnv
    Check ($result.Status -eq 'skipped' -and (Test-Path $insideEnv)) 'Explicit EnvFile inside the previous release was not protected.'
    Write-Host 'PASS cleanup: custom media/model/database/env/cache paths and aliased or nested DataRoot fail closed' 

    $case=New-Case migrated-compose
    Add-Content (Join-Path $case.Data 'immich.env') "DB_DATA_LOCATION=/home/example/immich/postgres`nUPLOAD_LOCATION=/mnt/d/immich-data/upload`nIMMICH_VERSION=v3.2.2"
    $result=Invoke-Cleanup $case
    Check ($result.Status -eq 'completed' -and -not (Test-Path $case.Old)) 'Unused migrated Compose paths blocked native release cleanup.'
    $case=New-Case fallback-media
    Set-Content (Join-Path $case.Data 'immich.env') "UPLOAD_LOCATION=$(Join-Path $case.Old photos)"
    Check ((Invoke-Cleanup $case).RetainedReleases.Count -eq 1) 'UPLOAD_LOCATION fallback was not protected when native media setting was absent.'
    foreach ($key in @('removing','removed','retained','failed','skipped','summary')) {
        Check ((Get-ImmichCleanupText $key 'ja-JP') -cne (Get-ImmichCleanupText $key 'en-US')) "Missing Japanese cleanup label: $key"
    }
    Write-Host 'PASS cleanup: migrated Compose settings do not block removal; real fallback media and Japanese/English labels retained'

    foreach ($mode in @('not-qualified','wrong-current','relative-data','malformed-env','linked-releases-root')) {
        $case=New-Case $mode
        switch ($mode) {
            not-qualified { @{status='candidate-installed';candidateRelease=$case.Current} | ConvertTo-Json | Set-Content (Join-Path $case.Data 'state/upgrade-recovery.json') }
            wrong-current { $case.Current=$case.Old }
            relative-data { Add-Content (Join-Path $case.Data 'immich.env') 'MACHINE_LEARNING_CACHE_FOLDER=relative-models' }
            malformed-env { Add-Content (Join-Path $case.Data 'immich.env') 'invalid environment line' }
            linked-releases-root {
                $moved=Join-Path $case.Path outside-releases
                Move-Item (Join-Path $case.Root releases) $moved
                New-Link (Join-Path $case.Root releases) $moved
            }
        }
        $result=Invoke-Cleanup $case
        Check ($result.Status -eq 'skipped' -and (Test-Path $case.Old)) "Unsafe cleanup was not skipped: $mode"
    }
    Write-Host 'PASS cleanup: failed/incomplete qualification, inconsistent current, and ambiguous protection paths prevent deletion'

    foreach ($mode in @('foreign','mismatched','missing','malformed','linked','outside','state-mismatch','volume-root')) {
        $case=New-Case $mode
        switch ($mode) {
            foreign { (Get-Content -Raw (Join-Path $case.Old manifest.json)).Replace('windows-x64-native','another-app') | Set-Content (Join-Path $case.Old manifest.json) }
            mismatched { (Get-Content -Raw (Join-Path $case.Old manifest.json)).Replace('v3.2.2.8','v3.2.2.7') | Set-Content (Join-Path $case.Old manifest.json) }
            missing { Remove-Item (Join-Path $case.Old manifest.json) }
            malformed { Set-Content (Join-Path $case.Old manifest.json) '{malformed' }
            linked {
                $target=Join-Path $case.Path external
                Move-Item $case.Old $target
                New-Link $case.Old $target
            }
            outside { $case.Old=New-Release (Join-Path $case.Path foreign-install) 'v3.2.2.8' }
            state-mismatch {
                $state=Get-Content -Raw (Join-Path $case.Data 'state/upgrade-recovery.json') | ConvertFrom-Json
                $state.previousRelease=Join-Path $case.Root 'releases/v3.2.2.7'
                $state | ConvertTo-Json | Set-Content (Join-Path $case.Data 'state/upgrade-recovery.json')
            }
            volume-root { Add-Content (Join-Path $case.Data 'immich.env') "IMMICH_MEDIA_LOCATION=$([IO.Path]::GetPathRoot($case.Old))" }
        }
        $result=Invoke-Cleanup $case
        Check ($result.Status -eq 'skipped' -and (Test-Path $case.Old)) "Unsafe previous-release target was accepted: $mode"
    }
    foreach ($name in @('v3.2.2','v3.2.2.0')) {
        $case=New-Case ('legacy-'+$name)
        $legacy=New-Release $case.Root 'v3.2.2'
        if ($name -ne 'v3.2.2') { Move-Item $legacy (Join-Path $case.Root "releases/$name") }
        $case.Old=Join-Path $case.Root "releases/$name"
        $state=Get-Content -Raw (Join-Path $case.Data 'state/upgrade-recovery.json') | ConvertFrom-Json
        $state.previousRelease=$case.Old
        $state | ConvertTo-Json | Set-Content (Join-Path $case.Data 'state/upgrade-recovery.json')
        Check ((Invoke-Cleanup $case).RemovedReleases.Count -eq 1 -and -not (Test-Path $case.Old)) "Known schema1 previous release was not removed: $name"
    }
    # Only the no-follow deletion walker may enumerate contents, after a target
    # has been selected from the existing state. Historical discovery is absent.
    $source=Get-Content -Raw (Join-Path $repo 'packaging/Remove-ObsoleteReleases.ps1')
    Check ($source -notmatch 'EnumerateDirectories|Get-ChildItem|Get-FileHash') 'Cleanup introduced release discovery or payload hashing.'
    Write-Host 'PASS cleanup: no release discovery; invalid/outside/current targets and volume-root data retained; known legacy paths supported'

    $case=New-Case current-changed
    $originalCurrent=(Get-Command Get-CurrentReleaseTarget).ScriptBlock
    $script:currentChecks=0
    function Get-CurrentReleaseTarget {
        param($InstallRoot)
        $script:currentChecks++
        if ($script:currentChecks -eq 2) {
            [IO.Directory]::Delete((Join-Path $InstallRoot current))
            New-Link (Join-Path $InstallRoot current) $case.Old
        }
        return & $originalCurrent -InstallRoot $InstallRoot
    }
    try { $result=Invoke-Cleanup $case } finally { Set-Item function:Get-CurrentReleaseTarget $originalCurrent }
    Check ($result.Status -eq 'skipped' -and (Test-Path (Join-Path $case.Old 'server/dist/main.js'))) 'Changing the current junction during protection checks allowed active release deletion.'
    Write-Host 'PASS cleanup: a current-junction change immediately before deletion preserves the active release'

    if ($IsWindows) {
        $case=New-Case real-locked-file
        $lock=[IO.File]::Open((Join-Path $case.Old 'server/dist/main.js'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try { $result=Invoke-Cleanup $case } finally { $lock.Dispose() }
        Check ($result.Status -eq 'incomplete' -and (Test-Path (Join-Path $case.Old manifest.json))) 'A real Windows sharing lock lost the previous manifest or reported success.'
        Check ((Invoke-Cleanup $case).Status -eq 'completed') 'Real Windows sharing-lock cleanup did not succeed after release.'
        Write-Host 'PASS cleanup: real Windows file-sharing lock is nonfatal and retryable'
    }

    $case=New-Case deletion-failure
    $locked=Join-Path $case.Old 'runtime/tray/ImmichTray.exe'
    $dependency=Join-Path $case.Old 'machine-learning/python-runtime/Lib/site-packages/large-package/payload'
    New-Item -ItemType Directory (Split-Path $locked),(Split-Path $dependency) -Force | Out-Null
    Set-Content $locked running-tray
    Set-Content $dependency removable-dependency
    $originalEntry=(Get-Command Remove-ImmichReleaseEntry).ScriptBlock
    function Remove-ImmichReleaseEntry {
        param($Entry)
        if ($Entry.FullName -eq $locked) { throw 'Injected sharing violation for old tray' }
        & $originalEntry $Entry
    }
    try { $result=Invoke-Cleanup $case } finally { Set-Item function:Remove-ImmichReleaseEntry $originalEntry }
    Check ($result.Status -eq 'incomplete' -and $result.FailedReleases.Count -eq 1 -and (Test-Path (Join-Path $case.Old manifest.json))) 'Deletion failure was silently reported as success or lost the previous manifest.'
    Check ((Test-Path $locked) -and -not (Test-Path $dependency) -and -not (Test-Path (Join-Path $case.Old 'server/dist/main.js'))) 'One locked tray file prevented independent payload removal.'
    Check (((Get-Content -Raw (Join-Path $case.Data 'state/upgrade-recovery.json') | ConvertFrom-Json).status) -eq 'qualified') 'Cleanup failure changed qualified recovery state.'
    Check ((Invoke-Cleanup $case).Status -eq 'completed') 'A failed previous-release cleanup could not be retried.'
    Write-Host 'PASS cleanup: locked tray stays, independent dependency files removed, failure explicit/nonfatal and retryable'
} finally {
    $env:PGDATA=$previousPgData
    # Test disposal uses the same no-follow walker because retained fixtures may
    # intentionally contain loops or links to active/external fixture data.
    if (Test-Path -LiteralPath $base) { Remove-ImmichReleaseTree -Directory ([IO.DirectoryInfo]::new($base)) }
}
