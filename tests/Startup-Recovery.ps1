#requires -Version 7.0
# Exercise the production guard with real process/mutex boundaries, without Immich or a database.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$base=Join-Path ([IO.Path]::GetTempPath()) ('immich-startup-recovery-'+[guid]::NewGuid().ToString('N'))
$root=Join-Path $base install
$data=Join-Path $base data
$envFile=Join-Path $data 'immich.env'
$statePath=Join-Path $data 'state/upgrade-recovery.json'
$module=Join-Path $repo 'runtime/Common.psm1'
Import-Module $module -Force
function Check([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Set-State([string]$Status,[int]$Controller=$PID) {
    @{status=$Status;controllerProcessId=$Controller;controllerMutexName=$controllerName} | ConvertTo-Json | Set-Content -LiteralPath $statePath
}
function Expect-Blocked([scriptblock]$Action) {
    $message=$null
    try { & $Action } catch { $message=$_.Exception.Message }
    Check ($message -like 'Upgrade is incomplete*') "Startup was not safely blocked: $message"
}
function Invoke-OtherProcess([string]$Mode,[bool]$Allowed) {
    $info=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    $info.UseShellExecute=$false
    $info.RedirectStandardOutput=$true
    $info.RedirectStandardError=$true
    foreach ($arg in @('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $base 'probe.ps1'),$module,$envFile,$root,$Mode)) { $info.ArgumentList.Add($arg) }
    $process=[Diagnostics.Process]::Start($info)
    try {
        $stdout=$process.StandardOutput.ReadToEndAsync()
        $stderr=$process.StandardError.ReadToEndAsync()
        Check ($process.WaitForExit(15000)) 'Startup guard subprocess timed out.'
        $message=$stdout.GetAwaiter().GetResult()+$stderr.GetAwaiter().GetResult()
        Check (($process.ExitCode -eq 0) -eq $Allowed) "Unexpected $Mode startup result: $message"
        if (-not $Allowed) { Check ($message -like '*Upgrade is incomplete*') "Unexpected startup rejection: $message" }
    } finally { $process.Dispose() }
}
$mutex=$null
$startupMutex=$null
$controllerName=''
$previousScope=$env:IMMICH_WINDOWS_INSTALL_SCOPE
$previousPath=$env:PATH
$previousFfmpeg=$env:FFMPEG_PATH
$previousFfprobe=$env:FFPROBE_PATH
try {
    New-Item -ItemType Directory -Path (Split-Path $statePath),$root -Force | Out-Null
    'IMMICH_WINDOWS_INSTALL_SCOPE=CurrentUser' | Set-Content -LiteralPath $envFile
    @'
param($Module,$EnvFile,$InstallRoot,$Mode)
$ErrorActionPreference='Stop'
Import-Module $Module -Force
try {
    Assert-ImmichStartupAllowed -EnvFile $EnvFile -InstallRoot $InstallRoot -ServiceProcess:($Mode -eq 'service') -UpgradeInProgress:($Mode -eq 'controlled')
    exit 0
} catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
'@ | Set-Content -LiteralPath (Join-Path $base 'probe.ps1')
    Assert-ImmichStartupAllowed -EnvFile $envFile -InstallRoot $root
    foreach ($status in @('qualified','recovered','preparation-failed','backup-failed')) {
        Set-State $status
        Assert-ImmichStartupAllowed -EnvFile $envFile -InstallRoot $root
    }
    foreach ($status in @('preparing','stopping','installing','failed','recovering','candidate-installed','recovery-starting')) {
        Set-State $status
        Expect-Blocked { Assert-ImmichStartupAllowed -EnvFile $envFile -InstallRoot $root }
    }
    Write-Host 'PASS startup recovery: safe and interrupted states'

    $key=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes([IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($root)).ToUpperInvariant())))
    $mutex=[Threading.Mutex]::new($false,"Global\ImmichWindowsUpdate-$key")
    Check ($mutex.WaitOne(0)) 'Could not hold the test updater mutex.'
    try {
        # Owning the serialization lock alone must never authorize a crashed attempt.
        Set-State candidate-installed
        Invoke-OtherProcess service $false
        Expect-Blocked { Assert-ImmichStartupAllowed -EnvFile $envFile -InstallRoot $root -UpgradeInProgress }
        $controllerName="Global\ImmichWindowsStartup-$key-$([guid]::NewGuid().ToString('N'))"
        $startupMutex=[Threading.Mutex]::new($true,$controllerName)
        foreach ($status in @('candidate-installed','recovery-starting')) {
            Set-State $status
            Assert-ImmichStartupAllowed -EnvFile $envFile -InstallRoot $root -UpgradeInProgress
            Expect-Blocked { Assert-ImmichStartupAllowed -EnvFile $envFile -InstallRoot $root }
            Invoke-OtherProcess service $true
            Invoke-OtherProcess normal $false
            Invoke-OtherProcess controlled $false
            Set-State $status ($PID+1)
            Expect-Blocked { Assert-ImmichStartupAllowed -EnvFile $envFile -InstallRoot $root -UpgradeInProgress }
        }
        $startupMutex.ReleaseMutex();$startupMutex.Dispose();$startupMutex=$null
        # A new attempt's active startup gate must not authorize the old recorded state.
        $otherGate=[Threading.Mutex]::new($true,"Global\ImmichWindowsStartup-$key-$([guid]::NewGuid().ToString('N'))")
        try {
            Set-State candidate-installed
            Invoke-OtherProcess service $false
            Expect-Blocked { Assert-ImmichStartupAllowed -EnvFile $envFile -InstallRoot $root -UpgradeInProgress }
        } finally { $otherGate.ReleaseMutex();$otherGate.Dispose() }
    } finally { $mutex.ReleaseMutex() }
    Set-State candidate-installed
    Invoke-OtherProcess service $false
    Write-Host 'PASS startup recovery: recursive updater, separate service/operator processes and stale attempt isolation'

    # Run the actual Start and loader. Rejection must precede any launch or services/log writes.
    $launchers=Join-Path $root 'current/runtime/launchers'
    New-Item -ItemType Directory -Path $launchers -Force | Out-Null
    Copy-Item $module (Join-Path $root 'current/runtime/Common.psm1')
    foreach ($name in @('Start-Immich.ps1','Load-ImmichEnv.ps1')) { Copy-Item (Join-Path $repo "runtime/launchers/$name") $launchers }
    Set-State failed
    Expect-Blocked { & (Join-Path $launchers 'Start-Immich.ps1') -InstallRoot $root -DataRoot $data -EnvFile $envFile }
    Check (-not (Test-Path (Join-Path $data services)) -and -not (Test-Path (Join-Path $data logs))) 'Rejected startup mutated process/log state.'
    Write-Host 'PASS startup recovery: real launcher rejects before process state changes'

    # Test the actual installer precedence expression without running the installer.
    $tokens=$null;$parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'packaging/Install.ps1'),[ref]$tokens,[ref]$parseErrors)
    Check ($parseErrors.Count -eq 0) 'Installer did not parse.'
    $assignment=$ast.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$PostgresRoot' -and $n.Right.Extent.Text -like '*IMMICH_POSTGRES_BIN_DIR*'},$true)
    Check ($null -ne $assignment) 'Legacy PostgreSQL root fallback is missing.'
    $resolve=[scriptblock]::Create('param($PostgresRoot,$sourceEnv,$Explicit) $PSBoundParameters=@{}; if ($Explicit) {$PSBoundParameters.PostgresRoot=$PostgresRoot}; '+$assignment.Extent.Text+'; $PostgresRoot')
    $legacyBin=Join-Path $base 'legacy-postgres/bin'
    $saved=Join-Path $base saved-postgres
    $explicit=Join-Path $base explicit-postgres
    Check ((& $resolve $explicit @{POSTGRES_ROOT=$saved;IMMICH_POSTGRES_BIN_DIR=$legacyBin} $true) -eq $explicit) 'Explicit PostgreSQL root lost precedence.'
    Check ((& $resolve default @{POSTGRES_ROOT=$saved;IMMICH_POSTGRES_BIN_DIR=$legacyBin} $false) -eq $saved) 'Saved PostgreSQL root lost precedence.'
    Check ((& $resolve default @{IMMICH_POSTGRES_BIN_DIR=$legacyBin} $false) -eq (Split-Path -Parent $legacyBin)) 'Legacy PostgreSQL bin path was not preserved.'
    Check ((& $resolve default @{} $false) -eq 'default') 'Default PostgreSQL root changed.'
    Write-Host 'PASS legacy PostgreSQL root: explicit, current env, legacy env, default'
} finally {
    if ($startupMutex) { $startupMutex.ReleaseMutex();$startupMutex.Dispose() }
    if ($mutex) { $mutex.Dispose() }
    $env:IMMICH_WINDOWS_INSTALL_SCOPE=$previousScope
    $env:PATH=$previousPath
    $env:FFMPEG_PATH=$previousFfmpeg
    $env:FFPROBE_PATH=$previousFfprobe
    if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
}
