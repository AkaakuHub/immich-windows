#requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param([ValidateSet('AllUsers','CurrentUser')][string]$Scope='AllUsers',[string]$DataRoot,[string]$InstallRoot,[switch]$RemovePersistentData)
Import-Module (Join-Path $PSScriptRoot '..\runtime\Common.psm1') -Force
if ($Scope -eq 'AllUsers') { Assert-Administrator }
$paths=Resolve-ImmichInstallPaths -Scope $Scope -InstallRoot $InstallRoot -DataRoot $DataRoot
$DataRoot=$paths.DataRoot
$InstallRoot=$paths.InstallRoot
if ($PSCmdlet.ShouldProcess($InstallRoot,'Remove Immich application releases')) {
    if ($Scope -eq 'CurrentUser') {
        Set-ImmichUserStartup -InstallRoot $InstallRoot -Enabled $false
        $envFile=Join-Path $DataRoot 'immich.env'
        if (Test-Path -LiteralPath $envFile) { & (Join-Path $InstallRoot 'current\runtime\launchers\Stop-Immich.ps1') -EnvFile $envFile -DataRoot $DataRoot -InstallRoot $InstallRoot }
    } else {
        $services = Join-Path $DataRoot 'services'
        foreach ($name in @('ImmichServer','ImmichMachineLearning')) {
            $exe = Join-Path $services "$name.exe"
            if (Test-Path $exe) { & $exe stop 2>$null; & $exe uninstall 2>$null }
        }
        $valkey = Join-Path $InstallRoot 'current\dependencies\valkey\ValkeyService.exe'
        if (Test-Path $valkey) { & $valkey uninstall --service-name ImmichValkey 2>$null }
    }
    Stop-ImmichTray -InstallRoot $InstallRoot
    Set-ImmichTrayStartup -InstallRoot $InstallRoot -DataRoot $DataRoot -Scope $Scope -Enabled $false
    Remove-ImmichLegacyStartMenu -Scope $Scope
    # The tray releases its singleton just before process exit. Allow Windows to
    # release the executable image, but never silently claim a partial removal.
    $deadline=[DateTime]::UtcNow.AddSeconds(10)
    do {
        try {
            if (Test-Path -LiteralPath $InstallRoot) { Remove-Item -LiteralPath $InstallRoot -Recurse -Force -ErrorAction Stop }
            break
        } catch {
            if ([DateTime]::UtcNow -ge $deadline) { throw "Immich application files are still in use. Close any other users' tray instances and retry uninstall. $($_.Exception.Message)" }
            Start-Sleep -Milliseconds 200
        }
    } while ($true)
}
if ($RemovePersistentData -and $PSCmdlet.ShouldProcess($DataRoot,'Remove Immich persistent config/cache/logs/Valkey data')) { Remove-Item $DataRoot -Recurse -Force -ErrorAction SilentlyContinue }
