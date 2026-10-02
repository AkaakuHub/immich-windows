#requires -Version 7.0
# Disposable filesystem fixtures; Windows services and PostgreSQL are never invoked.
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$base=Join-Path ([IO.Path]::GetTempPath()) ('immich-installer-safety-'+[guid]::NewGuid().ToString('N'))
$previousTemp=$env:TEMP
$previousPassword=$env:PGPASSWORD
function Check([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
try {
    $env:TEMP=$base
    $pg=Join-Path $base postgres
    $package=Join-Path $base package
    foreach ($path in @('bin','lib','share/extension')) { New-Item -ItemType Directory (Join-Path $pg $path) -Force | Out-Null }
    foreach ($path in @('installer','runtime','dependencies/postgres-extensions/vector','dependencies/postgres-extensions/vchord')) { New-Item -ItemType Directory (Join-Path $package $path) -Force | Out-Null }
    foreach ($name in @('vector','vchord')) {
        Set-Content (Join-Path $package "dependencies/postgres-extensions/$name/$name.control") "default_version = '1.0.0'"
        Set-Content (Join-Path $package "dependencies/postgres-extensions/$name/$name.dll") "new-$name"
        Set-Content (Join-Path $pg "lib/$name.dll") "old-$name"
        Set-Content (Join-Path $pg "share/extension/$name.control") "default_version = '0.9.0'"
    }
    $psql=Join-Path $pg 'bin/psql.exe'
    Set-Content $psql fixture
    Set-Item "function:global:$psql" { $global:LASTEXITCODE=0; if ($args[-1] -like 'SHOW*') { 'vchord' } else { '0' } }
    @'
function Assert-Administrator {}
function ConvertTo-TrimmedOutput { param($Output) return ([string]$Output).Trim() }
Export-ModuleMember -Function *
'@ | Set-Content (Join-Path $package 'runtime/Common.psm1')
    $scriptPath=Join-Path $package 'installer/Install-PostgresExtensions.ps1'
    Microsoft.PowerShell.Management\Copy-Item (Join-Path $repo 'packaging/Install-PostgresExtensions.ps1') $scriptPath
    $service=[pscustomobject]@{Status='Running'}
    $service | Add-Member ScriptMethod WaitForStatus { param($Status,$Timeout) }
    $events=[Collections.Generic.List[string]]::new()
    function Get-Service { param($Name) return $service }
    function Stop-Service { param($Name,[switch]$Force) $events.Add('stop'); $service.Status='Stopped' }
    function Start-Service { param($Name) $events.Add('start'); $service.Status='Running' }
    function Start-Sleep { param($Seconds) }
    function Copy-Item {
        [CmdletBinding()]
        param([Parameter(ValueFromPipeline,Position=0)]$Path,[string]$LiteralPath,[Parameter(Position=1)][string]$Destination,[switch]$Force)
        process {
            $source=if ($LiteralPath) { $LiteralPath } else { [string]$Path }
            if ($source -eq (Join-Path $package 'dependencies/postgres-extensions/vchord/vchord.dll')) {
                # A normal nonterminating copy error must become terminating in the installer.
                Microsoft.PowerShell.Management\Copy-Item -LiteralPath (Join-Path $base missing.dll) -Destination $Destination
            } else { Microsoft.PowerShell.Management\Copy-Item -LiteralPath $source -Destination $Destination -Force:$Force }
        }
    }
    $ErrorActionPreference='Continue'
    $failed=$false
    try { & $scriptPath -PackageRoot $package -PostgresRoot $pg -AdminPassword fixture -RecoveryRestore } catch { $failed=$true }
    $ErrorActionPreference='Stop'
    Check $failed 'Standalone extension installation ignored a copy failure.'
    Check (((Get-Content -Raw (Join-Path $pg 'lib/vector.dll')).Trim()) -eq 'old-vector') 'Copy failure left the first extension DLL replaced.'
    Check (($events -join ',') -eq 'stop,start') 'Copy failure did not restore the original service running state.'
    Write-Host 'PASS PostgreSQL extension install: standalone copy failure restores DLLs and reports failure'

    $tokens=$null;$parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'runtime/Common.psm1'),[ref]$tokens,[ref]$parseErrors)
    Check ($parseErrors.Count -eq 0) 'Runtime module did not parse.'
    $helper=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Set-ImmichServerDependencies'},$true)
    . ([scriptblock]::Create($helper.Extent.Text))
    $scCalls=[Collections.Generic.List[string]]::new()
    $registered=@('postgres-old','ImmichValkey','OperatorDependency')
    $scFailure=$false
    function Get-ItemProperty {
        [CmdletBinding()]param($LiteralPath)
        Check ($LiteralPath -eq 'HKLM:\SYSTEM\CurrentControlSet\Services\ImmichServer') 'Dependency reconciliation read an unrelated service.'
        [pscustomobject]@{DependOnService=@($registered | Where-Object { -not $_.StartsWith('+') });DependOnGroup=@('NetworkGroup')}
    }
    function sc.exe {
        Check ($args.Count -eq 4 -and $args[0] -eq 'config' -and $args[1] -eq 'ImmichServer' -and $args[2] -eq 'depend=') 'Reconciliation changed settings other than dependencies.'
        $scCalls.Add([string]$args[3])
        $global:LASTEXITCODE=if ($scFailure) { 5 } else { 0 }
    }
    $old='<service><id>ImmichServer</id><depend>postgres-old</depend><depend>ImmichValkey</depend></service>'
    $external='<service><id>ImmichServer</id><depend>postgres-new</depend></service>'
    $bundled='<service><id>ImmichServer</id><depend>postgres-new</depend><depend>ImmichValkey</depend></service>'
    Set-ImmichServerDependencies -Configuration $external -PreviousConfiguration $old
    Check ($scCalls[-1] -eq 'OperatorDependency/+NetworkGroup/postgres-new') 'External mode retained managed old dependencies or removed operator dependencies.'
    $registered=$scCalls[-1] -split '/'
    $count=$scCalls.Count
    Set-ImmichServerDependencies -Configuration $external -PreviousConfiguration $external
    Check ($scCalls.Count -eq $count) 'Unchanged dependencies caused an unnecessary SCM mutation.'
    Set-ImmichServerDependencies -Configuration $bundled -PreviousConfiguration $external
    Check ($scCalls[-1] -eq 'OperatorDependency/+NetworkGroup/postgres-new/ImmichValkey') 'Bundled mode failed to restore the Valkey dependency.'
    $registered=$scCalls[-1] -split '/'
    Set-ImmichServerDependencies -Configuration $external -PreviousConfiguration $external
    Check ($scCalls[-1] -notlike '*ImmichValkey*') 'Already-stale Valkey registration was preserved as an operator dependency.'
    Set-ImmichServerDependencies -Configuration $old -PreviousConfiguration $bundled
    Check ($scCalls[-1] -eq 'OperatorDependency/+NetworkGroup/postgres-old/ImmichValkey') 'Rollback did not restore paired dependencies.'
    $scFailure=$true
    $failed=$false
    try { Set-ImmichServerDependencies -Configuration $external -PreviousConfiguration $bundled } catch { $failed=$_.Exception.Message -like '*exit 5*' }
    Check $failed 'SCM configuration failure was reported as successful.'
    $scFailure=$false
    $recoveryAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'packaging/Recover-Upgrade.ps1'),[ref]$tokens,[ref]$parseErrors)
    Check ($parseErrors.Count -eq 0) 'Recovery script did not parse.'
    $recoveryHelper=$recoveryAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-RecoveryServerConfiguration'},$true)
    . ([scriptblock]::Create($recoveryHelper.Extent.Text))
    foreach ($mode in @('External','BundledValkey')) {
        $original=if ($mode -eq 'External') { $old } else { $external }
        $restored=Get-RecoveryServerConfiguration $original @{POSTGRES_SERVICE='postgres-restored';IMMICH_WINDOWS_REDIS_MODE=$mode} 'postgres-default'
        $dependencies=@(([xml]$restored).SelectNodes('/service/depend') | ForEach-Object { $_.InnerText })
        Check ($dependencies[0] -eq 'postgres-restored' -and (($dependencies -contains 'ImmichValkey') -eq ($mode -eq 'BundledValkey'))) "Restored XML disagrees with saved $mode environment."
        $registered=@('postgres-new','ImmichValkey','OperatorDependency')
        Set-ImmichServerDependencies -Configuration $restored -PreviousConfiguration $bundled
        Check ($scCalls[-1] -eq ('OperatorDependency/+NetworkGroup/'+($dependencies -join '/'))) "Restored SCM dependencies disagree with $mode XML."
    }
    $missingGuard=$recoveryAst.Find({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -like '*SelectSingleNode*'},$true)
    Check ($null -ne $missingGuard) 'Recovery has no explicit missing bundled-service check.'
    $configuration=$restored
    function Get-Service { [CmdletBinding()]param($Name) return $null }
    $failed=$false
    try { & ([scriptblock]::Create($missingGuard.Extent.Text)) } catch { $failed=$_.Exception.Message -like '*missing ImmichValkey service*' }
    Check $failed 'Recovery claimed a bundled configuration without its service.'
    $global:LASTEXITCODE=0
    Write-Host 'PASS service dependencies: Redis transitions, PostgreSQL change, operator extras/groups, stale registration, rollback, missing bundled service and SCM failure'
} finally {
    $env:TEMP=$previousTemp
    $env:PGPASSWORD=$previousPassword
    if ($psql) { Remove-Item "function:global:$psql" -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
}
