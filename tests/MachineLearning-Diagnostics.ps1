#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('immich-ml-diagnostic-' + [guid]::NewGuid().ToString('N'))
$oldActions = $env:GITHUB_ACTIONS
$oldToken = $env:IMMICH_DIAGNOSTIC_TEST_TOKEN
$oldSecret = $env:IMMICH_DIAGNOSTIC_TEST_SECRET
function Check([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
try {
    $env:GITHUB_ACTIONS = 'true'
    $env:IMMICH_DIAGNOSTIC_TEST_TOKEN = 'inherited-token-98765'
    $env:IMMICH_DIAGNOSTIC_TEST_SECRET = 'inherited-keyxx-54321'
    $logs = Join-Path $root 'logs'
    New-Item -ItemType Directory $logs -Force | Out-Null
    $secret = 'fixture password/@:123'
    Set-Content (Join-Path $root 'immich.env') "DB_PASSWORD=$secret`nIMMICH_PORT_ML=3003"
    Set-Content (Join-Path $logs 'ImmichServer-new.stderr.log') 'DO NOT CAPTURE SERVER LOGS'
    Set-Content (Join-Path $logs 'ImmichMachineLearning-old.stderr.log') 'OLD STDERR MUST NOT BE SELECTED'
    (Get-Item (Join-Path $logs 'ImmichMachineLearning-old.stderr.log')).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-1)
    Set-Content (Join-Path $logs 'ImmichMachineLearning-new.stderr.log') @(
        'Traceback (most recent call last):',
        'OSError: [WinError 10048] Address already in use',
        "secret echo $secret and $([uri]::EscapeDataString($secret))",
        "inherited echo $env:IMMICH_DIAGNOSTIC_TEST_TOKEN",
        "same-length secret echo $env:IMMICH_DIAGNOSTIC_TEST_SECRET",
        'https://user:unknown-password@example.test/path',
        'password=unknown-credential',
        '::error::untrusted child workflow command'
    )
    Set-Content (Join-Path $logs 'ImmichMachineLearning-new.stdout.log') (@('Beginning stdout marker') + (1..100 | ForEach-Object { "line $_" }))
    $output = Join-Path $root 'diagnostics.txt'
    & (Join-Path $PSScriptRoot 'actions/Write-MachineLearningDiagnostics.ps1') -InstallRoot $root -DataRoot $root -OutputPath $output 6>$null
    $actual = Get-Content -Raw $output
    foreach ($forbidden in @($secret,[uri]::EscapeDataString($secret),$env:IMMICH_DIAGNOSTIC_TEST_TOKEN,$env:IMMICH_DIAGNOSTIC_TEST_SECRET,'unknown-password','unknown-credential','::error::','OLD STDERR','SERVER LOGS','Beginning stdout marker')) {
        Check (-not $actual.Contains($forbidden)) "ML diagnostics exposed or selected forbidden content: $forbidden"
    }
    Check ($actual.Contains('WinError 10048') -and $actual.Contains('Traceback') -and $actual.Contains('line 100')) 'Diagnostic evidence was lost.'
    Check ($actual.Contains('[REDACTED]')) 'No redaction marker was emitted.'
    # Empty/missing installations should still produce useful best-effort output.
    & (Join-Path $PSScriptRoot 'actions/Write-MachineLearningDiagnostics.ps1') -InstallRoot $root -DataRoot (Join-Path $root missing) -OutputPath $output 6>$null
    Check ((Get-Content -Raw $output).Contains('No ML stderr log found.')) 'Missing logs blocked diagnostics.'
    # Exercise the lifecycle fixture's real restore block without native processes.
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'actions/Test-MachineLearningLifecycle.ps1'), [ref]$tokens, [ref]$errors)
    Check ($errors.Count -eq 0) 'Lifecycle fixture does not parse.'
    $outerTry = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })[-1]
    $restore = $outerTry.Finally.Statements[0].Finally.Extent.Text
    $restore = [scriptblock]::Create($restore.Substring(1, $restore.Length - 2))
    foreach ($leaveStopped in @($false,$true)) {
        & {
            param($LeaveStopped)
            $envFile = Join-Path $root 'lifecycle.env'
            $originalEnv = [Text.Encoding]::UTF8.GetBytes("original bytes`r`n")
            [IO.File]::WriteAllText($envFile, 'temporary fixture settings')
            $previousProcessEnv = @{}
            $launchArgs = @{}
            $start = { Set-Content (Join-Path $root 'restarted') 'yes' }
            $marker = Join-Path $root 'restarted'
            Remove-Item $marker -Force -ErrorAction SilentlyContinue
            & $restore
            Check ([Convert]::ToBase64String([IO.File]::ReadAllBytes($envFile)) -ceq [Convert]::ToBase64String($originalEnv)) 'Lifecycle fixture did not restore exact env bytes.'
            Check ((Test-Path $marker) -eq (-not $LeaveStopped)) 'Lifecycle fixture ignored LeaveStopped or changed its default restart behavior.'
        } $leaveStopped
    }
    Write-Host 'ML diagnostics passed: bounded latest-log selection, redaction, command neutralization and missing logs.'
    Write-Host 'ML lifecycle fixture passed: exact env restoration, default restart and LeaveStopped cleanup.'
} finally {
    $env:GITHUB_ACTIONS = $oldActions
    $env:IMMICH_DIAGNOSTIC_TEST_TOKEN = $oldToken
    $env:IMMICH_DIAGNOSTIC_TEST_SECRET = $oldSecret
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
