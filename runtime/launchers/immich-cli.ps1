[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
$release = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$vcRuntime = Join-Path $release 'runtime\vc-runtime'
if (Test-Path -LiteralPath $vcRuntime -PathType Container) { $env:PATH = "$vcRuntime;$env:PATH" }
$node = Join-Path $release 'runtime\node\node.exe'
$cli = Join-Path $release 'cli\dist\index.js'
if (-not (Test-Path $cli)) { throw "Immich CLI entrypoint not found: $cli" }
& $node $cli @Arguments
exit $LASTEXITCODE
