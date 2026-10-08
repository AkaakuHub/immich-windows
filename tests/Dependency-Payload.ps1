#requires -Version 7.0
# Exercise file delivery and retries through real cache I/O; never inspect source text.
param([string]$TemporaryRoot = $env:RUNNER_TEMP)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../runtime/DependencyPayload.psm1') -Force
function Check([bool]$Value,[string]$Message) { if (-not $Value) { throw $Message } }
if (-not $TemporaryRoot) { throw 'A test temporary directory is required.' }
$base=Join-Path $TemporaryRoot ('dependency-payload-'+[guid]::NewGuid().ToString('N'))
$requests=[Collections.Generic.List[string]]::new()
$contents=@{}
$failure=$null
function Invoke-WebRequest {
 param([string]$Uri,[string]$OutFile)
 $name=$Uri.Split('/')[-1]
 $requests.Add($name)
 if ($name -eq $failure) { [IO.File]::WriteAllText($OutFile,'partial'); throw 'Interrupted download' }
 [IO.File]::WriteAllText($OutFile,[string]$contents[$name])
}
function Payload([string]$Content) {
 $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Content))).ToLowerInvariant()
 $name="dependency-$hash";$contents[$name]=$Content
 return [pscustomobject]@{assetName=$name;sha256=$hash}
}
try {
 $cache=Join-Path $base cache
 $native=Payload 'native';$wheel=Payload 'wheel'
 $first=Get-ImmichDependencyPayload $native v3.3.0.3 $cache
 Check ($requests.Count -eq 1) 'Missing file did not require exactly one request.'
 $failure=$wheel.assetName
 $failed=$false
 try { Get-ImmichDependencyPayload $wheel v3.3.0.3 $cache } catch { $failed=$true }
 Check $failed 'Interrupted download was accepted.'
 Check (-not (Test-Path (Join-Path $cache $wheel.assetName))) 'Partial content entered the cache.'
 $failure=$null
 [void](Get-ImmichDependencyPayload $native v3.3.0.3 $cache)
 $second=Get-ImmichDependencyPayload $wheel v3.3.0.3 $cache
 Check ($requests.Count -eq 3) 'Retry downloaded the already-complete file.'
 $requests.Clear()
 foreach ($payload in @($native,$wheel)) { [void](Get-ImmichDependencyPayload $payload v3.3.0.4 $cache) }
 Check ($requests.Count -eq 0) 'A new release redownloaded unchanged content.'
 Check ((Get-Content -Raw $first) -ceq 'native' -and (Get-Content -Raw $second) -ceq 'wheel') 'Payload bytes changed.'
 $local=Payload 'installed wheel'
 $installed=Join-Path $base installed.whl
 [IO.File]::WriteAllText($installed,'installed wheel')
 [void](Get-ImmichDependencyPayload $local v3.3.0.3 $cache -InstalledPath $installed)
 Check ($requests.Count -eq 0) 'Existing installed content was downloaded.'
 $bad=Payload 'expected';$contents[$bad.assetName]='wrong'
 $failed=$false
 try { Get-ImmichDependencyPayload $bad v3.3.0.3 $cache } catch { $failed=$true }
 Check ($failed -and -not (Test-Path (Join-Path $cache $bad.assetName))) 'Checksum mismatch entered the cache.'
 [IO.File]::WriteAllText($first,'corrupt cache')
 $failed=$false
 try { Get-ImmichDependencyPayload $native v3.3.0.3 $cache } catch { $failed=$true }
 Check $failed 'Corrupt cached content was adopted.'
 Write-Host 'PASS dependency delivery: missing files only, unchanged releases zero requests, retry resumes completed content, local reuse, checksum rejection.'
} finally { if (Test-Path $base) { Remove-Item -LiteralPath $base -Recurse -Force } }
