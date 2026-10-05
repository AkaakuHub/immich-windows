#requires -Version 7.0
# No database, elevation, service changes, registry writes, or Pester dependency.
[CmdletBinding()]
param([string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$directory = Join-Path $RepositoryRoot 'runtime/metadata-date-repair'
Import-Module (Join-Path $RepositoryRoot 'runtime/Common.psm1') -Force
Import-Module (Join-Path $directory 'MetadataDateRepair.Launcher.psm1') -Force
# Shared reference state survives invocation from the launcher's separate script scope.
$repairTestState = @{ Checks = 0 }
function Assert-Repair([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAILED: $Message" }
    $repairTestState.Checks++
}
function Assert-RepairThrows([scriptblock]$Action, [string]$Message) {
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Assert-Repair $threw $Message
}

# The same quoting helper as the installer must round-trip non-ASCII and shell metacharacters.
$arguments = @('plain','C:\日本語 & family\Immich','C:\with spaces\','a"b','two\\"quotes',"apostrophe's",'$(not-a-command)')
$command = ($arguments | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' '
$parsed = @(ConvertFrom-RepairWindowsCommandLine $command)
Assert-Repair ($parsed.Count -eq $arguments.Count) 'argv count'
for ($i = 0; $i -lt $arguments.Count; $i++) { Assert-Repair ($parsed[$i] -ceq $arguments[$i]) "argv round trip $i" }
Assert-Repair (@(ConvertFrom-RepairWindowsCommandLine '""').Count -eq 1) 'empty quoted argv parsed'
Assert-RepairThrows { ConvertFrom-RepairWindowsCommandLine '"unterminated' } 'unterminated quotes rejected'
Assert-Repair (@(ConvertFrom-RepairWindowsCommandLine '  one   two  ').Count -eq 2) 'whitespace handling'
Assert-Repair (@(Merge-RepairInstallCandidates -Candidates @()).Count -eq 0) 'no records means no candidates'

$previous = [Environment]::GetEnvironmentVariables('Process')
try {
    foreach ($name in @('DB_HOSTNAME','DB_URL','PGHOST','PGPASSWORD','PGOPTIONS','TZ')) { [Environment]::SetEnvironmentVariable($name,'inherited-wrong-target','Process') }
    [Environment]::SetEnvironmentVariable('DB_REPAIR_EMPTY_TEST','','Process')
    [Environment]::SetEnvironmentVariable('REPAIR_KEEP_TEST','keep','Process')
    Clear-RepairConnectionEnvironment
    foreach ($name in @('DB_HOSTNAME','DB_URL','PGHOST','PGPASSWORD','PGOPTIONS','TZ')) { Assert-Repair ($null -eq [Environment]::GetEnvironmentVariable($name,'Process')) "$name cleared" }
    foreach ($name in @('DB_HOSTNAME','DB_URL','PGHOST','PGPASSWORD','PGOPTIONS','TZ','DB_REPAIR_EMPTY_TEST')) { Assert-Repair (-not [Environment]::GetEnvironmentVariables('Process').Contains($name)) "$name removed, not empty" }
    Assert-Repair ([Environment]::GetEnvironmentVariable('REPAIR_KEEP_TEST','Process') -ceq 'keep') 'unrelated environment preserved'
} finally {
    foreach ($name in @([Environment]::GetEnvironmentVariables('Process').Keys)) {
        if (-not $previous.Contains($name)) { Remove-Item -LiteralPath ("Env:" + $name) -ErrorAction Stop }
    }
    foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name,$previous[$name],'Process') }
}

# Parse every shipped PowerShell file even when testing from non-Windows PowerShell.
foreach ($file in @('Start-MetadataDateRepair.ps1','MetadataDateRepair.Launcher.psm1')) {
    $tokens = $null; $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile((Join-Path $directory $file),[ref]$tokens,[ref]$parseErrors)
    Assert-Repair ($parseErrors.Count -eq 0) "$file syntax"
}

if ($IsWindows) {
    $root = Join-Path $env:LOCALAPPDATA 'Programs\写真 & Family Immich'
    $data = Join-Path $env:LOCALAPPDATA '写真 & Family Data'
    $trayArgs = (@('--install-root',$root,'--data-root',$data,'--scope','CurrentUser','--powershell-path','C:\Program Files\PowerShell\7\pwsh.exe') | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' '
    $tray = [pscustomobject]@{TargetPath=(Join-Path $root 'current\runtime\tray\ImmichTray.exe');Arguments=$trayArgs}
    $candidate = ConvertFrom-RepairTrayRegistration $tray
    Assert-Repair ($candidate.Scope -ceq 'CurrentUser') 'tray scope'
    Assert-Repair (Test-RepairSamePath $candidate.InstallRoot $root) 'custom install root'
    Assert-Repair (Test-RepairSamePath $candidate.DataRoot $data) 'custom data root'
    $run = '"C:\Program Files\PowerShell\7\pwsh.exe" -NoProfile -WindowStyle Hidden -File "{0}\current\runtime\launchers\Start-Immich.ps1" -EnvFile "{1}\immich.env" -InstallRoot "{0}" -DataRoot "{1}"' -f $root,$data
    $runCandidate = ConvertFrom-RepairRunRegistration $run
    Assert-Repair (Test-RepairSamePath $runCandidate.DataRoot $data) 'HKCU custom data preserved'
    Assert-Repair (@(Merge-RepairInstallCandidates @($candidate,$runCandidate)).Count -eq 1) 'tray and Run deduplicated'
    Assert-RepairThrows { ConvertFrom-RepairRunRegistration ($run + ' -Unexpected value') } 'unexpected Run flags rejected'
    $badTray = [pscustomobject]@{TargetPath='C:\unrelated\ImmichTray.exe';Arguments=$trayArgs}
    Assert-RepairThrows { ConvertFrom-RepairTrayRegistration $badTray } 'unrelated tray target rejected'
    $badTray = [pscustomobject]@{TargetPath=$tray.TargetPath;Arguments=($trayArgs + ' --data-root "C:\wrong"')}
    Assert-RepairThrows { ConvertFrom-RepairTrayRegistration $badTray } 'duplicate arguments rejected'
    $machine = ConvertFrom-RepairServiceRegistration '"D:\写真 Archive\services\ImmichServer.exe"'
    Assert-Repair ($machine.Scope -ceq 'AllUsers' -and $machine.DataRoot -ceq 'D:\写真 Archive' -and $machine.Service) 'service exact data root'
    Assert-RepairThrows { ConvertFrom-RepairServiceRegistration '"D:\data\services\other.exe"' } 'wrong service binary rejected'
    Assert-RepairThrows { ConvertFrom-RepairServiceRegistration '"D:\data\services\ImmichServer.exe" ignored' } 'service trailing arguments rejected'
    $conflict = [pscustomobject]@{Scope='CurrentUser';InstallRoot=(Join-Path $env:LOCALAPPDATA 'different');DataRoot=$data;Service=$false}
    Assert-RepairThrows { Merge-RepairInstallCandidates @($candidate,$conflict) } 'conflicting registration rejected'
    $other = [pscustomobject]@{Scope='AllUsers';InstallRoot='C:\Program Files\Immich';DataRoot='D:\other data';Service=$true}
    Assert-Repair (@(Merge-RepairInstallCandidates @($candidate,$other)).Count -eq 2) 'multiple installations retained for explicit choice'

    $temporary = Join-Path ([IO.Path]::GetTempPath()) ('immich-repair-launcher-test-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path (Join-Path $temporary 'services') -Force | Out-Null
        $expectedRoot = 'D:\Installed Immich'
        $xml = '<service><id>ImmichServer</id><workingdirectory>D:\Installed Immich\current</workingdirectory><arguments>-NoProfile -File &quot;D:\Installed Immich\current\runtime\launchers\Load-ImmichEnv.ps1&quot; -EnvFile &quot;{0}\immich.env&quot; -ServiceRole Server</arguments></service>' -f [Security.SecurityElement]::Escape($temporary)
        [IO.File]::WriteAllText((Join-Path $temporary 'services\ImmichServer.xml'),$xml)
        Assert-Repair (Test-RepairSamePath (Resolve-RepairServiceInstallRoot $temporary) $expectedRoot) 'service XML root and env binding'
        [IO.File]::WriteAllText((Join-Path $temporary 'services\ImmichServer.xml'),($xml.Replace('immich.env','wrong.env')))
        Assert-RepairThrows { Resolve-RepairServiceInstallRoot $temporary } 'service XML wrong env rejected'
        [IO.File]::WriteAllText((Join-Path $temporary 'services\ImmichServer.xml'),'<!DOCTYPE service [<!ENTITY leak SYSTEM "file:///C:/private">]><service>&leak;</service>')
        Assert-RepairThrows { Resolve-RepairServiceInstallRoot $temporary } 'external XML entities rejected'
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force } }
} else { Write-Host 'Windows filesystem/registration fixtures skipped on this host.' }
Assert-Repair ((Resolve-RepairStartupTimezone -Scope AllUsers -UserTimezone 'user-zone' -MachineTimezone 'machine-zone') -ceq 'machine-zone') 'AllUsers ignores user TZ'
Assert-Repair ((Resolve-RepairStartupTimezone -Scope CurrentUser -UserTimezone 'user-zone' -MachineTimezone 'machine-zone') -ceq 'user-zone') 'CurrentUser inherits configured user TZ'
Assert-Repair ((Resolve-RepairStartupTimezone -Scope CurrentUser -UserTimezone $null -MachineTimezone 'machine-zone') -ceq 'machine-zone') 'CurrentUser machine TZ when user unset'
Assert-Repair ([string]::IsNullOrEmpty((Resolve-RepairStartupTimezone -Scope AllUsers -UserTimezone 'wrong-user' -MachineTimezone $null))) 'no configured TZ leaves Windows system timezone'

if ($IsWindows) {
    # Execute the actual launcher with bounded discovery/elevation mocks. Its native
    # Node invocation and loader/environment handling are real, using only fixtures.
    $fixture = Join-Path ([IO.Path]::GetTempPath()) ('immich-repair-flow-test-' + [guid]::NewGuid().ToString('N'))
    $oldDb = $env:DB_HOSTNAME; $oldPg = $env:PGPASSWORD; $oldTz = $env:TZ
    try {
        foreach ($relative in @('runtime/node','runtime/launchers','runtime/metadata-date-repair')) { New-Item -ItemType Directory -Path (Join-Path $fixture $relative) -Force | Out-Null }
        $realNode = (Get-Command node.exe -ErrorAction Stop).Source
        Copy-Item -LiteralPath $realNode -Destination (Join-Path $fixture 'runtime/node/node.exe')
        [IO.File]::WriteAllText((Join-Path $fixture 'runtime/launchers/Load-ImmichEnv.ps1'), @'
param([string]$EnvFile)
if ($env:DB_HOSTNAME -or $env:PGPASSWORD) { throw 'Inherited connection leaked into loader' }
$env:DB_HOSTNAME = 'fixture-db'
$env:TZ = 'Etc/UTC'
'@)
        [IO.File]::WriteAllText((Join-Path $fixture 'runtime/metadata-date-repair/guided.cjs'), @'
const assert = require('node:assert/strict');
assert.equal(process.env.DB_HOSTNAME, 'fixture-db');
assert.equal(process.env.PGPASSWORD, undefined);
assert.equal(process.env.TZ, 'Etc/UTC');
assert.deepEqual(process.argv.slice(2).filter((_, i) => i % 2 === 0), ['--release-root','--output-root','--language']);
console.log('FIXTURE_GUIDED_CALLED');
process.exit(23);
'@)
        $repairTestState.Candidates = @([pscustomobject]@{Scope='CurrentUser';InstallRoot=$fixture;DataRoot=$fixture;Service=$false})
        $repairTestState.Elevated = $false; $repairTestState.UacCalls = 0; $repairTestState.Denied = $false; $repairTestState.Answer = '2'
        $repairTestState.ResolveCalls = 0; $repairTestState.AllUsersOnly = $false
        function Import-Module { param([string]$Name,[switch]$Force) } # Modules are already loaded above.
        function Get-RepairInstallCandidates { param([switch]$AllUsersOnly); $repairTestState.AllUsersOnly = [bool]$AllUsersOnly; return $repairTestState.Candidates }
        function Test-ImmichElevated { return $repairTestState.Elevated }
        function Resolve-RepairInstall {
            param($Candidate)
            $repairTestState.ResolveCalls++
            $repairTestState.ResolvedScope = $Candidate.Scope
            return [pscustomobject]@{Scope=$Candidate.Scope;InstallRoot=$fixture;DataRoot=$fixture;ReleaseRoot=$fixture;EnvFile=(Join-Path $fixture 'immich.env');OutputRoot=(Join-Path $fixture 'state/metadata-date-repair')}
        }
        function Read-Host { param([string]$Prompt); return $repairTestState.Answer }
        function Start-Process {
            param($FilePath,$ArgumentList,$Verb,[switch]$Wait,[switch]$PassThru,$ErrorAction)
            $repairTestState.UacCalls++
            Assert-Repair ($Verb -ceq 'RunAs' -and $Wait -and $PassThru) 'UAC waits and captures process'
            $repairTestState.UacArguments = @(ConvertFrom-RepairWindowsCommandLine $ArgumentList)
            if ($repairTestState.Denied) { throw 'raw-secret-must-not-appear' }
            return [pscustomobject]@{ExitCode=37}
        }
        $entry = Join-Path $directory 'Start-MetadataDateRepair.ps1'
        $env:DB_HOSTNAME='wrong-inherited'; $env:PGPASSWORD='wrong-secret'; $env:TZ='wrong-zone'
        $output = (& $entry -Language en 2>&1 6>&1 | Out-String)
        Assert-Repair ($LASTEXITCODE -eq 23 -and $output.Contains('FIXTURE_GUIDED_CALLED')) ("real Node exit propagated; exit=$LASTEXITCODE; fixture output: $output")
        Assert-Repair ($repairTestState.UacCalls -eq 0) 'CurrentUser never requests elevation'
        Assert-Repair ($env:DB_HOSTNAME -ceq 'wrong-inherited' -and $env:PGPASSWORD -ceq 'wrong-secret' -and $env:TZ -ceq 'wrong-zone') 'caller environment restored'
        $repairTestState.Candidates = @([pscustomobject]@{Scope='AllUsers';InstallRoot=$fixture;DataRoot=$fixture;Service=$true})
        $output = (& $entry -Language en 2>&1 6>&1 | Out-String)
        Assert-Repair ($LASTEXITCODE -eq 37 -and $repairTestState.UacCalls -eq 1) ("elevated true exit propagated; exit=$LASTEXITCODE; fixture output: $output")
        $selectorIndex = [Array]::IndexOf($repairTestState.UacArguments, '-ElevatedSelection')
        $pinned = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($repairTestState.UacArguments[$selectorIndex + 1])) | ConvertFrom-Json
        Assert-Repair ($pinned.Scope -ceq 'AllUsers' -and $pinned.DataRoot -ceq $fixture -and $pinned.InstallRoot -ceq $fixture) 'UAC exact target pinned'
        $repairTestState.Denied = $true
        $output = (& $entry -Language en 2>&1 6>&1 | Out-String)
        Assert-Repair ($LASTEXITCODE -eq 1 -and $output.Contains('cancelled') -and -not $output.Contains('raw-secret')) ("UAC cancellation visible and sanitized; exit=$LASTEXITCODE; fixture output: $output")
        $repairTestState.Denied = $false; $repairTestState.Elevated = $true
        $bad = @{Scope='CurrentUser';InstallRoot=$fixture;DataRoot=$fixture} | ConvertTo-Json -Compress
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($bad))
        $beforeResolve = $repairTestState.ResolveCalls
        $output = (& $entry -Language en -ElevatedSelection $encoded 2>&1 6>&1 | Out-String)
        Assert-Repair ($LASTEXITCODE -eq 1 -and $repairTestState.ResolveCalls -eq $beforeResolve -and $repairTestState.AllUsersOnly) ("elevated CurrentUser selector rejected; exit=$LASTEXITCODE; fixture output: $output")
        $bad = @{Scope='AllUsers';InstallRoot=(Join-Path $fixture 'wrong-root');DataRoot=$fixture} | ConvertTo-Json -Compress
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($bad))
        $output = (& $entry -Language en -ElevatedSelection $encoded 2>&1 6>&1 | Out-String)
        Assert-Repair ($LASTEXITCODE -eq 1 -and $repairTestState.ResolveCalls -eq $beforeResolve) ("changed elevated root rejected; exit=$LASTEXITCODE; fixture output: $output")
        $repairTestState.Candidates += [pscustomobject]@{Scope='CurrentUser';InstallRoot=$fixture;DataRoot=(Join-Path $fixture 'other');Service=$false}
        $repairTestState.Answer = '2'; $repairTestState.Elevated = $false
        $output = (& $entry -Language en 2>&1 6>&1 | Out-String)
        Assert-Repair ($LASTEXITCODE -eq 23 -and $repairTestState.ResolvedScope -ceq 'CurrentUser') ("multiple install numeric selection honored; exit=$LASTEXITCODE; fixture output: $output")
        $repairTestState.Answer = ''
        $beforeResolve = $repairTestState.ResolveCalls
        $output = (& $entry -Language en 2>&1 6>&1 | Out-String)
        Assert-Repair ($LASTEXITCODE -eq 0 -and $repairTestState.ResolveCalls -eq $beforeResolve) ("cancel never loads env or starts Node; exit=$LASTEXITCODE; fixture output: $output")
    } finally {
        foreach ($name in @('Import-Module','Get-RepairInstallCandidates','Test-ImmichElevated','Resolve-RepairInstall','Read-Host','Start-Process')) { Remove-Item -LiteralPath ("Function:" + $name) -ErrorAction SilentlyContinue }
        $env:DB_HOSTNAME=$oldDb; $env:PGPASSWORD=$oldPg; $env:TZ=$oldTz
        if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
    }
}
Write-Host "PASS: $($repairTestState.Checks) launcher assertions"
