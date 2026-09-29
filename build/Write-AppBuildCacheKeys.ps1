#requires -Version 7.0
param([Parameter(Mandatory)][string]$OutputPath)
$versions = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\dependencies\versions.json') | ConvertFrom-Json
$application = @($versions.node.version,$versions.pnpm.version,$versions.extismJs.version,$versions.binaryen.version,$versions.sharp.version) -join '-'
$machineLearning = @($versions.python.version,$versions.uv.version) -join '-'
Add-Content -LiteralPath $OutputPath -Value "application=$application"
Add-Content -LiteralPath $OutputPath -Value "machineLearning=$machineLearning"
