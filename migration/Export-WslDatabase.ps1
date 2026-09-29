#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Distro,
    [Parameter(Mandatory)][string]$ComposeFile,
    [Parameter(Mandatory)][string]$Destination,
    [string]$DatabaseService='database',
    [string[]]$ApplicationServices=@('immich-server','immich-machine-learning'),
    [string]$DatabaseUser='postgres',
    [string]$DatabaseName='immich',
    [string]$PostgresRoot='C:\Program Files\PostgreSQL\18'
)

$ErrorActionPreference='Stop'
$Destination=[IO.Path]::GetFullPath($Destination)
if(-not $Destination.EndsWith('.dump',[StringComparison]::OrdinalIgnoreCase)){throw 'Destination must end in .dump.'}
if(Test-Path -LiteralPath $Destination){throw "Destination already exists: $Destination"}
$parent=Split-Path -Parent $Destination
if(-not(Test-Path -LiteralPath $parent -PathType Container)){throw "Destination directory does not exist: $parent"}
$pgRestore=Join-Path $PostgresRoot 'bin\pg_restore.exe'
if(-not(Test-Path -LiteralPath $pgRestore -PathType Leaf)){throw "pg_restore.exe not found: $pgRestore"}
$partial="$Destination.partial"
if(Test-Path -LiteralPath $partial){throw "Partial dump already exists: $partial"}

$compose=@('-d',$Distro,'--exec','docker','compose','-f',$ComposeFile)
try {
    if($ApplicationServices.Count){
        & wsl.exe @compose stop @ApplicationServices
        if($LASTEXITCODE -ne 0){throw 'Could not stop the WSL Immich application services.'}
    }
    $arguments=@($compose)+@('exec','-T',$DatabaseService,'pg_dump','-Fc','--no-owner','-w','-U',$DatabaseUser,'-d',$DatabaseName)
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName='wsl.exe'
    foreach ($argument in $arguments) { $start.ArgumentList.Add($argument) }
    $start.UseShellExecute=$false
    $start.RedirectStandardOutput=$true
    $start.RedirectStandardError=$true
    $process=[Diagnostics.Process]::Start($start)
    try {
        $stderr=$process.StandardError.ReadToEndAsync()
        $output=[IO.File]::Create($partial)
        try {$process.StandardOutput.BaseStream.CopyTo($output)} finally {$output.Dispose()}
        $process.WaitForExit()
        if($process.ExitCode -ne 0){throw "WSL pg_dump failed: $($stderr.Result.Trim())"}
    } finally {$process.Dispose()}

    & $pgRestore --list $partial | Out-Null
    if($LASTEXITCODE -ne 0){throw 'The exported PostgreSQL dump cannot be read.'}
    Move-Item -LiteralPath $partial -Destination $Destination
    Write-Host "Database dump created: $Destination"
    Write-Host 'WSL Immich application services remain stopped until migration is complete.'
} catch {
    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    if($ApplicationServices.Count){
        & wsl.exe @compose start @ApplicationServices
        if($LASTEXITCODE -ne 0){Write-Warning 'Could not restart the WSL Immich application services after export failure.'}
    }
    throw
}
