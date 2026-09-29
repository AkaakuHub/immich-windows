#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RepositoryRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
}

function Assert-WindowsX64 {
    if ($env:OS -ne 'Windows_NT') { throw 'This build script must run on Windows.' }
    if (-not [Environment]::Is64BitOperatingSystem -or [IntPtr]::Size -ne 8) {
        throw 'Only a 64-bit Windows x64 PowerShell process is supported by the initial port.'
    }
}

function Test-WindowsAbsolutePath {
    param([Parameter(Mandatory)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($Path -match '^[A-Za-z]:[\\/]') { return $true }
    if ($Path -match '^\\\\[^\\]+\\[^\\]+(?:\\|$)') { return $true }
    if ($Path -match '^\\\\\?\\(?:[A-Za-z]:\\|UNC\\)') { return $true }
    return $false
}

function Get-RelativePathPortable {
    param([Parameter(Mandatory)][string]$BasePath,[Parameter(Mandatory)][string]$FullPath)
    $base = (Resolve-Path -LiteralPath $BasePath).Path
    $full = (Resolve-Path -LiteralPath $FullPath).Path
    return [IO.Path]::GetRelativePath($base,$full)
}

function Assert-Command {
    param([Parameter(Mandatory)][string]$Name)
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) { throw "Required command '$Name' was not found in PATH." }
    return $command.Source
}

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter()][string[]]$ArgumentList = @(),
        [Parameter()][string]$WorkingDirectory
    )
    Write-Host "> $FilePath $($ArgumentList -join ' ')"
    $old = Get-Location
    try {
        if ($WorkingDirectory) { Set-Location -LiteralPath $WorkingDirectory }
        & $FilePath @ArgumentList
        if ($LASTEXITCODE -ne 0) {
            throw "Command failed with exit code ${LASTEXITCODE}: $FilePath $($ArgumentList -join ' ')"
        }
    } finally {
        Set-Location $old
    }
}

function New-CleanDirectory {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    return (Resolve-Path -LiteralPath $Path).Path
}

function Copy-Directory {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [string[]]$ExcludeDirectory = @()
    )
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $arguments = @($Source,$Destination,'/E','/SL','/COPY:DAT','/DCOPY:DAT','/R:2','/W:1','/NFL','/NDL','/NJH','/NJS','/NP')
    if ($ExcludeDirectory.Count) { $arguments += @('/XD') + $ExcludeDirectory }
    & robocopy @arguments | Out-Host
    $robocopyExitCode = $LASTEXITCODE
    if ($robocopyExitCode -gt 7) { throw "robocopy failed with exit code ${robocopyExitCode}: $Source -> $Destination" }
    $global:LASTEXITCODE = 0
}

function Write-Utf8NoBom {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Get-CachedDownload {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Destination
    )
    $parent = Split-Path -Parent $Destination
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
        $partial = "$Destination.download"
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        Write-Host "Downloading $Uri"
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $partial
            Move-Item -LiteralPath $partial -Destination $Destination
        } catch {
            Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
            throw
        }
    }
    return (Resolve-Path -LiteralPath $Destination).Path
}

function Expand-ZipClean {
    param(
        [Parameter(Mandatory)][string]$Archive,
        [Parameter(Mandatory)][string]$Destination
    )
    $Destination = New-CleanDirectory $Destination
    Expand-Archive -LiteralPath $Archive -DestinationPath $Destination -Force
    return $Destination
}

function Write-BuildLock {
    param([string]$Path,[object]$Versions)
    $content=[ordered]@{
        sources=@(
            [ordered]@{name='ffmpeg';version=$Versions.ffmpeg.version},
            [ordered]@{name='libvips';version=$Versions.sharpLibvips.version}
        )
        packages=@()
    } | ConvertTo-Json -Depth 5
    if((Test-Path -LiteralPath $Path -PathType Leaf) -and (Get-Content -Raw -LiteralPath $Path).TrimEnd() -ceq $content){return}
    $content | Set-Content -Encoding utf8 -LiteralPath $Path
}

function Assert-FileExists {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Expected file was not found: $Path" }
    return (Resolve-Path -LiteralPath $Path).Path
}

Export-ModuleMember -Function *
