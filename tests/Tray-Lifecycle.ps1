#requires -Version 7.0
# Execute the real common lifecycle against inert desktop/process adapters.
# Native Explorer/UAC integration still requires Windows desktop qualification.
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$base=Join-Path ([IO.Path]::GetTempPath()) ('immich-tray-lifecycle-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $base | Out-Null
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
namespace Immich.TrayTests {
    public sealed class Desktop : IDisposable { public void Dispose() {} }
    public static class DesktopShell {
        public static bool Available = true, FailLaunch;
        public static List<string> Events = new List<string>();
        public static string File, Arguments, Directory;
        public static Desktop GetDesktopProcess() { return Available ? new Desktop() : null; }
        public static string ProcessUser(Desktop value) { throw new Exception("Unexpected real-user access in fixture."); }
        public static void Execute(string file, string arguments, string directory) {
            Events.Add("desktop-start"); File=file; Arguments=arguments; Directory=directory;
            if (FailLaunch) { throw new Exception("Injected shell failure"); }
        }
    }
}
'@
function Check([bool]$condition,[string]$message) { if (-not $condition) { throw $message } }
try {
    # Compile the actual interop and assert SDK values without opening a desktop.
    Add-Type -Path (Join-Path $repo 'runtime/tray/DesktopShell.cs')
    $flags=[Reflection.BindingFlags]'Static,NonPublic'
    Check ([Immich.Windows.DesktopShell].GetField('SvgioBackground',$flags).GetRawConstantValue() -eq 0) 'SVGIO_BACKGROUND must be zero, not SVGIO_FLAG_VIEWORDER.'
    Check ([Immich.Windows.DesktopShell].GetField('SwcDesktop',$flags).GetRawConstantValue() -eq 8) 'SWC_DESKTOP changed.'
    Check ([Immich.Windows.DesktopShell].GetField('SwfoNeedDispatch',$flags).GetRawConstantValue() -eq 1) 'SWFO_NEEDDISPATCH changed.'
    $source=Get-Content -Raw (Join-Path $repo 'runtime/Common.psm1')
    # Redirect only the OS boundary; lifecycle/quoting function bodies are unchanged.
    $source=$source.Replace('Immich.Windows.DesktopShell','Immich.TrayTests.DesktopShell')
    $source+=@'
function Initialize-ImmichDesktopShell {}
function Test-ImmichElevated { return $script:Elevated }
function Test-Path { return $true }
function Get-CurrentReleaseTarget { param($InstallRoot) return (Join-Path $InstallRoot 'releases/v3.2.2.8') }
function New-TrayTestProcess([string]$Name,[int]$ExitCode=0) {
    $process=[pscustomobject]@{Name=$Name;ExitCode=$ExitCode;Id=321;Events=[Immich.TrayTests.DesktopShell]::Events;Timeout=$script:Timeout}
    $process|Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.Events.Add('dispose-'+$this.Name) }
    $process|Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($milliseconds); if($milliseconds -ne 10000){throw 'Unbounded exit wait'}; $this.Events.Add('wait-old'); return -not $this.Timeout }
    return $process
}
function Get-ImmichTrayProcesses {
    param($InstallRoot,$ReleasePath)
    if($ReleasePath -ne (Join-Path $InstallRoot 'releases/v3.2.2.8')){throw 'Wrong previous release'}
    [Immich.TrayTests.DesktopShell]::Events.Add('capture-old')
    New-TrayTestProcess old
}
function Start-Process {
    param($FilePath,$ArgumentList,$WorkingDirectory,[switch]$Wait,[switch]$PassThru)
    if($Wait) {
        if(-not $PassThru -or $ArgumentList -notmatch '"--exit-existing"'){throw 'Missing v8-compatible stop/wait contract'}
        [Immich.TrayTests.DesktopShell]::Events.Add('signal-v8')
        return New-TrayTestProcess control $script:ControlExit
    }
    [Immich.TrayTests.DesktopShell]::Events.Add('direct-start')
}
function Set-TrayTestMode([bool]$Elevated,[bool]$Timeout=$false,[int]$ControlExit=0) {
    $script:Elevated=$Elevated; $script:Timeout=$Timeout; $script:ControlExit=$ControlExit
}
Export-ModuleMember -Function *
'@
    $modulePath=Join-Path $base 'TrayFixture.psm1'
    Set-Content -LiteralPath $modulePath -Value $source
    Import-Module $modulePath -Force
    $root=Join-Path $base "Immich 日本語's `$dollar; space"
    $data=Join-Path $base "Data 写真's private"
    $old=Join-Path $root 'releases/v3.2.2.8'
    $events=[Immich.TrayTests.DesktopShell]::Events
    Set-TrayTestMode $false
    Start-ImmichTray -InstallRoot $root -DataRoot $data -Scope CurrentUser
    Check (($events -join ',') -eq 'direct-start') 'Unelevated start must not stop or use desktop broker.'
    $events.Clear()
    Set-TrayTestMode $true
    Start-ImmichTray -InstallRoot $root -DataRoot $data -Scope AllUsers
    Check (($events -join ',') -eq 'desktop-start') 'Elevated start must use only the existing desktop broker.'
    $entry=Get-ImmichTrayEntry -InstallRoot $root -DataRoot $data -Scope AllUsers
    Check ([Immich.TrayTests.DesktopShell]::File -eq $entry.TargetPath) 'Desktop launch did not use current tray.'
    Check ([Immich.TrayTests.DesktopShell]::Arguments -ceq $entry.Arguments) 'Desktop launch altered quoted paths.'
    Check ([Immich.TrayTests.DesktopShell]::Directory -ceq $root) 'Desktop launch lost installation working directory.'
    [Immich.TrayTests.DesktopShell]::Available=$false
    foreach ($elevated in @($true,$false)) {
        $events.Clear(); Set-TrayTestMode $elevated
        Start-ImmichTray -InstallRoot $root -DataRoot $data -Scope AllUsers
        Check ($events.Count -eq 0) 'A headless session must not launch UI or fall back to elevated Start-Process.'
    }
    foreach ($mode in @('success','timeout','control-failure')) {
        $events.Clear(); Set-TrayTestMode $true ($mode -eq 'timeout') $(if($mode -eq 'control-failure'){7}else{0})
        $failed=$false
        try { Stop-ImmichTray -InstallRoot $root -ReleasePath $old } catch { $failed=$true }
        Check ($failed -eq ($mode -ne 'success')) "Wrong stop failure behavior: $mode"
        $expected=if($mode -eq 'control-failure'){'capture-old,signal-v8,dispose-control,dispose-old'}else{'capture-old,signal-v8,dispose-control,wait-old,dispose-old'}
        Check (($events -join ',') -eq $expected) "Wrong handle/signalling/exit order: $mode ($($events -join ','))"
    }
    $events.Clear(); [Immich.TrayTests.DesktopShell]::Available=$true; [Immich.TrayTests.DesktopShell]::FailLaunch=$true
    Set-TrayTestMode $true
    $failed=$false
    try { Start-ImmichTray -InstallRoot $root -DataRoot $data -Scope AllUsers } catch { $failed=$true }
    Check ($failed -and ($events -join ',') -eq 'desktop-start') 'COM failure must surface without an elevated fallback.'
    Write-Host 'PASS tray lifecycle: v8 signal, exact old release, actual exit wait, handle disposal, desktop launch, no duplicate stop, no-shell and failure behavior.'
} finally {
    Remove-Module TrayFixture -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $base -Recurse -Force
}
