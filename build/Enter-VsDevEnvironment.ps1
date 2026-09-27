[CmdletBinding()]
param([switch]$RequireLlvm = $true)

Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
Assert-WindowsX64

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
    throw "vswhere.exe was not found. Install Visual Studio 2022 Build Tools with Desktop development with C++: $vswhere"
}
$install = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
if (-not $install) { throw 'Visual Studio 2022 C++ Build Tools were not found.' }
$vsDevCmd = Join-Path $install 'Common7\Tools\VsDevCmd.bat'
if (-not (Test-Path -LiteralPath $vsDevCmd -PathType Leaf)) { throw "VsDevCmd.bat not found: $vsDevCmd" }

# VsDevCmd is a batch file. Import the environment it creates into this PowerShell
# process so cl.exe, nmake.exe and the Windows SDK are available to later stages.
$command = '"{0}" -no_logo -arch=x64 -host_arch=x64 && set' -f $vsDevCmd
$lines = & $env:ComSpec /d /s /c $command
if ($LASTEXITCODE -ne 0) { throw "VsDevCmd failed with exit code $LASTEXITCODE." }
foreach ($line in $lines) {
    if (-not $line -or $line.StartsWith('=')) { continue }
    $i = $line.IndexOf('=')
    if ($i -lt 1) { continue }
    [Environment]::SetEnvironmentVariable($line.Substring(0,$i), $line.Substring($i+1), 'Process')
}

Assert-Command cl.exe | Out-Null
Assert-Command nmake.exe | Out-Null

if ($RequireLlvm -and -not $env:LIBCLANG_PATH) {
    $llvmCandidates = @(
        (Join-Path $env:ProgramFiles 'LLVM\bin'),
        (Join-Path $install 'VC\Tools\Llvm\x64\bin')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $_ 'libclang.dll') -PathType Leaf) }
    if ($llvmCandidates) {
        $env:LIBCLANG_PATH = $llvmCandidates[0]
        $env:PATH = "$($llvmCandidates[0]);$env:PATH"
    }
}
if ($RequireLlvm) {
    if (-not $env:LIBCLANG_PATH -or -not (Test-Path -LiteralPath (Join-Path $env:LIBCLANG_PATH 'libclang.dll') -PathType Leaf)) {
        throw 'LLVM/libclang was not found. Install LLVM x64 and ensure LIBCLANG_PATH points to the directory containing libclang.dll.'
    }
}

Write-Host "Visual Studio build environment loaded from $install"
if ($env:LIBCLANG_PATH) { Write-Host "LIBCLANG_PATH=$env:LIBCLANG_PATH" }
