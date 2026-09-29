[CmdletBinding()]
param(
    [string]$Destination,
    [string]$PostgresRoot = 'C:\Program Files\PostgreSQL\18',
    [switch]$SkipPostgresExtensions,
    [switch]$InstallCargoPgrx
)
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
Assert-WindowsX64
$root = Get-RepositoryRoot
if (-not $Destination) { $Destination = Join-Path $root 'artifacts\native' }
New-Item -ItemType Directory -Path $Destination -Force | Out-Null
$versions=Read-JsonFile (Join-Path $root 'dependencies\versions.json')
function Invoke-CachedNativeStage {
    param([string]$Name,[string]$Script,[object]$Version,[string]$Required,[hashtable]$Arguments=@{})
    $target=Join-Path $Destination $Name
    $statePath=Join-Path $Destination ".build-inputs\$($Name.Replace('\','-')).json"
    $inputs=[ordered]@{version=$Version;script=(Get-Item -LiteralPath (Join-Path $PSScriptRoot $Script)).LastWriteTimeUtc.Ticks}
    if($Name -like 'postgres-extensions\*'){
        $inputs.postgresRoot=(Resolve-Path -LiteralPath $PostgresRoot).Path
        $inputs.postgresqlVersion=$versions.postgresql.version
    }
    $inputJson=$inputs|ConvertTo-Json -Depth 8 -Compress
    if((Test-Path -LiteralPath $statePath -PathType Leaf) -and
        (Get-Content -Raw -LiteralPath $statePath).Trim() -ceq $inputJson -and
        (Test-Path -LiteralPath (Join-Path $target $Required) -PathType Leaf)){
        Write-Host "Reusing native stage at $target"
        return
    }
    Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
    & (Join-Path $PSScriptRoot $Script) -Destination $target @Arguments
    New-Item -ItemType Directory -Path (Split-Path $statePath -Parent) -Force | Out-Null
    $inputJson|Set-Content -Encoding utf8 -LiteralPath $statePath
}
Invoke-CachedNativeStage -Name 'node' -Script 'Fetch-NodeRuntime.ps1' -Version $versions.node -Required 'node.exe'
Invoke-CachedNativeStage -Name 'ffmpeg' -Script 'Fetch-FFmpeg.ps1' -Version $versions.ffmpeg -Required 'ffmpeg.exe'
Invoke-CachedNativeStage -Name 'valkey' -Script 'Fetch-Valkey.ps1' -Version $versions.valkey -Required 'ValkeyService.exe'
Invoke-CachedNativeStage -Name 'winsw' -Script 'Fetch-WinSW.ps1' -Version $versions.winsw -Required 'WinSW-x64.exe'
Invoke-CachedNativeStage -Name 'vc-runtime' -Script 'Stage-VcRuntime.ps1' -Version $null -Required 'vcruntime140.dll'
if (-not $SkipPostgresExtensions) {
    Invoke-CachedNativeStage -Name 'postgres-extensions\vector' -Script 'Build-PgVector.ps1' -Version $versions.pgvector -Required 'vector.dll' -Arguments @{PostgresRoot=$PostgresRoot}
    Invoke-CachedNativeStage -Name 'postgres-extensions\vchord' -Script 'Build-VectorChord.ps1' -Version $versions.vectorchord -Required 'vchord.dll' -Arguments @{PostgresRoot=$PostgresRoot;InstallCargoPgrx=$InstallCargoPgrx}
    & (Join-Path $PSScriptRoot 'Write-PostgresBuildMetadata.ps1') -Destination $Destination
}
Write-Host "Native dependency set staged at $Destination"
