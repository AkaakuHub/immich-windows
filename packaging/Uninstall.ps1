[CmdletBinding(SupportsShouldProcess)]
param([ValidateSet('AllUsers','CurrentUser')][string]$Scope='AllUsers',[string]$DataRoot,[string]$InstallRoot,[switch]$RemovePersistentData)
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
if ($Scope -eq 'AllUsers') { Assert-Administrator }
$paths=Resolve-ImmichInstallPaths -Scope $Scope -InstallRoot $InstallRoot -DataRoot $DataRoot
$DataRoot=$paths.DataRoot
$InstallRoot=$paths.InstallRoot
if ($PSCmdlet.ShouldProcess($InstallRoot,'Remove Immich application releases')) {
    if ($Scope -eq 'CurrentUser') {
        $envFile=Join-Path $DataRoot 'immich.env'
        if (Test-Path -LiteralPath $envFile) { & (Join-Path $InstallRoot 'current\runtime\Stop-Immich.ps1') -EnvFile $envFile -DataRoot $DataRoot -InstallRoot $InstallRoot }
    } else {
        $services = Join-Path $DataRoot 'services'
        foreach ($name in @('ImmichServer','ImmichMachineLearning')) {
            $exe = Join-Path $services "$name.exe"
            if (Test-Path $exe) { & $exe stop 2>$null; & $exe uninstall 2>$null }
        }
        $valkey = Join-Path $InstallRoot 'current\dependencies\valkey\ValkeyService.exe'
        if (Test-Path $valkey) { & $valkey uninstall --service-name ImmichValkey 2>$null }
    }
    Remove-Item $InstallRoot -Recurse -Force -ErrorAction SilentlyContinue
}
if ($RemovePersistentData -and $PSCmdlet.ShouldProcess($DataRoot,'Remove Immich persistent config/cache/logs/Valkey data')) { Remove-Item $DataRoot -Recurse -Force -ErrorAction SilentlyContinue }
