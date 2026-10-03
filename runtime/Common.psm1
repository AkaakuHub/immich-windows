#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'


function ConvertTo-WindowsArgument {
    param([Parameter(Mandatory)][string]$Value)
    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]'\') { $backslashes++; continue }
        if ($character -eq [char]'"') {
            [void]$builder.Append(('\' * (2 * $backslashes + 1)))
            [void]$builder.Append('"')
        } else {
            [void]$builder.Append(('\' * $backslashes))
            [void]$builder.Append($character)
        }
        $backslashes = 0
    }
    [void]$builder.Append(('\' * (2 * $backslashes)))
    [void]$builder.Append('"')
    $builder.ToString()
}

function Get-ImmichLocalUrl {
    param([Parameter(Mandatory)][string]$EnvFile,[string]$InstallRoot)
    try { $values=Read-EnvFile $EnvFile } catch [UnauthorizedAccessException] {
        if (-not $InstallRoot) { throw }
        # Non-administrator desktop users must never receive the private env.
        $hint=Get-Content -Raw -LiteralPath (Join-Path $InstallRoot 'tray-connection.json') | ConvertFrom-Json
        $uri=[uri]([string]$hint.url)
        if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'http' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { throw 'Invalid public Immich connection hint.' }
        return $uri.AbsoluteUri
    }
    $port=if ($values['IMMICH_PORT']) { [int]$values['IMMICH_PORT'] } else { 2283 }
    if ($port -lt 1 -or $port -gt 65535) { throw 'IMMICH_PORT must be between 1 and 65535.' }
    $hostname=[string]$values['IMMICH_HOST']
    if (-not $hostname -or $hostname -in @('0.0.0.0','::','[::]')) { $hostname='localhost' }
    return [UriBuilder]::new('http',$hostname,$port).Uri.AbsoluteUri
}

function Write-ImmichTrayConnectionHint {
    param([Parameter(Mandatory)][string]$InstallRoot,[Parameter(Mandatory)][string]$DataRoot)
    $url=Get-ImmichLocalUrl -EnvFile (Join-Path $DataRoot 'immich.env')
    $path=Join-Path $InstallRoot 'tray-connection.json'
    [IO.File]::WriteAllText($path, (@{url=$url} | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
}

function Get-ImmichManagedShortcutNames {
    # Only the eight names created by previous Immich Windows versions.
    'Open Immich'; 'Start Immich'; 'Stop Immich'; 'Update Immich'
    'Immichを開く'; 'Immichを起動'; 'Immichを停止'; 'Immichを更新'
}

function Initialize-ImmichShellLink {
    if ('Immich.Windows.ShortcutStore' -as [type]) { return }
    # Use IShellLinkW/IPersistFile directly: WScript shortcut persistence can lose non-ANSI file names.
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
namespace Immich.Windows {
    [ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellLinkW {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int count, IntPtr data, uint flags);
        void GetIDList(out IntPtr pidl);
        void SetIDList(IntPtr pidl);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder text, int count);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string text);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int count);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string path);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder args, int count);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string args);
        void GetHotkey(out short key);
        void SetHotkey(short key);
        void GetShowCmd(out int command);
        void SetShowCmd(int command);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int count, out int index);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string path, int index);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path, uint reserved);
        void Resolve(IntPtr window, uint flags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string path);
    }
    public sealed class ShortcutInfo {
        public string TargetPath;
        public string Arguments;
        public string IconLocation;
    }
    public static class ShortcutStore {
        static object Create() {
            return Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("00021401-0000-0000-C000-000000000046"), true));
        }
        public static void Write(string path, string target, string args, string icon, string directory, string description, int show) {
            object value=Create();
            try {
                var link=(IShellLinkW)value;
                link.SetPath(target);
                link.SetArguments(args);
                link.SetIconLocation(icon,0);
                link.SetWorkingDirectory(directory);
                link.SetDescription(description);
                link.SetShowCmd(show);
                ((IPersistFile)value).Save(path,true);
            } finally { Marshal.FinalReleaseComObject(value); }
        }
        public static ShortcutInfo Read(string path) {
            object value=Create();
            try {
                ((IPersistFile)value).Load(path,0);
                var link=(IShellLinkW)value;
                var target=new StringBuilder(32768);
                var args=new StringBuilder(32768);
                var icon=new StringBuilder(32768);
                int index;
                link.GetPath(target,target.Capacity,IntPtr.Zero,4);
                link.GetArguments(args,args.Capacity);
                link.GetIconLocation(icon,icon.Capacity,out index);
                return new ShortcutInfo {TargetPath=target.ToString(),Arguments=args.ToString(),IconLocation=icon.ToString()+","+index};
            } finally { Marshal.FinalReleaseComObject(value); }
        }
    }
}
'@
}

function Write-ImmichShortcut {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Entry)
    Initialize-ImmichShellLink
    if (-not $Entry.IconLocation.EndsWith(',0')) { throw 'Immich shortcut must use icon index zero.' }
    $icon=$Entry.IconLocation.Substring(0,$Entry.IconLocation.Length-2)
    [Immich.Windows.ShortcutStore]::Write($Path,$Entry.TargetPath,$Entry.Arguments,$icon,$Entry.WorkingDirectory,$Entry.Description,$Entry.WindowStyle)
}

function Read-ImmichShortcut {
    param([Parameter(Mandatory)][string]$Path)
    Initialize-ImmichShellLink
    return [Immich.Windows.ShortcutStore]::Read($Path)
}

function Remove-ImmichLegacyStartMenu {
    param([Parameter(Mandatory)][ValidateSet('AllUsers','CurrentUser')][string]$Scope)
    $programs=[Environment]::GetFolderPath($(if ($Scope -eq 'AllUsers') { 'CommonPrograms' } else { 'Programs' }))
    $directory=Join-Path $programs 'Immich'
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { return }
    foreach ($name in Get-ImmichManagedShortcutNames) {
        Remove-Item -LiteralPath (Join-Path $directory "$name.lnk") -Force -ErrorAction SilentlyContinue
    }
    if (-not @(Get-ChildItem -LiteralPath $directory -Force).Count) { Remove-Item -LiteralPath $directory -Force }
}

function Get-ImmichTrayEntry {
    param([Parameter(Mandatory)][string]$InstallRoot,[Parameter(Mandatory)][string]$DataRoot,
          [Parameter(Mandatory)][ValidateSet('AllUsers','CurrentUser')][string]$Scope)
    $current=Join-Path $InstallRoot 'current'
    $arguments=(@('--install-root',$InstallRoot,'--data-root',$DataRoot,'--scope',$Scope,
        '--powershell-path',(Join-Path $PSHOME 'pwsh.exe')) | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' '
    [pscustomobject]@{
        Name="Immich Tray - $Scope"
        TargetPath=(Join-Path $current 'runtime\tray\ImmichTray.exe')
        Arguments=$arguments
        IconLocation=((Join-Path $current 'build\www\favicon.ico')+',0')
        WorkingDirectory=$InstallRoot
        Description='Immich notification-area controls'
        WindowStyle=7
    }
}

function Set-ImmichTrayStartup {
    param([Parameter(Mandatory)][string]$InstallRoot,[Parameter(Mandatory)][string]$DataRoot,
          [Parameter(Mandatory)][ValidateSet('AllUsers','CurrentUser')][string]$Scope,[bool]$Enabled=$true)
    # Desktop UI belongs to this user/session; AllUsers services still start at boot.
    $entry=Get-ImmichTrayEntry -InstallRoot $InstallRoot -DataRoot $DataRoot -Scope $Scope
    $startup=[Environment]::GetFolderPath('Startup')
    $path=Join-Path $startup ($entry.Name+'.lnk')
    if (-not $Enabled) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue; return }
    if (-not (Test-Path -LiteralPath $entry.TargetPath -PathType Leaf)) { throw "Tray application is missing: $($entry.TargetPath)" }
    New-Item -ItemType Directory -Path $startup -Force | Out-Null
    Write-ImmichShortcut -Path $path -Entry $entry
}

function Test-ImmichElevated {
    if (-not $IsWindows) { return $false }
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Initialize-ImmichDesktopShell {
    if (-not ('Immich.Windows.DesktopShell' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'tray\DesktopShell.cs')
    }
}

function Get-ImmichTrayProcesses {
    param([Parameter(Mandatory)][string]$InstallRoot,[Parameter(Mandatory)][string]$ReleasePath)
    Initialize-ImmichDesktopShell
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    try { $sid=$identity.User.Value } finally { $identity.Dispose() }
    $caller=[Diagnostics.Process]::GetCurrentProcess()
    try { $session=$caller.SessionId } finally { $caller.Dispose() }
    $paths=@((Join-Path $ReleasePath 'runtime\tray\ImmichTray.exe'),(Join-Path $InstallRoot 'current\runtime\tray\ImmichTray.exe')) | ForEach-Object { [IO.Path]::GetFullPath($_) }
    # Take one bounded snapshot before signalling. Never kill a process or scan releases.
    # Both spellings are exact: Windows can report the original current-junction path.
    $captured=[Collections.Generic.List[Diagnostics.Process]]::new()
    try {
        foreach ($process in @(Get-Process -Name ImmichTray -ErrorAction SilentlyContinue)) {
            $retain=$false
            $matchedPath=$false
            try {
                # Pin before any identity reads; an exiting process cannot be replaced by PID reuse.
                $null=$process.Handle
                if ($process.SessionId -ne $session) { continue }
                $matchedPath=[IO.Path]::GetFullPath($process.MainModule.FileName) -iin $paths
                if ($matchedPath -and [Immich.Windows.DesktopShell]::ProcessUser($process) -eq $sid) {
                    $captured.Add($process)
                    $retain=$true
                }
            } catch [ComponentModel.Win32Exception] {
                # An inaccessible unrelated process with the same basename is not our tray.
                # Once the exact image matched, inability to verify its SID fails closed.
                if ($matchedPath -or $_.Exception.NativeErrorCode -ne 5) { throw }
            } catch [InvalidOperationException] { if (-not $process.HasExited) { throw } }
            finally { if (-not $retain) { $process.Dispose() } }
        }
        return $captured.ToArray()
    } catch {
        foreach ($process in $captured) { $process.Dispose() }
        throw
    }
}

function Stop-ImmichTray {
    param([Parameter(Mandatory)][string]$InstallRoot,[string]$ReleasePath=(Get-CurrentReleaseTarget -InstallRoot $InstallRoot))
    $executable=Join-Path $InstallRoot 'current\runtime\tray\ImmichTray.exe'
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { return }
    Initialize-ImmichDesktopShell
    $desktop=[Immich.Windows.DesktopShell]::GetDesktopProcess()
    try {
        $desktopSid=if ($desktop) { [Immich.Windows.DesktopShell]::ProcessUser($desktop) } else { $null }
        if ($desktopSid) {
            $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
            try { $sameUser=$desktopSid -eq $identity.User.Value } finally { $identity.Dispose() }
            if (-not $sameUser) { throw 'The desktop belongs to a different user from this updater. Its tray was left running; close that tray before removing the previous release.' }
        }
    } finally { if ($desktop) { $desktop.Dispose() } }
    $processes=@(Get-ImmichTrayProcesses -InstallRoot $InstallRoot -ReleasePath $ReleasePath)
    try {
        $arguments=(@('--install-root',$InstallRoot,'--exit-existing') | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' '
        $control=Start-Process -FilePath $executable -ArgumentList $arguments -Wait -PassThru
        try { if ($control.ExitCode -ne 0) { throw "Could not close this session's Immich tray (exit $($control.ExitCode))." } }
        finally { $control.Dispose() }
        # v8 signals completion when its mutex is released, just before the EXE unloads.
        # Wait for the captured process itself, with no retry loop or file-open polling.
        foreach ($process in $processes) {
            if (-not $process.WaitForExit(10000)) { throw "Immich tray process $($process.Id) did not exit within 10 seconds." }
        }
    } finally { foreach ($process in $processes) { $process.Dispose() } }
}

function Start-ImmichTray {
    param([Parameter(Mandatory)][string]$InstallRoot,[Parameter(Mandatory)][string]$DataRoot,
          [Parameter(Mandatory)][ValidateSet('AllUsers','CurrentUser')][string]$Scope)
    $entry=Get-ImmichTrayEntry -InstallRoot $InstallRoot -DataRoot $DataRoot -Scope $Scope
    Initialize-ImmichDesktopShell
    $desktop=[Immich.Windows.DesktopShell]::GetDesktopProcess()
    if (-not $desktop) {
        Write-Host 'No desktop shell is available in this session. Immich tray will start at the next desktop sign-in.'
        return
    }
    try {
        $elevated=Test-ImmichElevated
        if ($elevated -and [Immich.Windows.DesktopShell]::IsElevated($desktop)) {
            Write-Warning (Get-ImmichProgressText trayDeferred)
            return
        }
    } finally { $desktop.Dispose() }
    if ($elevated) {
        [Immich.Windows.DesktopShell]::Execute($entry.TargetPath,$entry.Arguments,$InstallRoot)
    } else {
        # Start is idempotent via the tray's SID/session/install mutex. Replacement
        # requires an explicit Stop before cleanup; starting never hides another stop.
        Start-Process -FilePath $entry.TargetPath -ArgumentList $entry.Arguments -WorkingDirectory $InstallRoot | Out-Null
    }
}

function Get-WindowsReleaseVersion {
    param([Parameter(Mandatory)]$Upstream)
    if ([string]$Upstream.version -cnotmatch '\Av(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z' -or
        [string]$Upstream.windowsRevision -cnotmatch '\A(0|[1-9][0-9]*)\z') {
        throw 'upstream.json must contain a stable upstream version and a nonnegative windowsRevision.'
    }
    return 'v' + ([version]("$($Upstream.version.TrimStart('v')).$($Upstream.windowsRevision)")).ToString(4)
}


function Get-WindowsPackageVersion {
    param([Parameter(Mandatory)]$Manifest)
    $upstream = [string]$Manifest.immichVersion
    if ($upstream -cnotmatch '\Av(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z') {
        throw "Invalid upstream version: $upstream"
    }
    # Schema 1 packages omitted the Windows revision; preserve their documented revision-zero identity.
    if (-not $Manifest.PSObject.Properties['windowsRevision']) {
        if ($Manifest.schemaVersion -ne 1 -or $Manifest.PSObject.Properties['packageVersion']) {
            throw 'Missing Windows package revision.'
        }
        return [version]($upstream.TrimStart('v') + '.0')
    }
    $revision = [string]$Manifest.windowsRevision
    if ($revision -cnotmatch '\A(0|[1-9][0-9]*)\z') { throw "Invalid Windows revision: $revision" }
    $version = [version]($upstream.TrimStart('v') + '.' + $revision)
    if ([string]$Manifest.packageVersion -cne "v$version") { throw 'Package version does not match upstream and Windows revision.' }
    return $version
}

function Test-ImmichDatabasePayloadEqual {
    param([Parameter(Mandatory)][string]$PreviousRelease,[Parameter(Mandatory)][string]$CandidateRelease,$DependencyReusePlan)
    $previous = Get-Content -Raw (Join-Path $PreviousRelease 'manifest.json') | ConvertFrom-Json
    $candidate = Get-Content -Raw (Join-Path $CandidateRelease 'manifest.json') | ConvertFrom-Json
    foreach ($field in @('immichVersion','upstreamCommit')) {
        if (-not $previous.PSObject.Properties[$field] -or -not $candidate.PSObject.Properties[$field] -or
            [string]$previous.$field -cne [string]$candidate.$field) { return $false }
    }
    if (-not $previous.PSObject.Properties['dependencies'] -or -not $candidate.PSObject.Properties['dependencies']) { return $false }
    # A matching release number alone never proves that the database-facing code is unchanged.
    foreach ($name in @('node','postgresql','pgvector','vectorchord')) {
        if (-not $previous.dependencies.PSObject.Properties[$name] -or -not $candidate.dependencies.PSObject.Properties[$name]) { return $false }
        if (($previous.dependencies.$name | ConvertTo-Json -Depth 10 -Compress) -cne
            ($candidate.dependencies.$name | ConvertTo-Json -Depth 10 -Compress)) { return $false }
    }
    $requiredFiles = @('server\package.json','server\pnpm-lock.yaml','server\pnpm-workspace.yaml','runtime\node\node.exe')
    $requiredDirectories = @('server\dist','server\.immich','dependencies\postgres-extensions','runtime\vc-runtime')
    $fingerprints = @()
    $hashes=@{}
    foreach ($root in @($PreviousRelease,$CandidateRelease)) {
        $files = @()
        foreach ($relative in $requiredFiles) {
            $path = Join-Path $root $relative
            if ($root -eq $CandidateRelease) { $path=Get-ImmichDependencyReadPath -Path $path -DependencyReusePlan $DependencyReusePlan }
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
            $files += [pscustomobject]@{FullName=$path;RelativePath=$relative.Replace('\','/')}
        }
        foreach ($relative in $requiredDirectories) {
            $path = Join-Path $root $relative
            if (-not (Test-Path -LiteralPath $path -PathType Container)) { return $false }
            $entries = @(Get-ChildItem -LiteralPath $path -Recurse -File -Force | Where-Object { $_.Name -ne 'build-inputs.json' -and $_.FullName -notmatch '[\\/]runtime[\\/]vc-runtime[\\/]vc-runtime\.json$' })
            if (-not $entries.Count) { return $false }
            $files += @($entries | ForEach-Object { [pscustomobject]@{FullName=$_.FullName;RelativePath=[IO.Path]::GetRelativePath($root,$_.FullName).Replace('\','/')} })
        }
        $lines = @($files | ForEach-Object {
            $relative = $_.RelativePath
            $key=[IO.Path]::GetFullPath($_.FullName)
            if (-not $hashes.ContainsKey($key)) { $hashes[$key]=(Get-FileHash -LiteralPath $key -Algorithm SHA256).Hash }
            $hash=$hashes[$key]
            "$relative=$hash"
        } | Sort-Object)
        $fingerprints += ($lines -join "`n")
    }
    return $fingerprints[0] -ceq $fingerprints[1]
}

function Test-WindowsAbsolutePath {
    param([Parameter(Mandatory)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($Path -match '^[A-Za-z]:[\\/]') { return $true }
    if ($Path -match '^\\\\[^\\]+\\[^\\]+(?:\\|$)') { return $true }
    if ($Path -match '^\\\\\?\\(?:[A-Za-z]:\\|UNC\\)') { return $true }
    return $false
}

function ConvertTo-TrimmedOutput {
    param([AllowNull()][object[]]$Output)
    $text = ''
    foreach ($item in $Output) {
        if ($null -ne $item) { $text += [string]$item }
    }
    return $text.Trim()
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this command from an elevated PowerShell session.'
    }
}

function Resolve-ImmichInstallPaths {
    param(
        [Parameter(Mandatory)][ValidateSet('AllUsers','CurrentUser')][string]$Scope,
        [string]$InstallRoot,
        [string]$DataRoot
    )
    if ($Scope -eq 'AllUsers') {
        if (-not $InstallRoot) { $InstallRoot = 'C:\Program Files\Immich' }
        if (-not $DataRoot) { $DataRoot = 'C:\ProgramData\Immich' }
    } else {
        if (-not $InstallRoot) { $InstallRoot = Join-Path $env:LOCALAPPDATA 'Programs\Immich' }
        if (-not $DataRoot) { $DataRoot = Join-Path $env:LOCALAPPDATA 'Immich' }
        foreach ($path in @($InstallRoot,$DataRoot)) {
            $fullPath = [IO.Path]::GetFullPath($path)
            $localAppData = [IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\') + '\'
            if (-not $fullPath.StartsWith($localAppData,[StringComparison]::OrdinalIgnoreCase)) {
                throw 'CurrentUser installation paths must remain under LOCALAPPDATA.'
            }
        }
    }
    return [pscustomobject]@{InstallRoot=$InstallRoot;DataRoot=$DataRoot}
}

function Set-ImmichUserStartup {
    param([Parameter(Mandatory)][string]$InstallRoot,[string]$DataRoot,[Parameter(Mandatory)][bool]$Enabled)
    $key='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $name='ImmichWindows'
    if (-not $Enabled) {
        Remove-ItemProperty -LiteralPath $key -Name $name -ErrorAction SilentlyContinue
        return
    }
    $powershellHost=Join-Path $PSHOME 'pwsh.exe'
    $entry=Join-Path $InstallRoot 'current\runtime\launchers\Start-Immich.ps1'
    $envFile=Join-Path $DataRoot 'immich.env'
    $command='"{0}" -NoProfile -WindowStyle Hidden -File "{1}" -EnvFile "{2}" -InstallRoot "{3}" -DataRoot "{4}"' -f $powershellHost,$entry,$envFile,$InstallRoot,$DataRoot
    New-Item -Path $key -Force | Out-Null
    Set-ItemProperty -LiteralPath $key -Name $name -Value $command
}

function ConvertTo-MsysPath {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -notmatch '^([A-Za-z]):[\\/](.*)$') { throw "Valkey requires a drive path for its data: $Path" }
    return '/cygdrive/' + $Matches[1].ToLowerInvariant() + '/' + $Matches[2].Replace('\','/')
}

function Read-EnvFile {
    param([Parameter(Mandatory)][string]$Path)
    $result = [ordered]@{}
    foreach ($line in Get-Content -LiteralPath $Path -Encoding utf8) {
        $entry = $line.TrimStart()
        if (-not $entry -or $entry.StartsWith('#')) { continue }
        if ($entry.StartsWith('export ')) { $entry = $entry.Substring(7).TrimStart() }
        $index = $entry.IndexOf('=')
        if ($index -lt 1) { throw "Invalid env line in ${Path}: $line" }
        $key = $entry.Substring(0, $index).Trim()
        $value = $entry.Substring($index + 1)
        if ($value.Length -ge 2 -and (($value[0] -eq '"' -and $value[$value.Length - 1] -eq '"') -or ($value[0] -eq "'" -and $value[$value.Length - 1] -eq "'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        if ($key -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw "Invalid env key in ${Path}: $key" }
        $result[$key] = $value
    }
    return $result
}

function Write-EnvFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Values)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $content = ($Values.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`r`n"
    [IO.File]::WriteAllText($Path, $content + "`r`n", [Text.UTF8Encoding]::new($false))
}

function ConvertTo-XmlValue([string]$Value) {
    return [Security.SecurityElement]::Escape($Value)
}

function Wait-HttpOk {
    param([Parameter(Mandatory)][string]$Uri, [int]$TimeoutSeconds = 90)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try {
            $r = Invoke-WebRequest -UseBasicParsing -Uri $Uri -TimeoutSec 5
            if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 400) { return }
        } catch { Start-Sleep -Seconds 2 }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for $Uri"
}

function Set-CurrentReleaseJunction {
    param([Parameter(Mandatory)][string]$InstallRoot, [Parameter(Mandatory)][string]$ReleasePath)
    if (-not (Test-Path -LiteralPath (Join-Path $ReleasePath 'manifest.json') -PathType Leaf)) { throw 'Release manifest is missing.' }
    $current = Join-Path $InstallRoot 'current'
    $existing = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
    if ($existing -and -not ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Refusing to replace non-junction current path: $current"
    }
    $next = Join-Path $InstallRoot ('current-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Junction -Path $next -Target $ReleasePath | Out-Null
        if ($existing) { [IO.Directory]::Delete($current) }
        Move-Item -LiteralPath $next -Destination $current
    } finally {
        if (Test-Path -LiteralPath $next) { [IO.Directory]::Delete($next) }
    }
}

function Install-ReleaseDirectory {
    param([Parameter(Mandatory)][string]$PackageRoot, [Parameter(Mandatory)][string]$InstallRoot)
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $PackageRoot 'manifest.json') | ConvertFrom-Json
    $version = 'v' + (Get-WindowsPackageVersion $manifest).ToString(4)
    $release = Join-Path $InstallRoot "releases\$version"
    if (Test-Path -LiteralPath $release) {
        throw "Release directory already exists: $release. Use -ResumeExistingRelease only for the identical inactive package."
    }
    New-Item -ItemType Directory -Path $release -Force | Out-Null
    & robocopy $PackageRoot $release /MIR /SL /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Host
    if ($LASTEXITCODE -gt 7) { throw "Failed to copy package to $release" }
    return $release
}


function Protect-ImmichDataRoot {
    param([Parameter(Mandatory)][string]$Path)
    $acl=Get-Acl -LiteralPath $Path
    $rules=$acl.GetAccessRules($true,$false,[Security.Principal.SecurityIdentifier])
    $requiredInheritance=[Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $hasSystem=$false
    $hasAdministrators=$false
    $installerSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $hasInstaller=$false
    foreach($rule in $rules){
        $fullControl=($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl
        $inherited=($rule.InheritanceFlags -band $requiredInheritance) -eq $requiredInheritance
        if($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or -not $fullControl -or -not $inherited){continue}
        if($rule.IdentityReference.Value -eq 'S-1-5-18'){$hasSystem=$true}
        if($rule.IdentityReference.Value -eq 'S-1-5-32-544'){$hasAdministrators=$true}
        if($rule.IdentityReference.Value -eq $installerSid){$hasInstaller=$true}
    }
    if($acl.AreAccessRulesProtected -and $hasSystem -and $hasAdministrators -and $hasInstaller){return}
    # Keep the service account and installer able to read the protected config.
    & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' "*${installerSid}:(OI)(CI)F" | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Failed to protect Immich data directory ACLs: $Path" }
    & icacls.exe (Join-Path $Path '*') /reset /T /C | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Failed to protect Immich data directory ACLs: $Path" }
}

function Get-CurrentReleaseTarget {
    param([Parameter(Mandatory)][string]$InstallRoot)
    $current = Join-Path $InstallRoot 'current'
    $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $null }
    if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Current release path is not a junction/reparse point: $current"
    }
    $target = @($item.Target) | Select-Object -First 1
    if (-not $target) { throw "Unable to resolve current release junction target: $current" }
    if (-not [IO.Path]::IsPathRooted($target)) {
        $target = Join-Path (Split-Path -Parent $current) $target
    }
    return [IO.Path]::GetFullPath([string]$target)
}

function Assert-ImmichStartupAllowed {
    param([Parameter(Mandatory)][string]$EnvFile,[Parameter(Mandatory)][string]$InstallRoot,
          [switch]$ServiceProcess,[switch]$UpgradeInProgress)
    $statePath=Join-Path (Split-Path -Parent $EnvFile) 'state\upgrade-recovery.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return }
    $state=Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
    if ($state.status -in @('qualified','recovered','preparation-failed','backup-failed')) { return }
    $blocked="Upgrade is incomplete ($($state.status)); explicit recovery is required before startup."
    if ($state.status -notin @('candidate-installed','recovery-starting')) { throw $blocked }
    # Services run in another process. CurrentUser launches run inside the updater,
    # where WaitOne succeeds recursively, so require its recorded controller too.
    $controlled=$UpgradeInProgress -and $state.PSObject.Properties['controllerProcessId'] -and
        [int]$state.controllerProcessId -eq $PID
    if (-not $ServiceProcess -and -not $controlled) { throw $blocked }
    $key=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes([IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($InstallRoot)).ToUpperInvariant())))
    if (-not $state.PSObject.Properties['controllerMutexName'] -or
        [string]$state.controllerMutexName -notmatch "^Global\\ImmichWindowsStartup-$key-[0-9a-f]{32}$") { throw $blocked }
    # A different updater may own the global serialization lock while inspecting
    # stale state. Only this recorded attempt's live gate authorizes startup.
    try { $gate=[Threading.Mutex]::OpenExisting([string]$state.controllerMutexName) }
    catch [Threading.WaitHandleCannotBeOpenedException] { throw $blocked }
    $available=$false
    try {
        try { $available=$gate.WaitOne(0) } catch [Threading.AbandonedMutexException] { $available=$true; throw $blocked }
        if (($ServiceProcess -and $available) -or ($controlled -and -not $available)) { throw $blocked }
    } finally {
        if ($available) { $gate.ReleaseMutex() }
        $gate.Dispose()
    }
}

function Set-ImmichServerDependencies {
    param([Parameter(Mandatory)][string]$Configuration,[AllowNull()][string]$PreviousConfiguration)
    $desiredXml=[xml]$Configuration
    if ([string]$desiredXml.service.id -ne 'ImmichServer') { throw 'Invalid Immich server service configuration.' }
    $required=@($desiredXml.SelectNodes('/service/depend') | ForEach-Object { $_.InnerText })
    $managed=@('ImmichValkey') # Also repair stale registrations left by an older updater.
    if ($PreviousConfiguration) {
        $previousXml=[xml]$PreviousConfiguration
        if ([string]$previousXml.service.id -ne 'ImmichServer') { throw 'Invalid previous Immich server service configuration.' }
        $managed+=@($previousXml.SelectNodes('/service/depend') | ForEach-Object { $_.InnerText })
    }
    $properties=Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\ImmichServer' -ErrorAction Stop
    $property=$properties.PSObject.Properties['DependOnService']
    $groups=$properties.PSObject.Properties['DependOnGroup']
    $existing=@(if ($property) { $property.Value }; if ($groups) { $groups.Value | ForEach-Object { '+'+$_ } })
    # Preserve dependencies added directly by the operator, outside our generated XML.
    $desired=@(@($existing | Where-Object { $_ -notin $managed })+$required | Select-Object -Unique)
    if ((@($existing | Sort-Object) -join '/') -ieq (@($desired | Sort-Object) -join '/')) { return }
    $argument=if ($desired.Count) { $desired -join '/' } else { '/' }
    & sc.exe config ImmichServer depend= $argument | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Could not reconcile ImmichServer service dependencies (exit $LASTEXITCODE)." }
}

function Get-ImmichUserProcess {
    param([string]$InstallRoot,[string]$DataRoot,[string]$Name)
    $pidFile=Join-Path $DataRoot "services\$Name.pid"
    if (-not (Test-Path -LiteralPath $pidFile -PathType Leaf)) { return }
    $process=Get-Process -Id ([int](Get-Content -Raw -LiteralPath $pidFile)) -ErrorAction SilentlyContinue
    if (-not $process -or -not $process.Path) { return }
    $roots=@((Join-Path $InstallRoot 'current'),(Get-CurrentReleaseTarget -InstallRoot $InstallRoot))
    foreach ($root in $roots) {
        if ($root -and $process.Path.StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { return $process }
    }
}

function Write-ImmichValkeyConfig {
    param([string]$Path,[string]$DataPath,[string]$LogPath,[int]$Port,[string]$Password)
    $values=@($DataPath,$LogPath,$Password) | ForEach-Object { '"'+$_.Replace('\','\\').Replace('"','\"').Replace("`r",'\r').Replace("`n",'\n')+'"' }
    $lines=@('bind 127.0.0.1 ::1','protected-mode yes',"port $Port","dir $($values[0])",'dbfilename dump.rdb','save 900 1','save 300 10','save 60 10000',"logfile $($values[1])")
    if ($Password) { $lines += "requirepass $($values[2])" }
    $lines | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
}

function Invoke-ImmichValkey {
    param([string]$Executable,[string]$Hostname,[int]$Port,[string]$Password,[string]$Username,[string[]]$Command)
    $previousAuth=$env:VALKEYCLI_AUTH
    try {
        if ($Password) { $env:VALKEYCLI_AUTH=$Password } else { Remove-Item Env:VALKEYCLI_AUTH -ErrorAction SilentlyContinue }
        $arguments=@('-h',$Hostname,'-p',[string]$Port)
        if ($Username) { $arguments += @('--user',$Username) }
        & $Executable @arguments @Command
        if ($LASTEXITCODE -ne 0) { throw "Valkey command failed with exit code $LASTEXITCODE." }
    } finally { $env:VALKEYCLI_AUTH=$previousAuth }
}


function Get-ImmichProgressText {
    param([string]$Key,[string]$Culture=[Globalization.CultureInfo]::CurrentUICulture.Name)
    $ja=$Culture.Replace('_','-').Split('-')[0] -eq 'ja'
    $messages=@{
        scan=@('Checking files','ファイルを確認中');copy=@('Copying existing files','既存ファイルをコピー中')
        python=@('Checking installed Python','既存Pythonを確認中');native=@('Comparing native dependency files','ネイティブ依存ファイルを照合中')
        node=@('Installing Node dependencies','Nodeの依存ライブラリをインストール中')
        downloadNeeded=@('Missing or changed native files to acquire','取得が必要な未配置・変更済みネイティブファイル')
        extract=@('Extracting cached archive','保存済みアーカイブを展開中');cleanup=@('Removing temporary extraction files','展開用一時ファイルを整理中')
        ml=@('Checking and synchronizing Python dependencies','Pythonの依存ライブラリを確認・同期中')
        prepare=@('Preparing the new release before stopping the current release','既存版を停止する前に新版を準備中')
        stop=@('Stopping Immich','Immichを停止中');backup=@('Backing up the database','データベースをバックアップ中')
        switch=@('Activating the prepared release','準備した新版へ切り替え中');start=@('Starting Immich','Immichを起動中')
        verify=@('Checking the updated installation','更新後の動作を確認中')
        complete=@('Completed','完了');failed=@('Failed','失敗');elapsed=@('elapsed','経過');items=@('items','件')
        selection=@('If the console title says Select, press Esc to leave selection mode.','タイトルに「選択」と表示された場合はEscで選択を解除してください。')
        trayDeferred=@('The desktop shell is elevated, so Immich tray was not started. This does not block server installation. Start the tray from a non-elevated desktop.','デスクトップシェルが管理者権限で動作しているため、Immichトレイは起動していません。サーバーのインストールは続行できます。管理者権限ではないデスクトップからトレイを起動してください。')
    }
    if (-not $messages.ContainsKey($Key)) { throw "Unknown progress message: $Key" }
    return $messages[$Key][[int]$ja]
}
function Start-ImmichProgress {
    param([string]$Key,[string]$Detail)
    $label=Get-ImmichProgressText $Key
    if ($Detail) { $label+=': '+$Detail }
    $state=@{Label=$label;Watch=[Diagnostics.Stopwatch]::StartNew();LastReport=0.0;Finished=$false}
    Write-Host ('[{0:HH:mm:ss}] {1}' -f [DateTime]::Now,$label)
    return $state
}
function Update-ImmichProgress {
    param([System.Collections.IDictionary]$State,[long]$Completed=0,[long]$Total=-1,[switch]$Force,[switch]$Finished,[switch]$Failed)
    if ($State.Finished) { return }
    $seconds=$State.Watch.Elapsed.TotalSeconds
    if (-not $Force -and -not $Finished -and -not $Failed -and $seconds-$State.LastReport -lt 2) { return }
    $count=if ($Total -ge 0) { "${Completed}/${Total} $(Get-ImmichProgressText items)" } elseif ($Completed -gt 0) { "$Completed $(Get-ImmichProgressText items)" } else { '' }
    $status=if($Failed){Get-ImmichProgressText failed}elseif($Finished){(Get-ImmichProgressText complete)+' '+$count}else{$count}
    Write-Host ('[{0:HH:mm:ss}] {1} — {2} ({3} {4:N0}s)' -f [DateTime]::Now,$State.Label,$status,(Get-ImmichProgressText elapsed),$seconds)
    $State.LastReport=$seconds
    if ($Finished -or $Failed) { $State.Finished=$true;$State.Watch.Stop() }
}

# Preparation never modifies the running release. Controlled updates defer unchanged
# directories for a journaled rename after shutdown; standalone preparation uses
# the existing package managers and caches.
function Get-ImmichDependencySource {
    param([string]$InstallRoot,[string]$ReleaseRoot)
    $source = Get-CurrentReleaseTarget -InstallRoot $InstallRoot
    if (-not $source) { return $null }
    $source = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($source))
    $candidate = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($ReleaseRoot))
    if ($source.Equals($candidate,[StringComparison]::OrdinalIgnoreCase)) { return $null }
    if (-not (Test-Path -LiteralPath (Join-Path $source 'manifest.json') -PathType Leaf)) { return $null }
    return $source
}
function Test-ImmichDependencyPinEqual {
    param($Previous,$Candidate,[string]$Name)
    function Canonical($Value) {
        if ($null -eq $Value) { return 'null' }
        if ($Value -is [pscustomobject]) {
            $parts = @(foreach ($p in ($Value.PSObject.Properties | Where-Object { $_.Name -notin @('notes','source') } | Sort-Object Name -CaseSensitive)) {
                (ConvertTo-Json -InputObject $p.Name -Compress) + ':' + (Canonical $p.Value)
            })
            return '{' + ($parts -join ',') + '}'
        }
        if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
            return '[' + (@(foreach ($v in $Value) { Canonical $v }) -join ',') + ']'
        }
        return ConvertTo-Json -InputObject $Value -Depth 100 -Compress
    }
    foreach ($m in @($Previous,$Candidate)) {
        if ($null -eq $m -or -not $m.PSObject.Properties['target'] -or
            -not $m.PSObject.Properties['dependencies'] -or -not $m.dependencies.PSObject.Properties[$Name]) { return $false }
    }
    if ([string]$Previous.target -cne [string]$Candidate.target) { return $false }
    return (Canonical $Previous.dependencies.$Name) -ceq (Canonical $Candidate.dependencies.$Name)
}
function Get-ImmichDependencyInputHash {
    param([string]$ReleaseRoot,[ValidateSet('server','cli')][string]$Project)
    $projectRoot = Join-Path $ReleaseRoot $Project
    $files = [Collections.Generic.List[IO.FileInfo]]::new()
    foreach ($name in @('package.json','pnpm-lock.yaml','pnpm-workspace.yaml')) {
        $item = Get-Item -LiteralPath (Join-Path $projectRoot $name) -Force -ErrorAction Stop
        if ($item -isnot [IO.FileInfo] -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Invalid dependency metadata.' }
        $files.Add($item)
    }
    if (Test-Path -LiteralPath (Join-Path $projectRoot '.npmrc')) { $files.Add((Get-Item -LiteralPath (Join-Path $projectRoot '.npmrc') -Force)) }
    if ($Project -eq 'server') {
        $sdk = Get-Item -LiteralPath (Join-Path $projectRoot '.immich/plugin-sdk') -Force -ErrorAction Stop
        if ($sdk -isnot [IO.DirectoryInfo] -or ($sdk.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Invalid plugin SDK.' }
        $pending = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
        $pending.Push($sdk)
        $sdkFiles = 0
        while ($pending.Count) {
            $directory = $pending.Pop()
            foreach ($entry in (Get-ChildItem -LiteralPath $directory.FullName -Force)) {
                if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked dependency metadata cannot be reused.' }
                if ($entry -is [IO.DirectoryInfo]) { $pending.Push($entry) } else { $files.Add($entry); $sdkFiles++ }
            }
        }
        if (-not $sdkFiles) { throw 'Plugin SDK input is empty.' }
    }
    $lines = @($files | ForEach-Object {
        $relative = [IO.Path]::GetRelativePath($projectRoot,$_.FullName).Replace('\','/')
        "$relative=$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"
    } | Sort-Object -CaseSensitive)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($lines -join [char]10))))
}
function Test-ImmichDependencyInputsEqual {
    param([string]$PreviousRelease,[string]$CandidateRelease,[ValidateSet('server','cli')][string]$Project)
    try { return (Get-ImmichDependencyInputHash $PreviousRelease $Project) -ceq (Get-ImmichDependencyInputHash $CandidateRelease $Project) }
    catch { return $false }
}
function Read-ImmichNodeDependencyState {
    param([string]$Path)
    try { if (Test-Path -LiteralPath $Path -PathType Leaf) { return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json } }
    catch { Write-Warning "Ignoring invalid dependency completion marker: $Path" }
    return $null
}
function Test-ImmichNodeProjectComplete {
    param([string]$Root,[ValidateSet('server','cli')][string]$Project)
    try {
        $package=Get-Content -Raw -LiteralPath (Join-Path $Root "$Project/package.json") | ConvertFrom-Json
        foreach ($dependency in $package.dependencies.PSObject.Properties) {
            $metadata=Join-Path $Root "$Project/node_modules/$($dependency.Name)/package.json"
            if (-not (Test-Path -LiteralPath $metadata -PathType Leaf)) { return $false }
            $installed=Get-Content -Raw -LiteralPath $metadata | ConvertFrom-Json
            if (-not $installed.PSObject.Properties['name'] -or [string]$installed.name -cne $dependency.Name) { return $false }
            if ($installed.PSObject.Properties['main'] -and [string]$installed.main -and
                -not (Test-Path -LiteralPath (Join-Path (Split-Path $metadata) $installed.main))) {
                $main=Join-Path (Split-Path $metadata) $installed.main
                if (-not (Test-Path "$main.js") -and -not (Test-Path "$main.json") -and -not (Test-Path "$main.node")) { return $false }
            }
        }
        return $true
    } catch { return $false }
}
function Test-ImmichSharpInputsEqual {
    param($Previous,$Candidate)
    $inventories=@()
    foreach ($manifest in @($Previous,$Candidate)) {
        if (-not $manifest -or -not $manifest.PSObject.Properties['nativeDependencyFiles']) { return $false }
        $entries=@($manifest.nativeDependencyFiles.PSObject.Properties | Where-Object { $_.Name.StartsWith('dependencies/sharp/') })
        if (-not $entries.Count) { return $false }
        $inventories+=((@($entries | Sort-Object Name -CaseSensitive | ForEach-Object { $_.Name+'='+([string]$_.Value).ToLowerInvariant() })) -join "`n")
    }
    if ($inventories[0] -cne $inventories[1]) { return $false }
    # Both the complete DLL set and its embedded version metadata must agree.
    foreach ($field in @('nativeDependencyMetadata')) {
        $values=@()
        foreach ($manifest in @($Previous,$Candidate)) {
            $metadata=$manifest.PSObject.Properties[$field]
            if (-not $metadata) { return $false }
            $entries=@($metadata.Value.PSObject.Properties | Where-Object { $_.Name.StartsWith('dependencies/sharp/') })
            if (-not $entries.Count) { return $false }
            $values+=((@($entries | Sort-Object Name -CaseSensitive | ForEach-Object { $_.Name+'='+[string]$_.Value })) -join "`n")
        }
        if ($values[0] -cne $values[1]) { return $false }
    }
    return $true
}
function Test-ImmichNodeProjectReusable {
    param([string]$PreviousRelease,[string]$CandidateRelease,[ValidateSet('server','cli')][string]$Project,[Collections.IDictionary]$Inputs)
    try {
        $previous=Get-Content -Raw -LiteralPath (Join-Path $PreviousRelease 'manifest.json') | ConvertFrom-Json
        $candidate=Get-Content -Raw -LiteralPath (Join-Path $CandidateRelease 'manifest.json') | ConvertFrom-Json
        $state=Read-ImmichNodeDependencyState (Join-Path $PreviousRelease '.node-dependencies-installed.json')
        if (-not $state -or -not $state.PSObject.Properties['node'] -or -not $state.PSObject.Properties['pnpm'] -or
            [string]$state.node -ne [string]$candidate.dependencies.node.version -or
            [string]$state.pnpm -ne [string]$candidate.dependencies.pnpm.version -or
            -not (Test-ImmichDependencyPinEqual $previous $candidate 'node') -or
            -not (Test-ImmichDependencyPinEqual $previous $candidate 'pnpm') -or
            -not (Test-Path -LiteralPath (Join-Path $PreviousRelease "$Project/node_modules") -PathType Container)) { return $false }
        if ($Project -eq 'server' -and -not (Test-ImmichSharpInputsEqual $previous $candidate)) { return $false }
        if (-not (Test-ImmichNodeProjectComplete $PreviousRelease $Project)) { return $false }
        $expected=if ($null -ne $Inputs -and $Inputs.Contains($Project)) { [string]$Inputs[$Project] } else { Get-ImmichDependencyInputHash $CandidateRelease $Project }
        $matches=(Get-ImmichDependencyInputHash $PreviousRelease $Project) -ceq $expected -and
            (-not $state.PSObject.Properties[$Project] -or [string]$state.$Project -ceq $expected)
        if ($matches -and $null -ne $Inputs) { $Inputs[$Project]=$expected }
        return $matches
    } catch { return $false }
}
function Get-ImmichPythonExecutable {
    param([Parameter(Mandatory)][string]$ReleaseRoot,[switch]$AllowMissing)
    $manifest=Get-Content -Raw -LiteralPath (Join-Path $ReleaseRoot 'manifest.json') | ConvertFrom-Json
    $version=[string]$manifest.dependencies.python.version
    if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid pinned Python version.' }
    $root=Join-Path $ReleaseRoot 'machine-learning/python-runtime'
    $candidates=[Collections.Generic.List[IO.FileInfo]]::new()
    # Support the legacy flat layout and uv's actual distribution, never its alias
    # junctions or arbitrary executables buried in site-packages/Scripts.
    if (Test-Path -LiteralPath $root -PathType Container) {
        $directories=@((Get-Item -LiteralPath $root -Force))
        $directories+=@(Get-ChildItem -LiteralPath $root -Directory -Force |
            Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $_.Name -like 'cpython-*' })
        foreach ($directory in $directories) {
            if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked Python runtime root.' }
            $executable=Get-Item -LiteralPath (Join-Path $directory.FullName 'python.exe') -Force -ErrorAction SilentlyContinue
            if (-not $executable) { continue }
            if ($executable -isnot [IO.FileInfo] -or ($executable.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Invalid Python executable.' }
            if ($directory.FullName -ne $directories[0].FullName -and $directory.Name -notlike "cpython-$version-windows-x86_64-*") {
                throw 'Python distribution does not match the pinned Windows x64 runtime.'
            }
            $candidates.Add($executable)
        }
    }
    if ($candidates.Count -eq 0 -and $AllowMissing) { return $null }
    if ($candidates.Count -ne 1) { throw 'Expected exactly one packaged ML Python runtime.' }
    return $candidates[0]
}

# Only the controlled updater may defer an unchanged directory until shutdown.
# The plan stays in memory until Update saves these exact paths in its existing
# recovery record, before the first rename. No dependency file inventory is built.
function Get-ImmichDependencyReadPath {
    param([string]$Path,$DependencyReusePlan)
    $full=[IO.Path]::GetFullPath($Path)
    foreach ($entry in $DependencyReusePlan) {
        $destination=[IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($entry.destination))
        if ($full.Equals($destination,[StringComparison]::OrdinalIgnoreCase)) { return [string]$entry.source }
        if ($full.StartsWith($destination+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {
            return Join-Path $entry.source ([IO.Path]::GetRelativePath($destination,$full))
        }
    }
    return $full
}
function Assert-ImmichDependencyReuseEntry {
    param($Entry,[string]$PreviousRelease,[string]$CandidateRelease)
    $relative=[string]$Entry.relativePath
    if ($relative -cnotmatch '\A(?:runtime/(?:node|ffmpeg|winsw)|dependencies/valkey|(?:server|cli)/node_modules|machine-learning/python-runtime/cpython-\d+\.\d+\.\d+-windows-x86_64-[A-Za-z0-9_.-]+)\z') {
        throw "Unexpected reusable dependency directory: $relative"
    }
    $previous=[IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($PreviousRelease))
    $candidate=[IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($CandidateRelease))
    if ($previous -ieq $candidate -or [IO.Path]::GetDirectoryName($previous) -ine [IO.Path]::GetDirectoryName($candidate)) {
        throw 'Reusable dependencies require two releases in the same releases directory.'
    }
    foreach ($pair in @(@([string]$Entry.source,(Join-Path $previous $relative)),@([string]$Entry.destination,(Join-Path $candidate $relative)))) {
        if ([IO.Path]::GetFullPath($pair[0]) -ine [IO.Path]::GetFullPath($pair[1])) { throw 'Dependency transfer path does not match its recorded release.' }
        $cursor=[IO.Path]::GetFullPath($pair[0])
        while ($cursor) {
            $item=Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
            if ($item -and ($item -isnot [IO.DirectoryInfo] -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint))) {
                throw "Dependency transfer path must be a real directory: $cursor"
            }
            $cursor=[IO.Path]::GetDirectoryName($cursor)
        }
    }
}
function Add-ImmichDependencyReuse {
    param([Collections.Generic.List[object]]$Plan,[string]$PreviousRelease,[string]$CandidateRelease,[string]$RelativePath,[string]$Label)
    if ($null -eq $Plan) { throw 'Deferred dependency reuse requires a controlled update.' }
    $relative=$RelativePath.Replace('\','/')
    $entry=[pscustomobject]@{relativePath=$relative;source=(Join-Path $PreviousRelease $relative);destination=(Join-Path $CandidateRelease $relative);label=$Label}
    Assert-ImmichDependencyReuseEntry $entry $PreviousRelease $CandidateRelease
    if (-not (Test-Path -LiteralPath $entry.source -PathType Container) -or (Test-Path -LiteralPath $entry.destination)) {
        throw 'Reusable dependency source is missing or its destination already exists.'
    }
    if (@($Plan | Where-Object { $_.relativePath -ieq $relative }).Count) { throw "Dependency is already planned: $relative" }
    $Plan.Add($entry)
    Write-Host "Keeping installed $Label for transfer after shutdown (no scan, copy, or download)."
}
function Move-ImmichReusedDependencies {
    param($DependencyReusePlan,[string]$PreviousRelease,[string]$CandidateRelease,[switch]$Restore)
    # Check every bounded plan entry before changing any directory. Directory.Move
    # never silently copies across a volume boundary and never overwrites a tree.
    foreach ($entry in $DependencyReusePlan) { Assert-ImmichDependencyReuseEntry $entry $PreviousRelease $CandidateRelease }
    $entries=@($DependencyReusePlan | ForEach-Object { $_ })
    if ($Restore) { [array]::Reverse($entries) }
    foreach ($entry in $entries) {
        $source=if ($Restore) { [string]$entry.destination } else { [string]$entry.source }
        $destination=if ($Restore) { [string]$entry.source } else { [string]$entry.destination }
        $sourceExists=Test-Path -LiteralPath $source -PathType Container
        $destinationExists=Test-Path -LiteralPath $destination -PathType Container
        if ($Restore -and -not $sourceExists -and $destinationExists) { continue }
        if (-not $sourceExists -or $destinationExists) { throw "Dependency transfer has ambiguous or missing paths: $($entry.label)" }
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
        [IO.Directory]::Move($source,$destination)
        Write-Host "$(if ($Restore) {'Restored'} else {'Moved'}) unchanged $($entry.label)."
    }
}
function Test-ImmichPythonDependencyReusable {
    param([string]$PreviousRelease,[string]$CandidateRelease,[Collections.IDictionary]$Inputs)
    try {
        $previous=Get-Content -Raw -LiteralPath (Join-Path $PreviousRelease 'manifest.json') | ConvertFrom-Json
        $candidate=Get-Content -Raw -LiteralPath (Join-Path $CandidateRelease 'manifest.json') | ConvertFrom-Json
        if (-not (Test-ImmichDependencyPinEqual $previous $candidate python)) { return $false }
        $marker=Get-Content -Raw -LiteralPath (Join-Path $PreviousRelease 'machine-learning/.dependencies-installed.json') | ConvertFrom-Json
        $requirementsHash=(Get-FileHash -LiteralPath (Join-Path $CandidateRelease 'machine-learning/requirements.txt') -Algorithm SHA256).Hash
        if ([string]$marker.python -cne [string]$candidate.dependencies.python.version -or
            [string]$marker.requirementsSha256 -ine $requirementsHash) { return $false }
        # Both CPU and DirectML launch the same exported package set. Device choice
        # changes execution, not installation. The completion marker describes the
        # installed requirements; reading the old requirements again adds no proof.
        $python=Get-ImmichPythonExecutable -ReleaseRoot $PreviousRelease
        if ($python.Directory.Name -notlike "cpython-$($candidate.dependencies.python.version)-windows-x86_64-*") { return $false }
        # Python only processes .pth files in the site-packages root. Do not walk
        # packages or cache files to check relocation; retain unused Scripts as-is
        # for recovery. Production starts python -m immich_ml, never those launchers.
        if (Test-Path -LiteralPath (Join-Path $python.Directory.FullName 'pyvenv.cfg')) { return $false }
        $site=Join-Path $python.Directory.FullName 'Lib/site-packages'
        if (-not (Test-Path -LiteralPath $site -PathType Container)) { return $false }
        foreach ($entry in (Get-ChildItem -LiteralPath $site -File -Force | Where-Object { $_.Extension -in @('.pth','.egg-link') })) {
            if ($entry.Extension -eq '.egg-link' -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
            foreach ($line in (Get-Content -LiteralPath $entry.FullName)) {
                if ($line.Trim() -match '^(?:[A-Za-z]:|[/\\])' -or $line.Contains($PreviousRelease)) { return $false }
            }
        }
        if ($null -ne $Inputs) { $Inputs.requirementsSha256=$requirementsHash.ToLowerInvariant() }
        return $true
    } catch { return $false }
}
function Assert-ImmichReusedDependencies {
    param($DependencyReusePlan,[string]$CandidateRelease)
    foreach ($entry in $DependencyReusePlan) {
        if ($entry.relativePath -like 'machine-learning/python-runtime/*') {
            $python=Get-ImmichPythonExecutable -ReleaseRoot $CandidateRelease
            $probe='import sys,pathlib,numpy,onnxruntime,uvicorn; root=pathlib.Path(sys.argv[1]).resolve(); assert pathlib.Path(sys.prefix).resolve().is_relative_to(root); assert pathlib.Path(sys.executable).resolve().is_relative_to(root); assert pathlib.Path(numpy.__file__).resolve().is_relative_to(root); assert pathlib.Path(onnxruntime.__file__).resolve().is_relative_to(root)'
            & $python.FullName -B -I -c $probe (Join-Path $CandidateRelease 'machine-learning/python-runtime')
            if ($LASTEXITCODE -ne 0) { throw 'Transferred Python imports failed validation.' }
        } elseif ($entry.relativePath -in @('server/node_modules','cli/node_modules')) {
            if (-not (Test-ImmichNodeProjectComplete -Root $CandidateRelease -Project $entry.relativePath.Split('/')[0])) { throw 'Transferred Node packages failed validation.' }
        }
    }
}

function Expand-ImmichNativePayload {
    param([Parameter(Mandatory)][string]$Archive,[Parameter(Mandatory)][string]$Destination,[Parameter(Mandatory)][string[]]$RelativePath)
    # The caller verifies the complete archive and each extracted file's SHA256.
    # Read only selected entries; never expand unrelated payloads or ZIP paths.
    $selected=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($relative in $RelativePath) {
        if (-not $relative -or $relative -match '(^/|:|(^|/)\.\.(/|$))' -or $relative.Contains('\') -or
            -not $selected.Add($relative)) { throw "Invalid or duplicate native payload path: $relative" }
    }
    $zip=[IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $entries=[Collections.Generic.Dictionary[string,IO.Compression.ZipArchiveEntry]]::new([StringComparer]::Ordinal)
        foreach ($entry in $zip.Entries) {
            if ($selected.Contains($entry.FullName)) {
                if ($entries.ContainsKey($entry.FullName)) { throw "Duplicate native ZIP entry: $($entry.FullName)" }
                $entries.Add($entry.FullName,$entry)
            }
        }
        foreach ($relative in $RelativePath) {
            if (-not $entries.ContainsKey($relative) -or -not $entries[$relative].Name) { throw "Native ZIP entry is missing: $relative" }
            $target=Join-Path $Destination $relative
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
            $input=$entries[$relative].Open()
            try {
                $output=[IO.File]::Create($target)
                try { $input.CopyTo($output) } finally { $output.Dispose() }
            } finally { $input.Dispose() }
        }
    } finally { $zip.Dispose() }
}


Export-ModuleMember -Function *
