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

function Stop-ImmichTray {
    param([Parameter(Mandatory)][string]$InstallRoot)
    $executable=Join-Path $InstallRoot 'current\runtime\tray\ImmichTray.exe'
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { return }
    $arguments=(@('--install-root',$InstallRoot,'--exit-existing') | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' '
    $process=Start-Process -FilePath $executable -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "Could not close this session's Immich tray (exit $($process.ExitCode))." }
}

function Start-ImmichTray {
    param([Parameter(Mandatory)][string]$InstallRoot,[Parameter(Mandatory)][string]$DataRoot,
          [Parameter(Mandatory)][ValidateSet('AllUsers','CurrentUser')][string]$Scope)
    if (Test-ImmichElevated) {
        Write-Host 'Immich tray is registered for sign-in. Launch its Startup shortcut from your normal desktop session.'
        return
    }
    Stop-ImmichTray -InstallRoot $InstallRoot
    $entry=Get-ImmichTrayEntry -InstallRoot $InstallRoot -DataRoot $DataRoot -Scope $Scope
    Start-Process -FilePath $entry.TargetPath -ArgumentList $entry.Arguments -WorkingDirectory $InstallRoot | Out-Null
}

function Get-WindowsReleaseVersion {
    param([Parameter(Mandatory)]$Upstream)
    if ([string]$Upstream.version -notmatch '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' -or
        [string]$Upstream.windowsRevision -notmatch '^[1-9][0-9]*$') {
        throw 'upstream.json must contain a stable upstream version and a positive windowsRevision.'
    }
    return 'v' + ([version]("$($Upstream.version.TrimStart('v')).$($Upstream.windowsRevision)")).ToString(4)
}


function Get-WindowsPackageVersion {
    param([Parameter(Mandatory)]$Manifest)
    $upstream = [string]$Manifest.immichVersion
    if ($upstream -notmatch '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
        throw "Invalid upstream version: $upstream"
    }
    # Legacy packages had no Windows revision. Treat only that documented schema as revision zero.
    if (-not $Manifest.PSObject.Properties['windowsRevision']) {
        if ($Manifest.schemaVersion -ne 1 -or $Manifest.PSObject.Properties['packageVersion']) {
            throw 'Missing Windows package revision.'
        }
        return [version]($upstream.TrimStart('v') + '.0')
    }
    $revision = [string]$Manifest.windowsRevision
    if ($revision -notmatch '^[1-9][0-9]*$') { throw "Invalid Windows revision: $revision" }
    $version = [version]($upstream.TrimStart('v') + '.' + $revision)
    if ([string]$Manifest.packageVersion -cne "v$version") { throw 'Package version does not match upstream and Windows revision.' }
    return $version
}

function Test-ImmichDatabasePayloadEqual {
    param([Parameter(Mandatory)][string]$PreviousRelease,[Parameter(Mandatory)][string]$CandidateRelease)
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
    foreach ($root in @($PreviousRelease,$CandidateRelease)) {
        $files = @()
        foreach ($relative in $requiredFiles) {
            $path = Join-Path $root $relative
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
            $files += Get-Item -LiteralPath $path
        }
        foreach ($relative in $requiredDirectories) {
            $path = Join-Path $root $relative
            if (-not (Test-Path -LiteralPath $path -PathType Container)) { return $false }
            $entries = @(Get-ChildItem -LiteralPath $path -Recurse -File -Force | Where-Object { $_.Name -ne 'build-inputs.json' -and $_.FullName -notmatch '[\\/]runtime[\\/]vc-runtime[\\/]vc-runtime\.json$' })
            if (-not $entries.Count) { return $false }
            $files += $entries
        }
        $lines = @($files | ForEach-Object {
            $relative = [IO.Path]::GetRelativePath($root,$_.FullName).Replace('\','/')
            $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
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

# Dependencies are copied into an isolated candidate; the running release is never modified.
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
function Copy-ImmichDependencyTree {
    param([string]$Source,[string]$Destination,[string[]]$ExcludeDirectoryNames=@(),[string]$Label='dependencies')
    $sourcePath = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Source))
    $destinationPath = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Destination))
    $separator = [IO.Path]::DirectorySeparatorChar
    if ($sourcePath.Equals($destinationPath,[StringComparison]::OrdinalIgnoreCase) -or
        $destinationPath.StartsWith($sourcePath+$separator,[StringComparison]::OrdinalIgnoreCase) -or
        $sourcePath.StartsWith($destinationPath+$separator,[StringComparison]::OrdinalIgnoreCase)) { throw 'Dependency source and destination overlap.' }
    foreach ($path in @($sourcePath,$destinationPath)) {
        $cursor=$path
        while ($cursor) {
            $item=Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
            if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Linked dependency path: $cursor" }
            $cursor=[IO.Path]::GetDirectoryName($cursor)
        }
    }
    $root=Get-Item -LiteralPath $sourcePath -Force -ErrorAction Stop
    if ($root -isnot [IO.DirectoryInfo]) { throw 'Dependency source is not a directory.' }
    if (Test-Path -LiteralPath $destinationPath) { throw 'Dependency destination already exists.' }
    $scan=Start-ImmichProgress -Key scan -Detail $Label
    $entries=[Collections.Generic.List[IO.FileSystemInfo]]::new()
    $pending=[Collections.Generic.Stack[IO.DirectoryInfo]]::new()
    $pending.Push($root)
    while ($pending.Count) {
        $directory=$pending.Pop()
        foreach ($entry in (Get-ChildItem -LiteralPath $directory.FullName -Force)) {
            if ($entry -is [IO.DirectoryInfo] -and $entry.Name -in $ExcludeDirectoryNames) { continue }
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked dependency entry: $($entry.FullName)" }
            $entries.Add($entry)
            Update-ImmichProgress -State $scan -Completed $entries.Count
            if ($entry -is [IO.DirectoryInfo]) { $pending.Push($entry) }
        }
    }
    Update-ImmichProgress -State $scan -Completed $entries.Count -Total $entries.Count -Finished
    $parent=[IO.Path]::GetDirectoryName($destinationPath)
    [void][IO.Directory]::CreateDirectory($parent)
    $stage=Join-Path $parent ('.dependency-copy-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($stage)
    $copy=Start-ImmichProgress -Key copy -Detail $Label
    $copied=0
    try {
        foreach ($entry in $entries) {
            $target=Join-Path $stage ([IO.Path]::GetRelativePath($sourcePath,$entry.FullName))
            if ($entry -is [IO.DirectoryInfo]) { [void][IO.Directory]::CreateDirectory($target) }
            else {
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
                [IO.File]::Copy($entry.FullName,$target,$false)
            }
            $copied++
            Update-ImmichProgress -State $copy -Completed $copied -Total $entries.Count
        }
        [IO.Directory]::Move($stage,$destinationPath)
        Update-ImmichProgress -State $copy -Completed $copied -Total $entries.Count -Finished
    } catch {
        Update-ImmichProgress -State $copy -Failed
        throw
    } finally { if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force } }
}


Export-ModuleMember -Function *
