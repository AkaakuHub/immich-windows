[CmdletBinding()]
param([string]$Destination)

Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
Assert-WindowsX64
$root = Get-RepositoryRoot
if (-not $Destination) { $Destination = Join-Path $root 'artifacts\native\vc-runtime' }

$redistRoot = $env:VCToolsRedistDir
if (-not $redistRoot -or -not (Test-Path -LiteralPath $redistRoot -PathType Container)) {
    throw 'VCToolsRedistDir is not set. Run build/Enter-VsDevEnvironment.ps1 before staging the MSVC runtime.'
}

$crt = Join-Path $redistRoot 'x64\Microsoft.VC143.CRT'
if (-not (Test-Path -LiteralPath $crt -PathType Container)) {
    $crt = Get-ChildItem -LiteralPath $redistRoot -Directory -Recurse -Filter 'Microsoft.VC143.CRT' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\x64\\' } |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $crt -or -not (Test-Path -LiteralPath $crt -PathType Container)) {
    throw "Visual C++ x64 app-local CRT directory was not found below $redistRoot"
}

$required = @('vcruntime140.dll','msvcp140.dll')
foreach ($name in $required) { Assert-FileExists (Join-Path $crt $name) | Out-Null }

$Destination = New-CleanDirectory $Destination
Get-ChildItem -LiteralPath $crt -Filter '*.dll' -File | Copy-Item -Destination $Destination -Force
$manifest = [ordered]@{
    source = $crt
    files = @(Get-ChildItem -LiteralPath $Destination -Filter '*.dll' -File | Sort-Object Name | Select-Object -ExpandProperty Name)
    builtAtUtc = [DateTime]::UtcNow.ToString('o')
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 -LiteralPath (Join-Path $Destination 'vc-runtime.json')
Write-Host "MSVC x64 app-local runtime staged at $Destination"
