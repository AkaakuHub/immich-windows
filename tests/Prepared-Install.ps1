#requires -Version 7.0
# Run the real Update and Install scripts with disposable files and inert external
# processes. Count actual installer stage calls, not a modeled install stub.
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$base=Join-Path ([IO.Path]::GetTempPath()) ('prepared-install-'+[guid]::NewGuid().ToString('N'))
function Check([bool]$Value,[string]$Message) { if (-not $Value) { throw $Message } }
function Write-Fixture([string]$Path,[string]$Text) { [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)); [IO.File]::WriteAllText($Path,$Text) }
$executables=@()
try {
 foreach ($mode in @('same','same-move','move-smoke-failure','bootstrap-entry','env-mutates','env-stop-mutates','validation-exit','dependency-exit','changed','stop-mutates','resume','ml-failure','prepare-only','standalone-app-only','standalone-changed')) {
    $case=Join-Path $base $mode;$root=Join-Path $case install;$data=Join-Path $case data;$package=Join-Path $case package;$pg=Join-Path $case postgres
    $oldTag=if ($mode -eq 'bootstrap-entry') {'v3.2.2.8'} else {'v3.2.2.1'}
    $candidateTag=if ($mode -eq 'bootstrap-entry') {'v3.2.4.0'} else {'v3.2.2.2'}
    $old=Join-Path $root "releases/$oldTag";$candidate=Join-Path $root "releases/$candidateTag"
    $env:IMMICH_TEST_PREPARED_EVENTS=Join-Path $case events
    $env:IMMICH_TEST_PREPARED_MODE=$mode
    $manifest=[ordered]@{schemaVersion=2;target='windows-x64-native';immichVersion='v3.2.2';upstreamCommit=('a'*40);windowsRevision=2;packageVersion='v3.2.2.2';sourceCommit=('b'*40);builtAtUtc='fixture';mediaStack=@{productionQualified=$true};dependencies=@{node=@{version='24.15.0'};postgresql=@{version='18.3'};pgvector=@{version='1.0.0'};vectorchord=@{version='1.0.0'}}}
    if ($mode -eq 'bootstrap-entry') { $manifest.immichVersion='v3.2.4';$manifest.windowsRevision=0;$manifest.packageVersion=$candidateTag;$manifest.upstreamCommit='c'*40 }
    foreach ($path in @($old,$package)) {
        Write-Fixture (Join-Path $path manifest.json) ($manifest|ConvertTo-Json -Depth 10)
        foreach ($file in @('server/package.json','server/pnpm-lock.yaml','server/pnpm-workspace.yaml','server/dist/main.js','server/.immich/plugin-sdk/index.js','dependencies/postgres-extensions/vector/vector.dll','runtime/vc-runtime/runtime.dll','runtime/node/node.exe')) { Write-Fixture (Join-Path $path $file) 'same payload' }
    }
    if ($mode -in @('same-move','move-smoke-failure')) { Remove-Item -LiteralPath (Join-Path $package 'runtime/node') -Recurse }
    foreach ($rootPath in @($old,$package)) { foreach ($extension in @('vector','vchord')) { Write-Fixture (Join-Path $rootPath "dependencies/postgres-extensions/$extension/$extension.control") "default_version = '1.0.0'" } }
    $manifest.windowsRevision=if ($mode -eq 'bootstrap-entry') {8} else {1};$manifest.packageVersion=$oldTag;$manifest.immichVersion='v3.2.2';$manifest.upstreamCommit='a'*40
    Write-Fixture (Join-Path $old manifest.json) ($manifest|ConvertTo-Json -Depth 10)
    if ($mode -in @('changed','standalone-changed')) { Write-Fixture (Join-Path $package 'server/dist/main.js') 'changed payload' }
    foreach ($name in @('Install','Update')) { Write-Fixture (Join-Path $package "installer/$name.ps1") (Get-Content -Raw (Join-Path $repo "packaging/$name.ps1")) }
    $common=Get-Content -Raw (Join-Path $repo 'runtime/Common.psm1')
    $common=$common.Replace('function Test-ImmichDatabasePayloadEqual {','function Test-ImmichDatabasePayloadEqualCore {')
    $common+=@'
function Resolve-ImmichInstallPaths {param($Scope,$InstallRoot,$DataRoot) return @{InstallRoot=$InstallRoot;DataRoot=$DataRoot}}
function Test-WindowsAbsolutePath {param($Path) return $true}
function Get-Service {param($Name) return [pscustomobject]@{Status='Running'}}
function Install-ReleaseDirectory {
 param($PackageRoot,$InstallRoot)
 Add-Content $env:IMMICH_TEST_PREPARED_EVENTS copy
 $identity=Get-Content -Raw (Join-Path $PackageRoot manifest.json)|ConvertFrom-Json
 $release=Join-Path $InstallRoot "releases/$($identity.packageVersion)"
 New-Item -ItemType Directory $release -Force|Out-Null
 Copy-Item (Join-Path $PackageRoot '*') $release -Recurse -Force
 return $release
}
function Test-ImmichDatabasePayloadEqual {
 param($PreviousRelease,$CandidateRelease,$DependencyReusePlan)
 Add-Content $env:IMMICH_TEST_PREPARED_EVENTS compare
 if (@(Get-Content $env:IMMICH_TEST_PREPARED_EVENTS) -notcontains 'stop') { throw 'DB classification ran before shutdown.' }
 return Test-ImmichDatabasePayloadEqualCore $PreviousRelease $CandidateRelease -DependencyReusePlan $DependencyReusePlan
}
function Set-CurrentReleaseJunction {
 param($InstallRoot,$ReleasePath)
 Add-Content $env:IMMICH_TEST_PREPARED_EVENTS activate
 [IO.Directory]::Delete((Join-Path $InstallRoot current))
 New-Item -ItemType $(if ($IsWindows) {'Junction'} else {'SymbolicLink'}) (Join-Path $InstallRoot current) -Target $ReleasePath | Out-Null
}
function Write-ImmichTrayConnectionHint {param($InstallRoot,$DataRoot)}
function Set-ImmichUserStartup {param($InstallRoot,$DataRoot,$Enabled)}
function Remove-ImmichLegacyStartMenu {param($Scope)}
function Set-ImmichTrayStartup {param($InstallRoot,$DataRoot,$Scope)}
function Start-ImmichTray {param($InstallRoot,$DataRoot,$Scope)}
Export-ModuleMember -Function *
'@
    Write-Fixture (Join-Path $package 'runtime/Common.psm1') $common
    Write-Fixture (Join-Path $package 'installer/Remove-ObsoleteReleases.ps1') 'function Remove-ImmichObsoleteReleases {param($InstallRoot,$DataRoot,$CurrentReleasePath,$PreviousReleasePath,$EnvFile); Add-Content $env:IMMICH_TEST_PREPARED_EVENTS cleanup}'
    Write-Fixture (Join-Path $package 'installer/Test-ReleasePackage.ps1') 'param($PackageRoot); Add-Content $env:IMMICH_TEST_PREPARED_EVENTS validate; if ($env:IMMICH_TEST_PREPARED_MODE -eq "validation-exit") { exit 9 }'
    foreach ($stage in @(@('installer/Install-RuntimeDependencies.ps1','runtime'),@('runtime/launchers/Install-NodeDependencies.ps1','node'),@('installer/Install-MachineLearningDependencies.ps1','ml'))) {
        Write-Fixture (Join-Path $package $stage[0]) ('param($ReleaseRoot,$InstallRoot,$DependencyReusePlan); if ($env:IMMICH_TEST_PREPARED_MODE -in @(''same-move'',''move-smoke-failure'') -and '''+$stage[1]+''' -eq ''runtime'') { Add-ImmichDependencyReuse -Plan $DependencyReusePlan -PreviousRelease (Get-CurrentReleaseTarget $InstallRoot) -CandidateRelease $ReleaseRoot -RelativePath ''runtime/node'' -Label Node }; Add-Content $env:IMMICH_TEST_PREPARED_EVENTS '+$stage[1]+'; if ($env:IMMICH_TEST_PREPARED_MODE -eq "env-mutates" -and "'+$stage[1]+'" -eq "node") { Add-Content (Join-Path (Split-Path $InstallRoot) "data/immich.env") "DB_PASSWORD=edited-during-preparation" }; if ($env:IMMICH_TEST_PREPARED_MODE -eq "dependency-exit" -and "'+$stage[1]+'" -eq "runtime") { exit 7 }; if ($env:IMMICH_TEST_PREPARED_MODE -eq "ml-failure" -and "'+$stage[1]+'" -eq "ml") { throw "Dependency preparation failed" }; $global:LASTEXITCODE=0')
    }
    Write-Fixture (Join-Path $package 'runtime/launchers/Stop-Immich.ps1') 'param($EnvFile,$DataRoot,$InstallRoot); Add-Content $env:IMMICH_TEST_PREPARED_EVENTS stop; if ($env:IMMICH_TEST_PREPARED_MODE -eq "env-stop-mutates") { Add-Content $EnvFile "DB_PASSWORD=edited-during-stop" }; if ($env:IMMICH_TEST_PREPARED_MODE -eq "stop-mutates") { Set-Content (Join-Path (Get-CurrentReleaseTarget $InstallRoot) "server/dist/main.js") changed }; $global:LASTEXITCODE=0'
    Write-Fixture (Join-Path $package 'runtime/launchers/Start-Immich.ps1') 'param($EnvFile,$DataRoot,$InstallRoot,[switch]$UpgradeInProgress); Add-Content $env:IMMICH_TEST_PREPARED_EVENTS start; $global:LASTEXITCODE=0'
    Write-Fixture (Join-Path $package 'tests/Smoke-Windows.ps1') 'param($InstallRoot,$DataRoot,$PostgresRoot); Add-Content $env:IMMICH_TEST_PREPARED_EVENTS smoke; if ($env:IMMICH_TEST_PREPARED_MODE -eq ''move-smoke-failure'') { throw ''Injected smoke failure'' }; $global:LASTEXITCODE=0'
    Write-Fixture (Join-Path $package 'migration/New-DatabaseBackup.ps1') 'param($EnvFile,$PostgresRoot); Add-Content $env:IMMICH_TEST_PREPARED_EVENTS backup; $path=Join-Path (Split-Path $EnvFile) backup.dump; Set-Content $path backup; $global:LASTEXITCODE=0; return $path'
    foreach ($name in @('postgres','psql','pg_dump','pg_restore')) {
        $exe=Join-Path $pg "bin/$name.exe";Write-Fixture $exe fixture;$executables+=$exe
        Set-Item "function:global:$exe" { $global:LASTEXITCODE=0; if ($args[-1] -eq '--version') { 'postgres (PostgreSQL) 18.3' } elseif ($args[-1] -like '*pg_database*') { '1' } elseif ($args[-1] -eq 'SHOW shared_preload_libraries') { 'vchord' } else { '1.0.0' } }
    }
    $media=Join-Path $case media;[void][IO.Directory]::CreateDirectory($media)
    Write-Fixture (Join-Path $data immich.env) "IMMICH_WINDOWS_INSTALL_SCOPE=CurrentUser`nIMMICH_MEDIA_LOCATION=$media`nDB_PASSWORD=fixture`nDB_DATABASE_NAME=existing_database`nIMMICH_WINDOWS_REDIS_MODE=External`nCUSTOM_SETTING=preserve=this value`n"
    New-Item -ItemType $(if ($IsWindows) {'Junction'} else {'SymbolicLink'}) (Join-Path $root current) -Target $old | Out-Null
    if ($mode -in @('resume','standalone-app-only','standalone-changed')) { [void][IO.Directory]::CreateDirectory($candidate);Copy-Item (Join-Path $package '*') $candidate -Recurse -Force }
    $failed=$false
    try {
        if ($mode -eq 'bootstrap-entry') {
            & (Join-Path $package 'installer/Install.ps1') -PackageRoot $package -Scope CurrentUser -InstallRoot $root -DataRoot $data -PostgresRoot $pg
        } elseif ($mode -eq 'prepare-only') {
            & (Join-Path $package 'installer/Install.ps1') -PackageRoot $package -Scope CurrentUser -InstallRoot $root -DataRoot $data -PostgresRoot $pg -ReuseServices -PrepareOnly
        } elseif ($mode -like 'standalone-*') {
            & (Join-Path $package 'installer/Install.ps1') -PackageRoot $package -Scope CurrentUser -InstallRoot $root -DataRoot $data -PostgresRoot $pg -ReuseServices -ResumeExistingRelease -ApplicationOnly -DoNotStart
        } else {
            & (Join-Path $package 'installer/Update.ps1') -PackageRoot $package -Scope CurrentUser -InstallRoot $root -DataRoot $data -PostgresRoot $pg
        }
    } catch { $failed=$true; Write-Host $_.Exception.Message }
    $events=@(Get-Content $env:IMMICH_TEST_PREPARED_EVENTS)
    if ($mode -in @('validation-exit','dependency-exit')) {
        $expected=if ($mode -eq 'validation-exit') { 'validate' } else { 'validate,copy,runtime' }
        Check ($failed -and ($events -join ',') -eq $expected) "$mode continued after nonzero preparation exit"
        Write-Host "PASS real prepared installer: $mode ($($events -join ','))"
        continue
    }
    foreach ($stage in @('validate','runtime','node','ml')) { Check (@($events|Where-Object {$_ -eq $stage}).Count -eq 1) "$mode repeated or missed $stage" }
    if ($mode -in @('env-mutates','env-stop-mutates')) {
        Check ($failed -and $events -notcontains 'activate' -and $events -notcontains 'backup') 'Concurrent config edit allowed stale-config activation or backup.'
        Check (($events -contains 'stop') -eq ($mode -eq 'env-stop-mutates')) 'Config changed during preparation stopped the running instance.'
        Check ((Get-Content -Raw (Join-Path $data immich.env)) -match 'edited-during-') 'Concurrent config edit was overwritten.'
    } elseif ($mode -eq 'move-smoke-failure') {
        Check ($failed -and $events -contains 'activate' -and $events -contains 'smoke') 'Transferred dependency failure did not reach the recovery case.'
        Check (Test-Path (Join-Path $old 'runtime/node/node.exe')) 'Failed candidate did not restore the old runtime.'
        Check (-not (Test-Path (Join-Path $candidate 'runtime/node/node.exe'))) 'Failure restoration copied the runtime.'
        Check ((Get-CurrentReleaseTarget $root) -eq $candidate) 'Failure unexpectedly switched releases automatically.'
        Check ((Get-Content -Raw (Join-Path $data 'state/upgrade-recovery.json')|ConvertFrom-Json).status -eq 'failed') 'Candidate with restored dependencies was not startup-blocked.'
    } elseif ($mode -eq 'ml-failure') {
        Check ($failed -and $events -notcontains 'stop' -and $events -notcontains 'activate') 'Failed dependencies changed the running release.'
    } elseif ($mode -eq 'prepare-only') {
        Check (-not $failed -and $events -notcontains 'stop' -and $events -notcontains 'compare' -and $events -notcontains 'activate') 'Standalone preparation changed the running release.'
    } elseif ($mode -eq 'standalone-changed') {
        Check ($failed -and $events -contains 'compare' -and $events -notcontains 'activate') 'Standalone application-only install bypassed DB proof.'
    } else {
        Check (-not $failed) "$mode installation failed"
        foreach ($stage in @('stop','compare','activate')) { Check (@($events|Where-Object {$_ -eq $stage}).Count -eq 1) "$mode repeated or missed $stage" }
        $compare=[array]::IndexOf($events,'compare');$activation=[array]::IndexOf($events,'activate')
        Check (-not @($events[($compare+1)..$activation]|Where-Object {$_ -in @('runtime','node','ml','copy')}).Count) 'Prepared payload was modified after its DB proof.'
        Check (($events -contains 'backup') -eq ($mode -in @('changed','stop-mutates','bootstrap-entry'))) "$mode backup policy is wrong"
    }
    if ($mode -eq 'same-move') {
        Check (-not (Test-Path (Join-Path $old 'runtime/node/node.exe'))) 'Successful update copied instead of moved Node.'
        Check (Test-Path (Join-Path $candidate 'runtime/node/node.exe')) 'Successful update did not transfer Node.'
        Check ($events -notcontains 'backup') 'Deferred identical Node triggered an unnecessary DB backup.'
    }
    if ($mode -eq 'bootstrap-entry') {
        $actual=Get-Content -Raw (Join-Path (Get-CurrentReleaseTarget $root) manifest.json)|ConvertFrom-Json
        $saved=Read-EnvFile (Join-Path $data immich.env)
        Check ($actual.packageVersion -ceq 'v3.2.4.0') 'Bootstrap entry failed to activate revision zero.'
        Check ($saved['DB_PASSWORD'] -ceq 'fixture' -and $saved['DB_DATABASE_NAME'] -ceq 'existing_database' -and $saved['IMMICH_MEDIA_LOCATION'] -ceq $media -and $saved['CUSTOM_SETTING'] -ceq 'preserve=this value') 'Bootstrap entry changed saved data paths or settings.'
    }
    Write-Host "PASS real prepared installer: $mode ($($events -join ','))"
 }
 # Keep these exact cheap callsites from regressing to tree scans / network checks.
 $smoke=Get-Content -Raw (Join-Path $repo 'tests/Smoke-Windows.ps1')
 Check ($smoke -match '\$python=Get-ImmichPythonExecutable -ReleaseRoot \$current') 'Smoke interpreter discovery regressed.'
 $node=Get-Content -Raw (Join-Path $repo 'runtime/launchers/Install-NodeDependencies.ps1')
 Check (($node -split "'--prefer-offline'").Count -eq 2) 'pnpm prefer-offline must be present once.'
 Check ($node -match "'--frozen-lockfile'" -and $node -notmatch "'--offline'") 'pnpm lost frozen inputs or added an offline retry.'
} finally {
 foreach ($exe in $executables) { Remove-Item "function:global:$exe" -ErrorAction SilentlyContinue }
 Remove-Item Env:IMMICH_TEST_PREPARED_EVENTS,Env:IMMICH_TEST_PREPARED_MODE -ErrorAction SilentlyContinue
 if (Test-Path $base) { Remove-Item -LiteralPath $base -Recurse -Force }
}
