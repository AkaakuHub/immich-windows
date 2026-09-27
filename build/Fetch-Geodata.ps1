[CmdletBinding()]
param([Parameter(Mandatory)][string]$Destination)
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
Assert-WindowsX64
$Destination = New-CleanDirectory $Destination

$files = @{
    'admin1CodesASCII.txt' = 'https://download.geonames.org/export/dump/admin1CodesASCII.txt'
    'admin2Codes.txt' = 'https://download.geonames.org/export/dump/admin2Codes.txt'
    'countryInfo.txt' = 'https://download.geonames.org/export/dump/countryInfo.txt'
    'cities500.zip' = 'https://download.geonames.org/export/dump/cities500.zip'
    'ne_10m_admin_0_countries.geojson' = 'https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v5.1.2/geojson/ne_10m_admin_0_countries.geojson'
}
foreach ($item in $files.GetEnumerator()) {
    $out = Join-Path $Destination $item.Key
    Write-Host "Downloading $($item.Value)"
    Invoke-WebRequest -UseBasicParsing -Uri $item.Value -OutFile $out
}
Expand-Archive -LiteralPath (Join-Path $Destination 'cities500.zip') -DestinationPath $Destination -Force
Remove-Item -LiteralPath (Join-Path $Destination 'cities500.zip')
[DateTimeOffset]::UtcNow.ToString('o') | Set-Content -NoNewline -Encoding ascii -LiteralPath (Join-Path $Destination 'geodata-date.txt')
