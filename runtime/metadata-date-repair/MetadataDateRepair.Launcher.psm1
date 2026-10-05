#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Pure Windows argv parser. Never evaluates registration strings as PowerShell.
function ConvertFrom-RepairWindowsCommandLine {
    param([Parameter(Mandatory)][string]$CommandLine)
    $result = [Collections.Generic.List[string]]::new()
    $i = 0
    while ($i -lt $CommandLine.Length) {
        while ($i -lt $CommandLine.Length -and [char]::IsWhiteSpace($CommandLine[$i])) { $i++ }
        if ($i -eq $CommandLine.Length) { break }
        $word = [Text.StringBuilder]::new()
        $quoted = $false
        while ($i -lt $CommandLine.Length) {
            if (-not $quoted -and [char]::IsWhiteSpace($CommandLine[$i])) { break }
            $slashes = 0
            while ($i -lt $CommandLine.Length -and $CommandLine[$i] -eq [char]'\') { $slashes++; $i++ }
            if ($i -lt $CommandLine.Length -and $CommandLine[$i] -eq [char]'"') {
                [void]$word.Append(('\' * [int][Math]::Floor($slashes / 2)))
                if ($slashes % 2) { [void]$word.Append('"') } else { $quoted = -not $quoted }
                $i++
            } else {
                [void]$word.Append(('\' * $slashes))
                if ($i -lt $CommandLine.Length -and ($quoted -or -not [char]::IsWhiteSpace($CommandLine[$i]))) {
                    [void]$word.Append($CommandLine[$i]); $i++
                }
            }
        }
        if ($quoted) { throw 'InvalidRegistration' }
        $result.Add($word.ToString())
    }
    return $result.ToArray()
}

function Get-RepairFullPath {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.Path]::IsPathFullyQualified($Path) -or $Path -match '[\r\n\x00]') { throw 'InvalidRegistration' }
    return [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Path))
}

function Test-RepairSamePath {
    param([string]$Left, [string]$Right)
    return [string]::Equals((Get-RepairFullPath $Left), (Get-RepairFullPath $Right), [StringComparison]::OrdinalIgnoreCase)
}

function ConvertFrom-RepairTrayRegistration {
    param([Parameter(Mandatory)]$Shortcut)
    $tokens = @(ConvertFrom-RepairWindowsCommandLine $Shortcut.Arguments)
    $values = @{}
    if ($tokens.Count -ne 8) { throw 'InvalidRegistration' }
    for ($i = 0; $i -lt $tokens.Count; $i += 2) {
        if ($tokens[$i] -cnotin @('--install-root','--data-root','--scope','--powershell-path') -or $values.ContainsKey($tokens[$i])) { throw 'InvalidRegistration' }
        $values[$tokens[$i]] = $tokens[$i + 1]
    }
    if ($values['--scope'] -cnotin @('AllUsers','CurrentUser')) { throw 'InvalidRegistration' }
    $root = Get-RepairFullPath $values['--install-root']
    $data = Get-RepairFullPath $values['--data-root']
    if (-not (Test-RepairSamePath $Shortcut.TargetPath (Join-Path $root 'current/runtime/tray/ImmichTray.exe'))) { throw 'InvalidRegistration' }
    [pscustomobject]@{ Scope=$values['--scope']; InstallRoot=$root; DataRoot=$data; Service=$false }
}

function ConvertFrom-RepairRunRegistration {
    param([Parameter(Mandatory)][string]$CommandLine)
    $tokens = @(ConvertFrom-RepairWindowsCommandLine $CommandLine)
    # Exact shape emitted by Set-ImmichUserStartup; no shell interpretation.
    if ($tokens.Count -ne 12 -or $tokens[1] -ine '-NoProfile' -or $tokens[2] -ine '-WindowStyle' -or
        $tokens[3] -ine 'Hidden' -or $tokens[4] -ine '-File' -or $tokens[6] -ine '-EnvFile' -or
        $tokens[8] -ine '-InstallRoot' -or $tokens[10] -ine '-DataRoot') { throw 'InvalidRegistration' }
    if ([IO.Path]::GetFileName($tokens[0]) -ine 'pwsh.exe') { throw 'InvalidRegistration' }
    $root = Get-RepairFullPath $tokens[9]
    $data = Get-RepairFullPath $tokens[11]
    if (-not (Test-RepairSamePath $tokens[5] (Join-Path $root 'current/runtime/launchers/Start-Immich.ps1')) -or
        -not (Test-RepairSamePath $tokens[7] (Join-Path $data 'immich.env'))) { throw 'InvalidRegistration' }
    [pscustomobject]@{ Scope='CurrentUser'; InstallRoot=$root; DataRoot=$data; Service=$false }
}

function ConvertFrom-RepairServiceRegistration {
    param([Parameter(Mandatory)][string]$ImagePath)
    $tokens = @(ConvertFrom-RepairWindowsCommandLine $ImagePath)
    if ($tokens.Count -ne 1) { throw 'InvalidRegistration' }
    $executable = Get-RepairFullPath $tokens[0]
    $services = Split-Path -Parent $executable
    if ([IO.Path]::GetFileName($executable) -ine 'ImmichServer.exe' -or [IO.Path]::GetFileName($services) -ine 'services') { throw 'InvalidRegistration' }
    [pscustomobject]@{ Scope='AllUsers'; InstallRoot=''; DataRoot=(Split-Path -Parent $services); Service=$true }
}

function Resolve-RepairServiceInstallRoot {
    param([Parameter(Mandatory)][string]$DataRoot)
    # XML is read only after AllUsers elevation. Never resolve external entities.
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = [Xml.XmlReader]::Create((Join-Path $DataRoot 'services/ImmichServer.xml'), $settings)
    try { $xml = [Xml.XmlDocument]::new(); $xml.XmlResolver = $null; $xml.Load($reader) } finally { $reader.Dispose() }
    if ([string]$xml.service.id -cne 'ImmichServer') { throw 'InvalidRegistration' }
    $current = Get-RepairFullPath ([string]$xml.service.workingdirectory)
    if ([IO.Path]::GetFileName($current) -ine 'current') { throw 'InvalidRegistration' }
    $root = Split-Path -Parent $current
    $tokens = @(ConvertFrom-RepairWindowsCommandLine ([string]$xml.service.arguments))
    if ($tokens.Count -ne 7 -or $tokens[0] -ine '-NoProfile' -or $tokens[1] -ine '-File' -or
        $tokens[3] -ine '-EnvFile' -or $tokens[5] -ine '-ServiceRole' -or $tokens[6] -cne 'Server' -or
        -not (Test-RepairSamePath $tokens[2] (Join-Path $current 'runtime/launchers/Load-ImmichEnv.ps1')) -or
        -not (Test-RepairSamePath $tokens[4] (Join-Path $DataRoot 'immich.env'))) { throw 'InvalidRegistration' }
    return $root
}

function Merge-RepairInstallCandidates {
    param([AllowEmptyCollection()][object[]]$Candidates = @())
    $merged = [Collections.Generic.List[object]]::new()
    foreach ($candidate in $Candidates) {
        $existing = @($merged | Where-Object { $_.Scope -ceq $candidate.Scope -and (Test-RepairSamePath $_.DataRoot $candidate.DataRoot) })
        if ($existing.Count) {
            $item = $existing[0]
            if ($item.InstallRoot -and $candidate.InstallRoot -and -not (Test-RepairSamePath $item.InstallRoot $candidate.InstallRoot)) { throw 'ConflictingRegistration' }
            if (-not $item.InstallRoot) { $item.InstallRoot = $candidate.InstallRoot }
            $item.Service = $item.Service -or $candidate.Service
        } else { $merged.Add([pscustomobject]@{Scope=$candidate.Scope; InstallRoot=$candidate.InstallRoot; DataRoot=$candidate.DataRoot; Service=[bool]$candidate.Service}) }
    }
    return $merged.ToArray()
}

function Get-RepairRegistryRecord {
    param([Parameter(Mandatory)][string]$Path)
    try { return Get-ItemProperty -LiteralPath $Path -ErrorAction Stop }
    catch [System.Management.Automation.ItemNotFoundException] { return $null }
}

function Get-RepairInstallCandidates {
    param([switch]$AllUsersOnly)
    $found = [Collections.Generic.List[object]]::new()
    $startup = [Environment]::GetFolderPath('Startup')
    foreach ($scope in @('CurrentUser','AllUsers')) {
        # The elevated handoff trusts only the machine registration, never another admin's profile.
        if ($AllUsersOnly) { continue }
        $path = Join-Path $startup "Immich Tray - $scope.lnk"
        if (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction Stop) {
            $candidate = ConvertFrom-RepairTrayRegistration (Read-ImmichShortcut -Path $path)
            if ($candidate.Scope -cne $scope) { throw 'InvalidRegistration' }
            $found.Add($candidate)
        }
    }
    if (-not $AllUsersOnly) {
        $run = Get-RepairRegistryRecord -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        if ($run -and $run.PSObject.Properties['ImmichWindows']) { $found.Add((ConvertFrom-RepairRunRegistration ([string]$run.ImmichWindows))) }
    }
    $service = Get-RepairRegistryRecord -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\ImmichServer'
    if ($service -and $service.PSObject.Properties['ImagePath']) { $found.Add((ConvertFrom-RepairServiceRegistration ([string]$service.ImagePath))) }
    return @(Merge-RepairInstallCandidates -Candidates $found.ToArray())
}

function Resolve-RepairInstall {
    param([Parameter(Mandatory)]$Candidate)
    if ($Candidate.Service) {
        $serviceRoot = Resolve-RepairServiceInstallRoot -DataRoot $Candidate.DataRoot
        if ($Candidate.InstallRoot -and -not (Test-RepairSamePath $Candidate.InstallRoot $serviceRoot)) { throw 'ConflictingRegistration' }
        $Candidate.InstallRoot = $serviceRoot
    }
    if (-not $Candidate.InstallRoot) { throw 'InvalidRegistration' }
    # Explicit roots only: this helper's default-directory behavior is never used.
    $paths = Resolve-ImmichInstallPaths -Scope $Candidate.Scope -InstallRoot $Candidate.InstallRoot -DataRoot $Candidate.DataRoot
    $release = Get-CurrentReleaseTarget -InstallRoot $paths.InstallRoot
    if (-not $release) { throw 'MissingRuntime' }
    $envFile = Join-Path $paths.DataRoot 'immich.env'
    $values = Read-EnvFile -Path $envFile
    if ([string]$values['IMMICH_WINDOWS_INSTALL_SCOPE'] -cne $Candidate.Scope) { throw 'ConflictingRegistration' }
    $output = Join-Path $paths.DataRoot 'state/metadata-date-repair'
    foreach ($path in @((Join-Path $paths.DataRoot 'state'), $output)) {
        if (Test-Path -LiteralPath $path) {
            $item = Get-Item -LiteralPath $path -Force
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'UnsafeOutput' }
        }
    }
    foreach ($path in @((Join-Path $release 'manifest.json'), (Join-Path $release 'runtime/node/node.exe'),
        (Join-Path $release 'runtime/launchers/Load-ImmichEnv.ps1'), (Join-Path $release 'runtime/metadata-date-repair/guided.cjs'))) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'MissingRuntime' }
    }
    [pscustomobject]@{ Scope=$Candidate.Scope; InstallRoot=$paths.InstallRoot; DataRoot=$paths.DataRoot; ReleaseRoot=$release; EnvFile=$envFile; OutputRoot=$output }
}

function Resolve-RepairStartupTimezone {
    param([ValidateSet('AllUsers','CurrentUser')][string]$Scope, [AllowNull()][string]$UserTimezone, [AllowNull()][string]$MachineTimezone)
    # Match the service/sign-in startup environment; the installed env loader overrides this.
    # No configured TZ means Node uses the Windows system timezone, as the server does.
    if ($Scope -eq 'CurrentUser' -and -not [string]::IsNullOrEmpty($UserTimezone)) { return $UserTimezone }
    return $MachineTimezone
}

function Select-RepairResumeFolder {
    param(
        [Parameter(Mandatory)][string]$OutputRoot,
        [ValidateSet('ja','en')][string]$Language = 'en'
    )
    # Start only from the verified installation's repair output. Never search for
    # runs or silently choose one: the user must select a folder and press OK.
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
    try {
        $dialog.Description = if ($Language -eq 'ja') { '再開する前回の修復フォルダーを選んでください' } else { 'Select the previous repair folder to resume' }
        $dialog.SelectedPath = $OutputRoot
        $dialog.ShowNewFolderButton = $false
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            return $dialog.SelectedPath
        }
        return $null
    } finally { $dialog.Dispose() }
}

function Clear-RepairConnectionEnvironment {
    foreach ($name in @([Environment]::GetEnvironmentVariables('Process').Keys)) {
        # The provider deletes the variable; .NET's string API binds $null as an empty value in PowerShell 7.5+.
        if ([string]$name -match '^(DB_|PG|TZ$)') { Remove-Item -LiteralPath ("Env:" + $name) -ErrorAction Stop }
    }
}

Export-ModuleMember -Function ConvertFrom-RepairWindowsCommandLine,ConvertFrom-RepairTrayRegistration,ConvertFrom-RepairRunRegistration,ConvertFrom-RepairServiceRegistration,Resolve-RepairServiceInstallRoot,Merge-RepairInstallCandidates,Get-RepairInstallCandidates,Resolve-RepairInstall,Clear-RepairConnectionEnvironment,Test-RepairSamePath,Resolve-RepairStartupTimezone,Select-RepairResumeFolder
