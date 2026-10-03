#requires -Version 7.0
# Release orchestration tests. Network/install/tray functions and the Read-Host acknowledgement
# are fixtures. Never elevates, starts a real tray, or waits for a real Enter key in CI.
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$base=Join-Path ([IO.Path]::GetTempPath()) ('immich-release-ui-tests-'+[guid]::NewGuid().ToString('N'))
$source=Get-Content -Raw (Join-Path $repo 'packaging/Update-FromRelease.ps1')
$common=Get-Content -Raw (Join-Path $repo 'runtime/Common.psm1')
$common+=@'
# Match the parent pipe decoder explicitly; Windows console/OEM defaults differ.
if ($env:IMMICH_TEST_REAL_INPUT -eq '1') {[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)}
function Assert-Administrator {}
function Resolve-ImmichInstallPaths {param($Scope,$InstallRoot,$DataRoot) return @{InstallRoot=$InstallRoot;DataRoot=$DataRoot}}
function Read-Host {
    param($Prompt)
    # Windows ConsoleHost may write Read-Host's prompt directly to its console,
    # bypassing redirected stdout. Record the actual localized argument separately.
    [IO.File]::WriteAllText($env:IMMICH_TEST_PROMPT,[string]$Prompt,[Text.UTF8Encoding]::new($false))
    Add-Content $env:IMMICH_TEST_EVENTS enter
    if ($env:IMMICH_TEST_REAL_INPUT -eq '1') {return Microsoft.PowerShell.Utility\Read-Host $Prompt}
    Write-Host $Prompt; return ''
}
function Write-ImmichTrayConnectionHint {param($InstallRoot,$DataRoot)}
function Remove-ImmichLegacyStartMenu {param($Scope)}
function Set-ImmichTrayStartup {param($InstallRoot,$DataRoot,$Scope) if ($env:IMMICH_TEST_MODE -eq 'refresh-fail') {throw 'DB_PASSWORD=fixture-secret-must-not-leak'}}
function Start-ImmichTray {param($InstallRoot,$DataRoot,$Scope) Add-Content $env:IMMICH_TEST_EVENTS tray-replaced}
function Invoke-RestMethod {
    param($Uri,$Headers,$TimeoutSec)
    Add-Content $env:IMMICH_TEST_EVENTS check
    if ($env:IMMICH_TEST_MODE -eq 'check-fail') {throw [System.Net.Http.HttpRequestException]::new('DB_PASSWORD=fixture-secret-must-not-leak')}
    $tag=switch($env:IMMICH_TEST_MODE) {'latest' {'v3.2.2.5'} 'latest-incomplete' {'v3.2.2.5'} 'refresh-fail' {'v3.2.2.5'} 'invalid' {'invalid-secret-must-not-leak'} 'downgrade' {'v3.2.2.4'} 'revision-zero' {'v3.2.4.0'} 'revision-zero-requested' {'v3.2.4.0'} 'invalid-zero-padding' {'v3.2.4.00'} 'invalid-negative' {'v3.2.4.-1'} 'invalid-upstream-padding' {'v03.2.4.0'} default {'v3.2.2.6'}}
    $assets=if ($env:IMMICH_TEST_MODE -eq 'missing') {@()} else {@(@{name="immich-windows-$tag-win-x64.zip";browser_download_url='https://example.invalid/inert'})}
    return @{tag_name=$tag;assets=$assets}
}
function Invoke-WebRequest {param($Uri,$OutFile,$TimeoutSec) Add-Content $env:IMMICH_TEST_EVENTS download; throw 'DB_PASSWORD=fixture-secret-must-not-leak'}
Export-ModuleMember -Function *
'@
$update=@'
param($PackageRoot,$Scope,$InstallRoot,$DataRoot,$PostgresRoot,$PostgresService)
Add-Content $env:IMMICH_TEST_EVENTS apply
if ($env:IMMICH_TEST_MODE -eq 'update-throw') {throw 'Native probe failed: GLib worker initialization failed. DB_PASSWORD=fixture-secret-must-not-leak'}
if ($env:IMMICH_TEST_MODE -eq 'update-native-throw') {$global:LASTEXITCODE=7; throw 'GLib worker initialization failed'}
if ($env:IMMICH_TEST_MODE -eq 'update-exit') {exit 7}
if ($env:IMMICH_TEST_MODE -eq 'noop-installer') {return}
# Exercise the nested update's recursive acquisition on the same PowerShell thread.
$key=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes([IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($InstallRoot)).ToUpperInvariant())))
$mutex=[Threading.Mutex]::new($false,"Global\ImmichWindowsUpdate-$key")
try {if (-not $mutex.WaitOne(0)) {throw 'Nested update lock failed'}; $mutex.ReleaseMutex()} finally {$mutex.Dispose()}
Add-Content $env:IMMICH_TEST_EVENTS nested-lock
Copy-Item (Join-Path $PackageRoot manifest.json) (Join-Path $InstallRoot current/manifest.json) -Force
Start-ImmichTray -InstallRoot $InstallRoot -DataRoot $DataRoot -Scope $Scope
'@
# Hold a mutex on a different thread to exercise repeated clicks / another session.
Add-Type -TypeDefinition @'
using System;
using System.Threading;
public sealed class ImmichUpdateTestLock : IDisposable {
    readonly ManualResetEvent ready = new ManualResetEvent(false), stop = new ManualResetEvent(false);
    readonly Thread thread;
    public ImmichUpdateTestLock(string name) {
        thread = new Thread(delegate() {
            using (var mutex = new Mutex(false, name)) {
                mutex.WaitOne(); ready.Set(); stop.WaitOne(); mutex.ReleaseMutex();
            }
        });
        thread.Start(); ready.WaitOne();
    }
    public void Dispose() {stop.Set(); thread.Join(); ready.Dispose(); stop.Dispose();}
}
'@
try {
    foreach ($language in @('en','ja')) {
        foreach ($mode in @('latest','latest-incomplete','success','revision-zero','revision-zero-requested','invalid-zero-padding','invalid-negative','invalid-upstream-padding','invalid-requested','check-fail','invalid','downgrade','missing','download-fail','validate-fail','validate-exit','update-throw','update-native-throw','update-exit','noop-installer','busy')) {
            $case=Join-Path $base "$language-$mode"
            $root=Join-Path $case install
            $data=Join-Path $case data
            $package=Join-Path $case runner
            $candidateTag=if ($mode -like 'revision-zero*') { 'v3.2.4.0' } else { 'v3.2.2.6' }
            $candidate=Join-Path $data "staging/$candidateTag/immich-windows-$candidateTag-win-x64"
            foreach ($dir in @("$root/current","$package/installer","$package/runtime","$candidate/installer")) {New-Item -ItemType Directory -Path $dir -Force|Out-Null}
            $env:IMMICH_TEST_MODE=$mode
            $env:IMMICH_TEST_REAL_INPUT='0'
            $env:IMMICH_TEST_EVENTS=Join-Path $case events
            $env:IMMICH_TEST_PROMPT=Join-Path $case prompt.txt
            Set-Content "$package/installer/Update-FromRelease.ps1" $source
            Set-Content "$package/runtime/Common.psm1" $common
            Set-Content "$package/installer/Test-ReleasePackage.ps1" 'param($PackageRoot,$Version); Add-Content $env:IMMICH_TEST_EVENTS validate; if($env:IMMICH_TEST_MODE -eq "validate-fail"){throw "fixture-secret-must-not-leak"}; if($env:IMMICH_TEST_MODE -eq "validate-exit"){exit 9}'
            Set-Content "$candidate/installer/Update.ps1" $update
            Set-Content "$data/immich.env" 'DB_PASSWORD=fixture-secret-must-not-leak'
            Set-Content "$root/current/manifest.json" '{"schemaVersion":2,"immichVersion":"v3.2.2","windowsRevision":5,"packageVersion":"v3.2.2.5"}'
            if ($mode -like 'revision-zero*') {
                Set-Content "$root/current/manifest.json" '{"schemaVersion":2,"immichVersion":"v3.2.2","windowsRevision":8,"packageVersion":"v3.2.2.8"}'
                Set-Content "$candidate/manifest.json" '{"schemaVersion":2,"immichVersion":"v3.2.4","windowsRevision":0,"packageVersion":"v3.2.4.0"}'
            } else { Set-Content "$candidate/manifest.json" '{"schemaVersion":2,"immichVersion":"v3.2.2","windowsRevision":6,"packageVersion":"v3.2.2.6"}' }
            if ($mode -eq 'latest-incomplete') {
                New-Item -ItemType Directory -Path (Join-Path $data state) -Force|Out-Null
                Set-Content (Join-Path $data 'state/upgrade-recovery.json') '{"status":"failed"}'
            }
            if ($mode -ne 'download-fail') {Set-Content (Join-Path $data "staging/$candidateTag/.ready") ready}
            # Real common target resolver expects a current junction; use a minimal local override
            # because replacing a current link is outside this result-delivery contract.
            Add-Content "$package/runtime/Common.psm1" 'function Get-CurrentReleaseTarget {param($InstallRoot) Join-Path $InstallRoot current}; Export-ModuleMember -Function *'
            $held=$null
            try {
                if ($mode -eq 'busy') {
                    $key=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes([IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($root)).ToUpperInvariant())))
                    $held=[ImmichUpdateTestLock]::new("Global\ImmichWindowsUpdate-$key")
                }
                $global:LASTEXITCODE=0
                if ($mode -in @('latest','success','update-throw')) {
                    # Run the real Read-Host in a real child shell. Do not send Enter until
                    # it has reached the prompt and is proven to still be running.
                    $env:IMMICH_TEST_REAL_INPUT='1'
                    $info=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
                    $info.UseShellExecute=$false
                    $info.RedirectStandardInput=$true
                    $info.RedirectStandardOutput=$true
                    $info.RedirectStandardError=$true
                    $info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false)
                    $info.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
                    foreach ($arg in @('-NoLogo','-NoProfile','-File',"$package/installer/Update-FromRelease.ps1",'-InstallRoot',$root,'-DataRoot',$data,'-Scope','CurrentUser','-Interactive','-Language',$language)) {$info.ArgumentList.Add($arg)}
                    $process=[Diagnostics.Process]::Start($info)
                    try {
                        $stdout=$process.StandardOutput.ReadToEndAsync()
                        $stderr=$process.StandardError.ReadToEndAsync()
                        $deadline=[Diagnostics.Stopwatch]::StartNew()
                        do {
                            if ($process.HasExited) {throw "$mode shell closed before Enter: $($stderr.Result)"}
                            if ($deadline.Elapsed.TotalSeconds -gt 15) {throw "$mode shell did not reach the acknowledgement"}
                            Start-Sleep -Milliseconds 50
                        } while (-not (Test-Path $env:IMMICH_TEST_EVENTS) -or @(Get-Content $env:IMMICH_TEST_EVENTS) -notcontains 'enter')
                        if ($process.WaitForExit(200)) {throw "$mode shell did not wait for Enter"}
                        $process.StandardInput.WriteLine('')
                        $process.StandardInput.Flush()
                        if (-not $process.WaitForExit(10000)) {throw "$mode shell did not exit after Enter"}
                        $output=@($stdout.Result,$stderr.Result)
                        $exitCode=$process.ExitCode
                    } finally {if(-not $process.HasExited){$process.Kill()}; $process.Dispose()}
                } else {
                    $request=@{}
                    if ($mode -eq 'revision-zero-requested') { $request.Version='v3.2.4.0' }
                    if ($mode -eq 'invalid-requested') { $request.Version='v3.2.4.00' }
                    $output=@(& "$package/installer/Update-FromRelease.ps1" -InstallRoot $root -DataRoot $data -Scope CurrentUser -Interactive -Language $language @request 6>&1)
                    $exitCode=$LASTEXITCODE
                }
            } finally {if($held){$held.Dispose()}}
            $expected=switch($mode){latest {10} success {0} 'revision-zero' {0} 'revision-zero-requested' {0} default {20}}
            if ($exitCode -ne $expected) {throw "$language/$mode exit $exitCode; expected $expected"}
            $message=($output|ForEach-Object {$_.ToString()}) -join "`n"
            $events=@(Get-Content $env:IMMICH_TEST_EVENTS)
            $logs=@(Get-ChildItem "$data/logs" -Filter '*.log' -ErrorAction SilentlyContinue)
            $log=if($logs.Count){Get-Content -Raw $logs[0].FullName}else{''}
            if (($message+$log) -match 'fixture-secret|invalid-secret') {throw "$mode leaked raw failure/env content"}
            if ($expected -eq 20 -and $mode -ne 'busy') {
                if ($logs.Count -ne 1 -or -not $message.Contains($logs[0].FullName)) {throw "$mode result lacks one sanitized failure log"}
            } elseif ($logs.Count) {throw "$mode must not create unnecessary log files"}
            if (@($events|Where-Object {$_ -eq 'enter'}).Count -ne 1 -or $events[-1] -ne 'enter') {throw "$mode must wait once after all update/tray work"}
            $close=if($language -eq 'ja'){'Enterキーを押して'}else{'Press Enter to close'}
            $prompt=[IO.File]::ReadAllText($env:IMMICH_TEST_PROMPT,[Text.Encoding]::UTF8)
            if (-not $prompt.Contains($close)) {
                $units=($prompt.ToCharArray()|ForEach-Object {'U+{0:X4}' -f [int]$_}) -join ' '
                throw "$language/$mode missing localized acknowledgement; prompt='$prompt'; code units=$units; captured output='$message'"
            }
            if ($mode -eq 'latest') {
                $latest=if($language -eq 'ja'){'最新版です'}else{'You have the latest version'}
                if (-not $message.Contains($latest) -or $events -contains 'apply' -or $events -contains 'tray-replaced' -or $events -notcontains 'check') {
                    $units=($message.ToCharArray()|ForEach-Object {'U+{0:X4}' -f [int]$_}) -join ' '
                    throw "$language/$mode latest result is missing or performed extra work; captured output='$message'; code units=$units; events=$($events -join ',')"
                }
            } elseif ($mode -in @('success','revision-zero','revision-zero-requested')) {
                if ($events -notcontains 'nested-lock' -or $events -notcontains 'tray-replaced' -or (Test-Path "$data/staging/$candidateTag")) {throw 'Applied update did not survive tray restart / clean staging / recurse mutex'}
            } elseif ($message -match 'You have the latest version|最新版です|updated successfully|更新が完了しました') {throw "$mode must never claim latest or success"}
            if ($mode -eq 'invalid-requested' -and $events -contains 'check') {throw 'Invalid requested version reached the release API'}
            if ($mode -like 'invalid-*' -and $events -contains 'apply') {throw 'Malformed version was applied'}
            if ($mode -eq 'busy' -and $events -contains 'check') {throw 'Concurrent update must stop before querying/downloading'}
            if ($mode -eq 'latest-incomplete' -and $log -notmatch 'reason=recovery') {throw 'Incomplete current release was not identified as requiring recovery'}
            if ($mode -eq 'update-throw' -and $message -notmatch 'GLib worker initialization failed') {throw 'Meaningful native error text was lost'}
            if ($mode -eq 'update-native-throw' -and $log -notmatch 'nativeExit=7') {throw 'Native failure code preceding a throw was lost'}
            if ($mode -eq 'update-exit' -and $log -notmatch 'nativeExit=7') {throw 'Native update failure was lost'}
            if ($mode -eq 'validate-exit' -and $log -notmatch 'nativeExit=9') {throw 'Native validation failure was lost'}
            Write-Host "PASS release update feedback: $language/$mode"
        }
    }
} finally {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:IMMICH_TEST_MODE,Env:IMMICH_TEST_EVENTS,Env:IMMICH_TEST_PROMPT,Env:IMMICH_TEST_REAL_INPUT -ErrorAction SilentlyContinue
}
