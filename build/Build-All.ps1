[CmdletBinding()]
param(
    [switch]$SkipNativeDependencies,
    [string]$PostgresRoot = 'C:\Program Files\PostgreSQL\18',
    [switch]$InstallCargoPgrx,
    [string]$CustomSharpLibvipsBundle,
    [string[]]$SharpFixture
)
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
Assert-WindowsX64
$root = Get-RepositoryRoot
if (-not $SkipNativeDependencies) { & (Join-Path $PSScriptRoot 'Enter-VsDevEnvironment.ps1') }
& (Join-Path $PSScriptRoot 'Bootstrap-BuildTools.ps1') | Out-Host
$source = & (Join-Path $PSScriptRoot 'Prepare-Source.ps1')
$source = @($source)[-1]
function Invoke-CachedBuildStage {
    param([string]$Destination,[string]$StateName,[object]$Inputs,[string[]]$Required,[scriptblock]$Build)
    $statePath=Join-Path $Destination $StateName
    $inputJson=$Inputs|ConvertTo-Json -Depth 5 -Compress
    if((Test-Path -LiteralPath $statePath -PathType Leaf) -and
        (Get-Content -Raw -LiteralPath $statePath).Trim() -ceq $inputJson -and
        @($Required|Where-Object{-not(Test-Path -LiteralPath (Join-Path $Destination $_))}).Count -eq 0){
        Write-Host "Reusing build stage at $Destination"
        return
    }
    Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
    & $Build
    $inputJson|Set-Content -Encoding utf8 -LiteralPath $statePath
}
$app = Join-Path $root 'artifacts\application'
$versions=Read-JsonFile (Join-Path $root 'dependencies\versions.json')
$appInputs=[ordered]@{
    serverTree=(& git -C $source rev-parse HEAD:server).Trim()
    webTree=(& git -C $source rev-parse HEAD:web).Trim()
    packagesTree=(& git -C $source rev-parse HEAD:packages).Trim()
    lockFile=(& git -C $source rev-parse HEAD:pnpm-lock.yaml).Trim()
    workspaceFile=(& git -C $source rev-parse HEAD:pnpm-workspace.yaml).Trim()
    sourceDiff=(@(& git -C $source diff --binary -- server web packages pnpm-lock.yaml pnpm-workspace.yaml) -join "`n")
    node=$versions.node.version
    pnpm=$versions.pnpm.version
    extismJs=$versions.extismJs.version
    binaryen=$versions.binaryen.version
    sharp=$versions.sharp.version
    builder=(Get-Item -LiteralPath (Join-Path $PSScriptRoot 'Build-Immich.ps1')).LastWriteTimeUtc.Ticks
    geodata=(Get-Item -LiteralPath (Join-Path $PSScriptRoot 'Fetch-Geodata.ps1')).LastWriteTimeUtc.Ticks
}
Invoke-CachedBuildStage -Destination $app -StateName 'build-inputs.json' -Inputs $appInputs -Required @('server\dist\main.js','server\.immich\plugin-sdk\dist\index.js','build\www\index.html','application-manifest.json') -Build {
    & (Join-Path $PSScriptRoot 'Build-Immich.ps1') -Source $source -Destination $app
}
Write-BuildLock -Path (Join-Path $app 'build\build-lock.json') -Versions $versions
if ($CustomSharpLibvipsBundle) {
    $bundle=(Resolve-Path -LiteralPath $CustomSharpLibvipsBundle).Path
    $mediaInputs=[ordered]@{
        application=(Get-Item -LiteralPath (Join-Path $app 'build-inputs.json')).LastWriteTimeUtc.Ticks
        bundle=$bundle
        bundleBuiltAt=(Read-JsonFile (Join-Path $bundle 'immich-windows-libvips.json')).builtAtUtc
        stage=(Get-Item -LiteralPath (Join-Path $PSScriptRoot 'Stage-CustomSharpLibvips.ps1')).LastWriteTimeUtc.Ticks
        test=(Get-Item -LiteralPath (Join-Path $PSScriptRoot 'Test-SharpCapabilities.ps1')).LastWriteTimeUtc.Ticks
        fixtures=@($SharpFixture | ForEach-Object { $file=Get-Item -LiteralPath $_; "$($file.FullName):$($file.LastWriteTimeUtc.Ticks)" })
    }
    Invoke-CachedBuildStage -Destination $app -StateName 'media-build-inputs.json' -Inputs $mediaInputs -Required @('sharp-libvips-injection.json','sharp-libvips-qualification.json') -Build {
        & (Join-Path $PSScriptRoot 'Stage-CustomSharpLibvips.ps1') -ApplicationRoot $app -BundleRoot $bundle
        $testArgs = @{ ApplicationRoot = $app }
        if ($SharpFixture) { $testArgs.Fixture = $SharpFixture }
        & (Join-Path $PSScriptRoot 'Test-SharpCapabilities.ps1') @testArgs
    }
} else {
    Write-Warning 'No custom Sharp/libvips bundle was supplied. This build is suitable for native bring-up only; New-Package.ps1 will require -AllowStockSharp until the codec-complete bundle is injected.'
}
$ml=Join-Path $root 'artifacts\machine-learning'
$mlInputs=[ordered]@{
    sourceTree=(& git -C $source rev-parse HEAD:machine-learning).Trim()
    sourceDiff=(@(& git -C $source diff --binary -- machine-learning) -join "`n")
    python=$versions.python.version
    uv=$versions.uv.version
    builder=(Get-Item -LiteralPath (Join-Path $PSScriptRoot 'Build-MachineLearning.ps1')).LastWriteTimeUtc.Ticks
}
Invoke-CachedBuildStage -Destination $ml -StateName 'build-inputs.json' -Inputs $mlInputs -Required @('app\immich_ml\__main__.py','requirements.txt','ml-manifest.json') -Build {
    & (Join-Path $PSScriptRoot 'Build-MachineLearning.ps1') -Source $source -Destination $ml
}
if (-not $SkipNativeDependencies) {
    $native = Join-Path $PSScriptRoot 'Build-NativeDependencies.ps1'
    & $native -Source $source -Destination (Join-Path $root 'artifacts\native') -PostgresRoot $PostgresRoot -InstallCargoPgrx:$InstallCargoPgrx
}
Write-Host 'All requested build stages completed.'
