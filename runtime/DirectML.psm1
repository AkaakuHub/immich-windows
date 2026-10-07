#requires -Version 7.0
Set-StrictMode -Version Latest

function Resolve-ImmichDirectMLAdapter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PythonPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$DeviceInstanceId
    )
    if ([string]::IsNullOrWhiteSpace($DeviceInstanceId)) {
        throw 'IMMICH_WINDOWS_ML_DEVICE_INSTANCE_ID is required for DirectML.'
    }
    $output = & $PythonPath (Join-Path $PSScriptRoot 'DirectML-Adapter.py') --instance-id $DeviceInstanceId
    if ($LASTEXITCODE -ne 0) { throw 'The configured DirectML GPU could not be resolved.' }
    $adapter = ($output -join "`n") | ConvertFrom-Json
    Write-Host "DirectML GPU: $($adapter.name); instance: $($adapter.device_instance_id); current DXGI index: $($adapter.device_id)"
    return $adapter
}

Export-ModuleMember -Function Resolve-ImmichDirectMLAdapter
