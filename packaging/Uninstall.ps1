[CmdletBinding(SupportsShouldProcess)]
param([string]$DataRoot='C:\ProgramData\Immich',[string]$InstallRoot='C:\Program Files\Immich',[switch]$RemovePersistentData)
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
Assert-Administrator
$services = Join-Path $DataRoot 'services'
foreach ($name in @('ImmichServer','ImmichMachineLearning')) {
    $exe = Join-Path $services "$name.exe"
    # The generic WinSW binary is renamed next to a same-basename XML file at
    # install time. In this mode WinSW resolves its XML implicitly; passing the
    # XML path as a positional argument is interpreted as an extra service arg.
    if (Test-Path $exe) { & $exe stop 2>$null; & $exe uninstall 2>$null }
}
$valkey = Join-Path $InstallRoot 'current\dependencies\valkey\ValkeyService.exe'
if (Test-Path $valkey) { & $valkey uninstall --service-name ImmichValkey 2>$null }
if ($PSCmdlet.ShouldProcess($InstallRoot,'Remove Immich application releases')) { Remove-Item $InstallRoot -Recurse -Force -ErrorAction SilentlyContinue }
if ($RemovePersistentData -and $PSCmdlet.ShouldProcess($DataRoot,'Remove Immich persistent config/cache/logs/Valkey data')) { Remove-Item $DataRoot -Recurse -Force -ErrorAction SilentlyContinue }
