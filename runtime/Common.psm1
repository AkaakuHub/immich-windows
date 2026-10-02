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
    param([Parameter(Mandatory)][string]$EnvFile)
    $values=Read-EnvFile $EnvFile
    $port=if ($values['IMMICH_PORT']) { [int]$values['IMMICH_PORT'] } else { 2283 }
    if ($port -lt 1 -or $port -gt 65535) { throw 'IMMICH_PORT must be between 1 and 65535.' }
    $hostname=[string]$values['IMMICH_HOST']
    if (-not $hostname -or $hostname -in @('0.0.0.0','::','[::]')) { $hostname='localhost' }
    return [UriBuilder]::new('http',$hostname,$port).Uri.AbsoluteUri
}

function Get-ImmichStartMenuEntries {
    param([Parameter(Mandatory)][string]$InstallRoot,[Parameter(Mandatory)][string]$DataRoot,
          [Parameter(Mandatory)][ValidateSet('AllUsers','CurrentUser')][string]$Scope)
    $hostPath=Join-Path $PSHOME 'pwsh.exe'
    $current=Join-Path $InstallRoot 'current'
    $envFile=Join-Path $DataRoot 'immich.env'
    $icon=Join-Path $current 'build\www\favicon.ico'
    $quote={ param([string]$Value) "'"+$Value.Replace("'","''")+"'" }
    $commonArguments=" -InstallRoot $(& $quote $InstallRoot) -DataRoot $(& $quote $DataRoot) -EnvFile $(& $quote $envFile)"
    $actions=@(
        @{Name='Immichを開く';Description='ブラウザーで写真ライブラリを開きます';Elevate=$false;Command="Import-Module $(& $quote (Join-Path $current 'runtime\Common.psm1')) -Force; Start-Process -FilePath (Get-ImmichLocalUrl -EnvFile $(& $quote $envFile))"},
        @{Name='Immichを起動';Description='Immichのサーバーと機械学習を起動します';Elevate=$true;Command="& $(& $quote (Join-Path $current 'runtime\launchers\Start-Immich.ps1'))$commonArguments"},
        @{Name='Immichを停止';Description='Immichを停止します。写真や設定は削除しません';Elevate=$true;Command="& $(& $quote (Join-Path $current 'runtime\launchers\Stop-Immich.ps1'))$commonArguments"},
        @{Name='Immichを更新';Description='既存の写真と設定を維持して最新版へ更新します';Elevate=$true;Command=$null}
    )
    $backgroundTemplate=@'
try {
    $ErrorActionPreference='Stop'
    __IMMICH_ACTION__
} catch {
    $dialog=New-Object -ComObject WScript.Shell
    [void]$dialog.Popup($_.Exception.Message,0,'Immich',16)
    exit 1
}
'@
    foreach ($action in $actions) {
        $windowStyle=7
        if ($action.Command) {
            $command=$backgroundTemplate.Replace('__IMMICH_ACTION__',$action.Command)
            $arguments='-NoProfile -WindowStyle Hidden -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        } else {
            $script=Join-Path $current 'installer\Update-FromRelease.ps1'
            $arguments=(@('-NoProfile','-NoExit','-File',$script,'-Scope',$Scope,'-InstallRoot',$InstallRoot,'-DataRoot',$DataRoot) | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' '
            $windowStyle=1
        }
        $target=$hostPath
        if ($action.Elevate -and $Scope -eq 'AllUsers') {
            $command="Start-Process -FilePath $(& $quote $hostPath) -ArgumentList $(& $quote $arguments) -Verb RunAs"
            $target=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $arguments='-NoProfile -WindowStyle Hidden -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
            $windowStyle=7
        }
        [pscustomobject]@{Name=$action.Name;TargetPath=$target;Arguments=$arguments;IconLocation="$icon,0";WorkingDirectory=$InstallRoot;Description=$action.Description;WindowStyle=$windowStyle}
    }
}

function Set-ImmichStartMenu {
    param([Parameter(Mandatory)][string]$InstallRoot,[Parameter(Mandatory)][string]$DataRoot,
          [Parameter(Mandatory)][ValidateSet('AllUsers','CurrentUser')][string]$Scope,[bool]$Enabled=$true)
    $programs=[Environment]::GetFolderPath($(if ($Scope -eq 'AllUsers') { 'CommonPrograms' } else { 'Programs' }))
    $directory=Join-Path $programs 'Immich'
    $names=@('Immichを開く','Immichを起動','Immichを停止','Immichを更新','Update Immich')
    if (-not $Enabled) {
        foreach ($name in $names) { Remove-Item -LiteralPath (Join-Path $directory "$name.lnk") -Force -ErrorAction SilentlyContinue }
        return
    }
    $icon=Join-Path $InstallRoot 'current\build\www\favicon.ico'
    if (-not (Test-Path -LiteralPath $icon -PathType Leaf)) { throw "The packaged upstream Immich icon is missing: $icon" }
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $shell=New-Object -ComObject WScript.Shell
    foreach ($entry in (Get-ImmichStartMenuEntries -InstallRoot $InstallRoot -DataRoot $DataRoot -Scope $Scope)) {
        $shortcut=$shell.CreateShortcut((Join-Path $directory "$($entry.Name).lnk"))
        foreach ($property in @('TargetPath','Arguments','IconLocation','WorkingDirectory','Description','WindowStyle')) { $shortcut.$property=$entry.$property }
        $shortcut.Save()
    }
    # Replace the single English update entry from Windows revision 1 without leaving a duplicate.
    Remove-Item -LiteralPath (Join-Path $directory 'Update Immich.lnk') -Force -ErrorAction SilentlyContinue
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
            $entries = @(Get-ChildItem -LiteralPath $path -Recurse -File -Force | Where-Object { $_.Name -ne 'build-inputs.json' })
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

Export-ModuleMember -Function *
