#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$Destination,
    [switch]$AllowStockSharp
)

Import-Module (Join-Path $PSScriptRoot '..\build\Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\runtime\Common.psm1') -Force
$root = Get-RepositoryRoot
$upstream = Read-JsonFile (Join-Path $root 'upstream.json')
$packageVersion = Get-WindowsReleaseVersion $upstream
$versions = Read-JsonFile (Join-Path $root 'dependencies\versions.json')
if (-not $Destination) { $Destination = Join-Path $root "dist\immich-windows-$packageVersion-win-x64" }
$app = Join-Path $root 'artifacts\application'
$ml = Join-Path $root 'artifacts\machine-learning'
foreach ($required in @($app,$ml)) { if (-not (Test-Path $required)) { throw "Build artifact missing: $required" } }
$sharpMarker = Join-Path $app 'sharp-libvips-injection.json'
$sharpQualificationMarker = Join-Path $app 'sharp-libvips-qualification.json'
$customSharp = Test-Path -LiteralPath $sharpMarker -PathType Leaf
$mediaStackQualified = $customSharp -and (Test-Path -LiteralPath $sharpQualificationMarker -PathType Leaf)
if (-not $mediaStackQualified -and -not $AllowStockSharp) {
    throw 'The Windows media stack has not completed the required media fixture checks.'
}

$Destination = New-CleanDirectory $Destination
Copy-Directory (Join-Path $app 'server') (Join-Path $Destination 'server') -ExcludeDirectory @('node_modules')
Copy-Directory (Join-Path $app 'cli') (Join-Path $Destination 'cli') -ExcludeDirectory @('node_modules')
Get-ChildItem (Join-Path $Destination 'server\dist') -File -Recurse |
    Where-Object { $_.Name -match '(\.d\.ts|\.map|\.tsbuildinfo)$' } |
    Remove-Item -Force
Copy-Directory (Join-Path $app 'build') (Join-Path $Destination 'build')
$mlDestination = Join-Path $Destination 'machine-learning'
Copy-Directory (Join-Path $ml 'app') (Join-Path $mlDestination 'app')
Copy-Item (Join-Path $ml 'requirements.txt') (Join-Path $mlDestination 'requirements.txt') -Force
Copy-Item (Join-Path $ml 'ml-manifest.json') (Join-Path $mlDestination 'ml-manifest.json') -Force
Copy-Item (Join-Path $app 'LICENSE') (Join-Path $Destination 'LICENSE') -Force

foreach ($project in @('server','cli')) {
    $projectRoot = Join-Path $Destination $project
    $packagePath = Join-Path $projectRoot 'package.json'
    $package = Get-Content -Raw -LiteralPath $packagePath | ConvertFrom-Json
    $package.PSObject.Properties.Remove('devDependencies')
    foreach ($sectionName in @('dependencies','optionalDependencies','overrides')) {
        $section = $package.$sectionName
        if (-not $section) { continue }
        foreach ($dependency in $section.PSObject.Properties) {
            $dependency.Value = [regex]::Replace([string]$dependency.Value,'^([^()]+)\(.*$','$1')
        }
    }
    if ($project -eq 'server') { $package.dependencies.'@immich/plugin-sdk' = 'file:./.immich/plugin-sdk' }
    $package | Add-Member -NotePropertyName packageManager -NotePropertyValue "pnpm@$($versions.pnpm.version)" -Force
    Write-Utf8NoBom -Path $packagePath -Content ($package | ConvertTo-Json -Depth 100)
    $allowBuilds = "allowBuilds:`n  bcrypt: true`n  sharp: true"
    if ($project -eq 'server') { $allowBuilds += "`n  '@scarf/scarf': false`n  esbuild: true`n  msgpackr-extract: true`n  protobufjs: false" }
    Write-Utf8NoBom -Path (Join-Path $projectRoot 'pnpm-workspace.yaml') -Content $allowBuilds
    Invoke-Native (Assert-Command pnpm) @('install','--lockfile-only','--prod','--config.node-linker=hoisted') $projectRoot
    if (Test-Path -LiteralPath (Join-Path $projectRoot 'node_modules')) { throw "$project must not contain node_modules." }
}

if ($customSharp) {
    Copy-Item -LiteralPath $sharpMarker -Destination (Join-Path $Destination 'sharp-libvips-injection.json') -Force
    Copy-Item -LiteralPath $sharpQualificationMarker -Destination (Join-Path $Destination 'sharp-libvips-qualification.json') -Force
    $smokeMarker = Join-Path $app 'sharp-libvips-smoke.json'
    if (Test-Path -LiteralPath $smokeMarker -PathType Leaf) { Copy-Item -LiteralPath $smokeMarker -Destination (Join-Path $Destination 'sharp-libvips-smoke.json') -Force }
    if (Test-Path -LiteralPath (Join-Path $app 'media-stack')) { Copy-Directory (Join-Path $app 'media-stack') (Join-Path $Destination 'media-stack') }
}

Copy-Directory (Join-Path $root 'runtime') (Join-Path $Destination 'runtime')
& (Join-Path $root 'build\Build-Tray.ps1') -Destination (Join-Path $Destination 'runtime\tray\ImmichTray.exe')
Remove-Item -LiteralPath (Join-Path $Destination 'runtime\tray\ImmichTray.cs')
$installerDestination = Join-Path $Destination 'installer'
New-Item -ItemType Directory -Path $installerDestination -Force | Out-Null
foreach ($name in @(
    'Install-MachineLearningDependencies.ps1','Install-PostgresExtensions.ps1',
    'Install-RuntimeDependencies.ps1','Install.ps1','Recover-Upgrade.ps1','Remove-ObsoleteReleases.ps1','Test-ReleasePackage.ps1',
    'Uninstall.ps1','Update-FromRelease.ps1','Update.ps1'
)) {
    Copy-Item (Join-Path $root "packaging\$name") (Join-Path $installerDestination $name) -Force
}
if (Test-Path (Join-Path $root 'migration')) { Copy-Directory (Join-Path $root 'migration') (Join-Path $Destination 'migration') }
New-Item -ItemType Directory -Path (Join-Path $Destination 'tests') -Force | Out-Null
Copy-Item (Join-Path $root 'tests\Smoke-Windows.ps1') (Join-Path $Destination 'tests\Smoke-Windows.ps1')
Copy-Item (Join-Path $root 'config\immich.env.example') (Join-Path $Destination 'immich.env.example') -Force
$installCmd = (Get-Content -Raw -LiteralPath (Join-Path $root 'packaging\Install.cmd')).Replace('__IMMICH_VERSION__', $packageVersion)
Write-Utf8NoBom -Path (Join-Path $root 'dist\Install.cmd') -Content $installCmd
Copy-Item (Join-Path $root 'README.md') (Join-Path $Destination 'README.md')
New-Item -ItemType Directory -Path (Join-Path $Destination 'docs') -Force | Out-Null
foreach ($name in @('install.md','operations.md','migration.md')) {
    Copy-Item (Join-Path $root "docs\$name") (Join-Path $Destination "docs\$name")
}

# File identity, not ZIP timestamps or upstream version, determines native reuse.
$nativeFiles = [ordered]@{}
$nativeMetadata = [ordered]@{}
if ($mediaStackQualified) {
    $nativeStage = Join-Path $root 'dist\native-dependencies'
    foreach ($file in (Get-ChildItem -LiteralPath $nativeStage -File -Recurse | Where-Object { $_.Name -ne 'vc-runtime.json' } | Sort-Object FullName)) {
        $relative = [IO.Path]::GetRelativePath($nativeStage,$file.FullName).Replace('\','/')
        $nativeFiles[$relative] = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
        if ($relative -in @('dependencies/sharp/versions.json','dependencies/postgres-extensions/build-inputs.json')) {
            $nativeMetadata[$relative] = [Convert]::ToBase64String([IO.File]::ReadAllBytes($file.FullName))
        }
    }
    if ($nativeFiles.Count -eq 0) { throw 'Native dependency content inventory is empty.' }

}
$manifest = [ordered]@{
    schemaVersion = 2
    packageVersion = $packageVersion
    windowsRevision = [int]$upstream.windowsRevision
    sourceCommit = (& git -C $root rev-parse HEAD).Trim()
    nativeDependencyFiles = $nativeFiles
    nativeDependencyMetadata = $nativeMetadata
    nativeDependenciesSha256 = $(if ($mediaStackQualified) { (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $root "dist\immich-windows-$packageVersion-native-dependencies.zip")).Hash.ToLowerInvariant() } else { $null })
    immichVersion = $upstream.version
    upstreamRepository = $upstream.repository
    upstreamCommit = (Get-Content -Raw (Join-Path $app 'application-manifest.json') | ConvertFrom-Json).upstreamCommit
    target = 'windows-x64-native'
    mediaStack = [ordered]@{
        sharpLibvips = $(if ($customSharp) { 'custom-immich-compatible' } else { 'stock-sharp-windows' })
        productionQualified = [bool]$mediaStackQualified
        fixtureQualification = $(if ($mediaStackQualified) { Get-Content -Raw -LiteralPath $sharpQualificationMarker | ConvertFrom-Json } else { $null })
    }
    dependencies = $versions
    builtAtUtc = [DateTime]::UtcNow.ToString('o')
}
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Encoding utf8 -LiteralPath (Join-Path $Destination 'manifest.json')
Write-Host "Application package: $Destination"
