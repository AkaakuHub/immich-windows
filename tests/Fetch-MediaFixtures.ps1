[CmdletBinding()]
param([Parameter(Mandatory)][string]$Destination)

$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../build/Common.psm1') -Force
New-Item -ItemType Directory -Path $Destination -Force|Out-Null

$jxl='https://raw.githubusercontent.com/libjxl/testdata/main'
$heif='https://raw.githubusercontent.com/strukturag/libheif/master'
$fixtures=[ordered]@{
    'fixture-jpeg-flower.jpg'="$jxl/jxl/flower/flower.png.im_q85_420.jpg"
    'fixture-jpeg-cropped.jpg'="$jxl/jxl/flower/flower_cropped.jpg"
    'fixture-png-flower.png'="$jxl/jxl/flower/flower.png"
    'fixture-webp-feature.webp'='https://raw.githubusercontent.com/immich-app/immich/v3.2.2/docs/docs/overview/img/feature-panel.webp'
    'fixture-avif-example.avif'="$heif/examples/example.avif"
    'fixture-heic-example.heic'="$heif/examples/example.heic"
    'fixture-heic-alpha.heic'="$heif/tests/data/with-alpha-512x512.heic"
    'fixture-heic-rainbow.heic'="$heif/tests/data/rainbow-451x461.heic"
    'fixture-raw-purple-cast.dng'='https://media.githubusercontent.com/media/reatom/reatom/v1001/examples/gallery/src/__fixtures__/images/tier-c/dng/574-purple-cast.dng'
    'fixture-jxl-traffic-light.jxl'="$jxl/jxl/blending/cropped_traffic_light.jxl"
}
foreach($item in $fixtures.GetEnumerator()){
    Get-CachedDownload -Uri $item.Value -Destination (Join-Path $Destination $item.Key)|Out-Null
}
Get-ChildItem -LiteralPath $Destination -File -Filter 'fixture-*'|Select-Object -ExpandProperty FullName
