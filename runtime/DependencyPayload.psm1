#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ImmichDependencyPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Payload,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$CacheRoot,
        [string]$InstalledPath
    )
    $hash = [string]$Payload.sha256
    $name = [string]$Payload.assetName
    if ($hash -cnotmatch '\A[0-9a-f]{64}\z' -or $name -cne "dependency-$hash") { throw 'Invalid dependency payload identity.' }
    New-Item -ItemType Directory -Path $CacheRoot -Force | Out-Null
    $path = Join-Path $CacheRoot $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -and $InstalledPath -and
        (Test-Path -LiteralPath $InstalledPath -PathType Leaf) -and
        (Get-FileHash -Algorithm SHA256 -LiteralPath $InstalledPath).Hash -ieq $hash) {
        Copy-Item -LiteralPath $InstalledPath -Destination $path
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $partial = "$path.download"
        try {
            Invoke-WebRequest -Uri "https://github.com/AkaakuHub/immich-windows/releases/download/$Version/$name" -OutFile $partial
            if ((Get-FileHash -Algorithm SHA256 -LiteralPath $partial).Hash -ine $hash) { throw "Downloaded dependency checksum mismatch: $name" }
            [IO.File]::Move($partial, $path, $true)
        } finally { Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue }
    }
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash -ine $hash) { throw "Cached dependency checksum mismatch: $name" }
    return $path
}

Export-ModuleMember -Function Get-ImmichDependencyPayload
