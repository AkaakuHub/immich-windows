#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Destination)
$ErrorActionPreference='Stop'
if (-not $IsWindows) { throw 'The tray is compiled with the Windows .NET Framework compiler.' }
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw "The Windows .NET Framework compiler is missing: $compiler" }
$source=Join-Path $PSScriptRoot '..\runtime\tray\ImmichTray.cs'
New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
& $compiler /nologo /target:winexe /platform:anycpu /optimize+ /langversion:5 /codepage:65001 /utf8output `
    /reference:System.Windows.Forms.dll /reference:System.Drawing.dll "/out:$Destination" $source
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $Destination -PathType Leaf)) { throw 'Could not compile the Immich notification-area controller.' }
Write-Host "Built lightweight Immich tray: $Destination"
