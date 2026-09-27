Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'


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

function Get-RelativePathPortable {
    param([Parameter(Mandatory)][string]$BasePath,[Parameter(Mandatory)][string]$FullPath)
    $base = (Resolve-Path -LiteralPath $BasePath).Path.TrimEnd('\') + '\'
    $full = (Resolve-Path -LiteralPath $FullPath).Path
    $baseUri = New-Object System.Uri($base)
    $fullUri = New-Object System.Uri($full)
    if ($baseUri.Scheme -ne $fullUri.Scheme) { return $full }
    return [Uri]::UnescapeDataString($baseUri.MakeRelativeUri($fullUri).ToString()).Replace('/','\')
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
    $pwsh=(Get-Command pwsh.exe -ErrorAction Stop).Source
    $entry=Join-Path $InstallRoot 'current\runtime\launchers\Start-Immich.ps1'
    $envFile=Join-Path $DataRoot 'immich.env'
    $command='"{0}" -NoProfile -WindowStyle Hidden -File "{1}" -EnvFile "{2}" -InstallRoot "{3}" -DataRoot "{4}"' -f $pwsh,$entry,$envFile,$InstallRoot,$DataRoot
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
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.TrimStart().StartsWith('#')) { continue }
        $index = $line.IndexOf('=')
        if ($index -lt 1) { throw "Invalid env line in ${Path}: $line" }
        $key = $line.Substring(0, $index).Trim()
        $value = $line.Substring($index + 1)
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

function Escape-XmlValue([string]$Value) {
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
    $current = Join-Path $InstallRoot 'current'
    $existing = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
    if ($existing) {
        if (-not ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Refusing to replace non-junction current path: $current"
        }
        # Use cmd.exe rmdir for directory junctions. It removes only the reparse
        # point, including a dangling junction whose target was replaced.
        & cmd.exe /d /c rmdir "$current"
        $remaining = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($LASTEXITCODE -ne 0 -and $remaining) {
            throw "Failed to remove existing current release junction: $current"
        }
    }
    New-Item -ItemType Junction -Path $current -Target $ReleasePath | Out-Null
}

function Install-ReleaseDirectory {
    param([Parameter(Mandatory)][string]$PackageRoot, [Parameter(Mandatory)][string]$InstallRoot)
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $PackageRoot 'manifest.json') | ConvertFrom-Json
    $version = $manifest.immichVersion
    $release = Join-Path $InstallRoot "releases\$version"
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
    foreach($rule in $rules){
        $fullControl=($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl
        $inherited=($rule.InheritanceFlags -band $requiredInheritance) -eq $requiredInheritance
        if($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or -not $fullControl -or -not $inherited){continue}
        if($rule.IdentityReference.Value -eq 'S-1-5-18'){$hasSystem=$true}
        if($rule.IdentityReference.Value -eq 'S-1-5-32-544'){$hasAdministrators=$true}
    }
    if($acl.AreAccessRulesProtected -and $hasSystem -and $hasAdministrators){return}
    # immich.env contains the database password. Restrict the persistent config,
    # service wrappers and logs to LocalSystem and local Administrators using SIDs
    # so this works on non-English Windows installations as well.
    & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /T /C | Out-Host
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

Export-ModuleMember -Function *
