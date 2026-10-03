#requires -Version 7.0
# Loaded by Update.ps1 only after startup and smoke verification have qualified.
# Common.psm1 is already loaded by the caller; do not reload its module here.

function Get-ImmichCleanupText {
    param([string]$Key,[string]$Culture=[Globalization.CultureInfo]::CurrentUICulture.Name)
    $ja=$Culture.Replace('_','-').Split('-')[0] -eq 'ja'
    $messages=@{
        removing=@('Removing old application release','旧アプリを削除中')
        removed=@('Removed old application release','旧アプリの削除完了')
        retained=@('Old release retained for safety','安全のため旧アプリを保持')
        failed=@('Old release cleanup failed','旧アプリの削除に失敗')
        skipped=@('Old release cleanup skipped; running server unchanged','旧アプリの削除を中止しました。稼働中のサーバーには影響しません')
        summary=@('Old release cleanup {0}: {1} removed, {2} retained, {3} failed.','旧アプリの整理 {0}: 削除 {1} 件、保持 {2} 件、失敗 {3} 件')
        completed=@('completed','完了');incomplete=@('incomplete','未完了');skippedStatus=@('skipped','中止')
    }
    return $messages[$Key][[int]$ja]
}

function Get-ImmichCleanupPath {
    param([Parameter(Mandatory)][string]$Path,[switch]$ResolveLinks,[int]$LinkDepth=0)
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw "Cannot safely resolve relative cleanup protection path: $Path" }
    $full=[IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Path))
    if (-not $ResolveLinks) { return $full }
    if ($LinkDepth -gt 32) { throw "Too many directory links in cleanup protection path: $Path" }
    $root=[IO.Path]::GetPathRoot($full)
    $parts=$full.Substring($root.Length).Split([char[]]@([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar),[StringSplitOptions]::RemoveEmptyEntries)
    $resolved=$root
    for ($index=0; $index -lt $parts.Count; $index++) {
        $resolved=Join-Path $resolved $parts[$index]
        try { $item=Get-Item -LiteralPath $resolved -Force -ErrorAction Stop }
        catch [Management.Automation.ItemNotFoundException] {
            # A configured directory need not exist yet. Preserve its intended path.
            for ($remaining=$index+1; $remaining -lt $parts.Count; $remaining++) { $resolved=Join-Path $resolved $parts[$remaining] }
            return [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($resolved))
        }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $targets=@($item.Target)
            if ($targets.Count -ne 1 -or -not $targets[0]) { throw "Unresolved directory link in cleanup protection path: $resolved" }
            $target=[string]$targets[0]
            if (-not [IO.Path]::IsPathFullyQualified($target)) { $target=Join-Path (Split-Path -Parent $resolved) $target }
            for ($remaining=$index+1; $remaining -lt $parts.Count; $remaining++) { $target=Join-Path $target $parts[$remaining] }
            return Get-ImmichCleanupPath -Path $target -ResolveLinks -LinkDepth ($LinkDepth+1)
        }
    }
    return [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($resolved))
}

function Test-ImmichCleanupPathWithin {
    param([string]$Path,[string]$Root)
    return $Path.Equals($Root,[StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith(($Root.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar),[StringComparison]::OrdinalIgnoreCase)
}

function Assert-ImmichCleanupRelease {
    param([Parameter(Mandatory)][IO.DirectoryInfo]$Directory)
    $Directory.Refresh()
    if (-not $Directory.Exists -or ($Directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Release is missing or is a directory link.' }
    $manifestPath=Join-Path $Directory.FullName 'manifest.json'
    $manifestFile=Get-Item -LiteralPath $manifestPath -Force -ErrorAction Stop
    if ($manifestFile.PSIsContainer -or ($manifestFile.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Release manifest is not a regular file.' }
    $manifest=Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    if ($manifest.schemaVersion -notin @(1,2) -or $manifest.target -cne 'windows-x64-native') { throw 'Manifest does not identify a managed Windows release.' }
    $version=Get-WindowsPackageVersion $manifest
    $expected=@("v$version")
    if ($manifest.schemaVersion -eq 1 -and -not $manifest.PSObject.Properties['windowsRevision']) { $expected+=,[string]$manifest.immichVersion }
    if ($Directory.Name -cnotin $expected) { throw 'Release directory name does not match its manifest identity.' }
}

function Remove-ImmichReleaseEntry {
    param([Parameter(Mandatory)][IO.FileSystemInfo]$Entry)
    # Never change attributes through a link: that could mutate its target.
    if (-not ($Entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -and ($Entry.Attributes -band [IO.FileAttributes]::ReadOnly)) {
        $Entry.Attributes=$Entry.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly)
    }
    $Entry.Delete()
}

function Remove-ImmichReleaseTree {
    param([Parameter(Mandatory)][IO.DirectoryInfo]$Directory,[switch]$ReleaseRoot,[hashtable]$Failures)
    $ownsFailures=$null -eq $Failures
    if ($ownsFailures) { $Failures=@{Count=0;Messages=[Collections.Generic.List[string]]::new()} }
    $before=$Failures.Count
    try {
        $Directory.Refresh()
        if ($Directory.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            # Delete only the link, never enumerate a junction/symlink target.
            Remove-ImmichReleaseEntry $Directory
        } else {
            foreach ($entry in $Directory.EnumerateFileSystemInfos()) {
                if ($ReleaseRoot -and $entry.Name -ieq 'manifest.json') { continue }
                try {
                    if ($entry -is [IO.DirectoryInfo] -and -not ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                        Remove-ImmichReleaseTree -Directory $entry -Failures $Failures
                    } else { Remove-ImmichReleaseEntry $entry }
                } catch {
                    $Failures.Count++
                    if ($Failures.Messages.Count -lt 8) { $Failures.Messages.Add("$($entry.FullName): $($_.Exception.Message)") }
                }
            }
            # Locked old tray files must not prevent independent dependency trees
            # being removed. Retain identity whenever any descendant remains.
            if ($Failures.Count -eq $before) {
                if ($ReleaseRoot) { Remove-ImmichReleaseEntry ([IO.FileInfo]::new((Join-Path $Directory.FullName 'manifest.json'))) }
                $Directory.Delete()
            }
        }
    } catch {
        $Failures.Count++
        if ($Failures.Messages.Count -lt 8) { $Failures.Messages.Add("$($Directory.FullName): $($_.Exception.Message)") }
    }
    if ($ownsFailures -and $Failures.Count) { throw "Previous release cleanup incomplete ($($Failures.Count) failures): $($Failures.Messages -join '; ')" }
}

function Remove-ImmichObsoleteReleases {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)][string]$CurrentReleasePath,
        [Parameter(Mandatory)][string]$PreviousReleasePath,
        [string]$EnvFile=(Join-Path $DataRoot 'immich.env')
    )
    $ErrorActionPreference='Stop'
    $result=[ordered]@{Status='skipped';RemovedReleases=@();RetainedReleases=@();FailedReleases=@()}
    try {
        $releaseRoot=Get-ImmichCleanupPath (Join-Path $InstallRoot 'releases') -ResolveLinks
        $releaseRootItem=Get-Item -LiteralPath (Join-Path $InstallRoot 'releases') -Force
        if (-not $releaseRootItem.PSIsContainer -or ($releaseRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'The releases directory is missing or is a directory link.' }
        $current=Get-ImmichCleanupPath (Get-CurrentReleaseTarget -InstallRoot $InstallRoot) -ResolveLinks
        $expectedCurrent=Get-ImmichCleanupPath $CurrentReleasePath -ResolveLinks
        $previous=Get-ImmichCleanupPath $PreviousReleasePath
        if ($current -ine $expectedCurrent -or [IO.Path]::GetDirectoryName($current) -ine $releaseRoot) { throw 'The active release does not match this qualified update.' }
        if ((Get-ImmichCleanupPath ([IO.Path]::GetDirectoryName($previous)) -ResolveLinks) -ine $releaseRoot) { throw 'The previous release is not an immediate child of this installation releases directory.' }
        # Canonicalize its parent only. A previous-release link is never followed.
        $previous=Join-Path $releaseRoot ([IO.Path]::GetFileName($previous))
        if ($previous -ieq $current) { throw 'The previous release is still active.' }
        Assert-ImmichCleanupRelease -Directory ([IO.DirectoryInfo]::new($current))
        $state=Get-Content -Raw -LiteralPath (Join-Path $DataRoot 'state/upgrade-recovery.json') | ConvertFrom-Json -AsHashtable
        if ($state['status'] -ne 'qualified' -or -not $state['candidateRelease'] -or
            (Get-ImmichCleanupPath ([string]$state['candidateRelease']) -ResolveLinks) -ine $current -or
            -not $state['previousRelease'] -or (Get-ImmichCleanupPath ([string]$state['previousRelease'])) -ine (Get-ImmichCleanupPath $PreviousReleasePath)) {
            throw 'The recorded qualified update does not authorize this previous release cleanup.'
        }
        try { $directory=Get-Item -LiteralPath $previous -Force -ErrorAction Stop }
        catch [Management.Automation.ItemNotFoundException] { $result.Status='completed'; return [pscustomobject]$result }
        Assert-ImmichCleanupRelease -Directory $directory

        # Check only known configured paths, both literally and through aliases.
        # Never enumerate releases to discover other versions; users manage those.
        $protected=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $paths=[Collections.Generic.List[string]]::new()
        foreach ($path in @($DataRoot,$EnvFile,(Join-Path $InstallRoot 'cache'),(Join-Path $InstallRoot 'common'))) { $paths.Add($path) }
        if ($state['databaseBackup']) { $paths.Add([string]$state['databaseBackup']) }
        $values=Read-EnvFile $EnvFile
        # Migrated Compose-only DB_DATA_LOCATION and unused UPLOAD_LOCATION are
        # not native consumers; their stale /home and /mnt values must not block.
        $media=if ($values['IMMICH_MEDIA_LOCATION']) { $values['IMMICH_MEDIA_LOCATION'] } else { $values['UPLOAD_LOCATION'] }
        if ($media) { $paths.Add([string]$media) }
        foreach ($key in @('MACHINE_LEARNING_CACHE_FOLDER','IMMICH_CONFIG_FILE','IMMICH_BUILD_DATA',
            'POSTGRES_ROOT','IMMICH_POSTGRES_BIN_DIR','PGDATA','HF_HOME','HF_HUB_CACHE','HUGGINGFACE_HUB_CACHE',
            'TORCH_HOME','XDG_CACHE_HOME','TRANSFORMERS_CACHE')) {
            if ($values[$key]) { $paths.Add([string]$values[$key]) }
        }
        if ($env:PGDATA) { $paths.Add($env:PGDATA) }
        foreach ($path in $paths) {
            [void]$protected.Add((Get-ImmichCleanupPath $path))
            [void]$protected.Add((Get-ImmichCleanupPath $path -ResolveLinks))
        }
        foreach ($path in $protected) {
            if ((Test-ImmichCleanupPathWithin $path $previous) -or (Test-ImmichCleanupPathWithin $previous $path)) {
                throw 'Configured data, media, models, database, environment, or shared cache overlaps the previous release.'
            }
        }
        # The caller holds the update mutex. Check the live link immediately
        # before deletion, without discovering or inspecting historical releases.
        if ((Get-ImmichCleanupPath (Get-CurrentReleaseTarget -InstallRoot $InstallRoot) -ResolveLinks) -ine $current) { throw 'Active release changed during cleanup.' }
        try {
            Write-Host "$(Get-ImmichCleanupText removing): $previous"
            Remove-ImmichReleaseTree -Directory $directory -ReleaseRoot
            $result.Status='completed'
            $result.RemovedReleases+=,$previous
            Write-Host "$(Get-ImmichCleanupText removed): $previous"
        } catch {
            $result.Status='incomplete'
            $result.FailedReleases+=,$previous
            Write-Warning "$(Get-ImmichCleanupText failed): $previous. $($_.Exception.Message)" -WarningAction Continue
        }
    } catch {
        $result.RetainedReleases+=,$PreviousReleasePath
        Write-Warning "$(Get-ImmichCleanupText retained): $PreviousReleasePath. $($_.Exception.Message)" -WarningAction Continue
    }
    $statusKey=if ($result.Status -eq 'skipped') { 'skippedStatus' } else { $result.Status }
    Write-Host ((Get-ImmichCleanupText summary) -f (Get-ImmichCleanupText $statusKey),$result.RemovedReleases.Count,$result.RetainedReleases.Count,$result.FailedReleases.Count)
    return [pscustomobject]$result
}
