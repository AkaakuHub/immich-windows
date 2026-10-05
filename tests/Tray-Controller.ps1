#requires -Version 5.1
<#
.SYNOPSIS
Tests a compiled .NET Framework tray controller without starting Immich or a resident tray.
.EXAMPLE
powershell.exe -NoProfile -File tests\Tray-Controller.ps1 -Executable build\ImmichTray.exe -IconPath build\www\favicon.ico
.NOTES
Run with Windows PowerShell 5.1. IconPath must be the real upstream favicon, not a dummy ICO.
No repository module is imported. Management commands run only inert, temporary fixture scripts;
Read-Host is replaced with a recorded Enter response. No UAC or browser action is performed.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Executable,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$IconPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or $PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'Run Tray-Controller.ps1 with Windows PowerShell 5.1 on Windows.'
}
$Executable = (Resolve-Path -LiteralPath $Executable).ProviderPath
$IconPath = (Resolve-Path -LiteralPath $IconPath).ProviderPath
if (-not [IO.File]::Exists($Executable) -or -not [IO.File]::Exists($IconPath)) {
    throw 'Executable and IconPath must name existing files.'
}

$script:AssertCount = 0
$script:ProcessCount = 0
$base = Join-Path ([IO.Path]::GetTempPath()) ('immich-tray-tests-' + [guid]::NewGuid().ToString('N'))
$utf8 = New-Object Text.UTF8Encoding($true)

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ('Tray contract: ' + $Message) }
    $script:AssertCount++
}
function Assert-Equal($Actual, $Expected, [string]$Message) {
    Assert-True ($Actual -ceq $Expected) ($Message + " (expected '$Expected'; actual '$Actual')")
}
function Assert-Throws([scriptblock]$Action, [type]$ExceptionType, [string]$Message) {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_.Exception }
    while ($null -ne $caught -and $null -ne $caught.InnerException) { $caught = $caught.InnerException }
    Assert-True ($null -ne $caught) ($Message + ': did not throw')
    Assert-True ($ExceptionType.IsInstanceOfType($caught)) ($Message + ': unexpected exception type')
    return $caught
}
function Write-Fixture([string]$Path, [string]$Content) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    [IO.File]::WriteAllText($Path, $Content, $utf8)
}
function Quote-PowerShell([string]$Value) { return "'" + $Value.Replace("'", "''") + "'" }
function Parse-Command([string]$Command, [string]$Label) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Command, [ref]$tokens, [ref]$errors)
    Assert-Equal $errors.Count 0 ($Label + ' must parse under Windows PowerShell 5.1')
    return $ast
}
function Find-Command($Ast, [string]$Name) {
    return @($Ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq $Name
    }, $true))
}
function Assert-CommandParameter($Command, [string]$Name, [string]$Value, [string]$Label) {
    $elements = $Command.CommandElements
    $found = $false
    for ($i = 1; $i -lt ($elements.Count - 1); $i++) {
        if ($elements[$i] -is [Management.Automation.Language.CommandParameterAst] -and $elements[$i].ParameterName -ceq $Name) {
            Assert-True ($elements[$i + 1] -is [Management.Automation.Language.StringConstantExpressionAst]) ($Label + ': ' + $Name + ' must be a literal')
            Assert-Equal $elements[$i + 1].Value $Value ($Label + ': ' + $Name + ' round-trip')
            $found = $true
        }
    }
    Assert-True $found ($Label + ': missing parameter ' + $Name)
}
function Invoke-TestProcess([string]$FilePath, [string[]]$Arguments, [string]$Label) {
    $script:ProcessCount++
    $stdout = Join-Path $base ("process-$script:ProcessCount.stdout.txt")
    $stderr = Join-Path $base ("process-$script:ProcessCount.stderr.txt")
    # Start-Process joins ArgumentList with spaces. These fixture arguments contain no double
    # quotes or trailing slashes; quote independently of the controller's quoting helper.
    $argumentLine = ($Arguments | ForEach-Object {
        if ($_.Contains('"') -or $_.EndsWith('\')) { throw 'Unexpected native fixture argument.' }
        '"' + $_ + '"'
    }) -join ' '
    $process = Start-Process -FilePath $FilePath -ArgumentList $argumentLine -WorkingDirectory $base -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    try {
        Assert-True $process.HasExited ($Label + ': process did not finish')
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout = [IO.File]::ReadAllText($stdout)
            Stderr = [IO.File]::ReadAllText($stderr)
        }
    } finally { $process.Dispose() }
}

try {
    [IO.Directory]::CreateDirectory($base) | Out-Null
    # Quotes, metacharacters and Unicode must remain data in both CLI and PowerShell commands.
    $installRoot = Join-Path $base "Immich 日本語's `$dollar; space"
    $dataRoot = Join-Path $base "Data 写真's (private)"
    $fakePowerShell = Join-Path $base "PowerShell 実行's space\pwsh.exe"
    $currentRoot = Join-Path $installRoot 'current'
    $commonPath = Join-Path $currentRoot 'runtime\Common.psm1'
    $startPath = Join-Path $currentRoot 'runtime\launchers\Start-Immich.ps1'
    $stopPath = Join-Path $currentRoot 'runtime\launchers\Stop-Immich.ps1'
    $updatePath = Join-Path $currentRoot 'installer\Update-FromRelease.ps1'
    $envFile = Join-Path $dataRoot 'immich.env'
    $fixtureIcon = Join-Path $currentRoot 'build\www\favicon.ico'
    $inertScript = "param(`$InstallRoot, `$DataRoot, `$EnvFile, `$Scope, [switch]`$Interactive, `$Language)`r`nthrow 'Fixture actions must not run during --check.'"
    foreach ($path in @($commonPath, $startPath, $stopPath, $updatePath)) { Write-Fixture $path $inertScript }
    Write-Fixture $envFile "IMMICH_PORT=2283`r`nDB_PASSWORD=fixture-secret-must-not-leak"
    Write-Fixture $fakePowerShell 'This is deliberately not an executable.'
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fixtureIcon)) | Out-Null
    [IO.File]::Copy($IconPath, $fixtureIcon)
    $iconBytes = [IO.File]::ReadAllBytes($fixtureIcon)
    Assert-True ($iconBytes.Length -gt 6 -and $iconBytes[0] -eq 0 -and $iconBytes[1] -eq 0 -and $iconBytes[2] -eq 1 -and $iconBytes[3] -eq 0) 'IconPath must contain a real ICO resource'

    [Reflection.Assembly]::LoadFrom($Executable) | Out-Null
    $validArguments = [string[]]@('--install-root', $installRoot, '--data-root', $dataRoot, '--scope', 'CurrentUser', '--powershell-path', $fakePowerShell)
    $options = [Immich.Windows.TrayOptions]::Parse($validArguments)
    Assert-Equal $options.InstallRoot $installRoot 'CLI install root'
    Assert-Equal $options.DataRoot $dataRoot 'CLI data root'
    Assert-Equal $options.PowerShellPath $fakePowerShell 'CLI PowerShell path'
    Assert-Equal $options.Scope 'CurrentUser' 'CLI scope'
    Assert-Equal $options.CurrentRoot $currentRoot 'Canonical current release'
    Assert-Equal $options.EnvFile $envFile 'Configured env file'
    Assert-Equal $options.IconPath $fixtureIcon 'Upstream favicon location'
    Assert-True (-not $options.Check -and -not $options.ExitExisting) 'Normal parsing unexpectedly selected a control mode'
    $options.ValidateFiles()
    Assert-True $true 'Complete fixture validates'
    $checkOptions = [Immich.Windows.TrayOptions]::Parse([string[]]($validArguments + '--check'))
    Assert-True $checkOptions.Check '--check flag'
    $exitOptions = [Immich.Windows.TrayOptions]::Parse([string[]]@('--install-root', $installRoot, '--exit-existing'))
    Assert-True ($exitOptions.ExitExisting -and -not $exitOptions.Check) 'Exit-existing requires only the install root'

    $invalidCases = @(
        @{ Name = 'no arguments'; Arguments = [string[]]@() },
        @{ Name = 'unknown option'; Arguments = [string[]]($validArguments + '--unknown') },
        @{ Name = 'wrong option case'; Arguments = [string[]]($validArguments + '--CHECK') },
        @{ Name = 'bare value'; Arguments = [string[]]($validArguments + 'surplus') },
        @{ Name = 'missing install root'; Arguments = [string[]]$validArguments[2..7] },
        @{ Name = 'missing data root'; Arguments = [string[]]($validArguments[0..1] + $validArguments[4..7]) },
        @{ Name = 'missing scope'; Arguments = [string[]]($validArguments[0..3] + $validArguments[6..7]) },
        @{ Name = 'missing PowerShell path'; Arguments = [string[]]$validArguments[0..5] },
        @{ Name = 'duplicate check'; Arguments = [string[]]($validArguments + @('--check', '--check')) },
        @{ Name = 'duplicate exit'; Arguments = [string[]]@('--install-root', $installRoot, '--exit-existing', '--exit-existing') },
        @{ Name = 'incompatible modes'; Arguments = [string[]]($validArguments + @('--check', '--exit-existing')) },
        @{ Name = 'exit without root'; Arguments = [string[]]@('--exit-existing') }
    )
    foreach ($index in @(0, 2, 4, 6)) {
        $name = $validArguments[$index]
        $invalidCases += @{ Name = 'duplicate ' + $name; Arguments = [string[]]($validArguments + @($name, $validArguments[$index + 1])) }
        $invalidCases += @{ Name = 'incomplete ' + $name; Arguments = [string[]]@($name) }
        $invalidCases += @{ Name = 'blank ' + $name; Arguments = [string[]]@($name, ' ') }
    }
    foreach ($index in @(0, 2, 6)) {
        $argsCopy = [string[]]$validArguments.Clone()
        $argsCopy[$index + 1] = 'relative\path'
        $invalidCases += @{ Name = 'relative ' + $validArguments[$index]; Arguments = $argsCopy }
    }
    foreach ($scope in @('allusers', 'currentuser', 'Machine', '')) {
        $argsCopy = [string[]]$validArguments.Clone()
        $argsCopy[5] = $scope
        $invalidCases += @{ Name = "invalid scope '$scope'"; Arguments = $argsCopy }
    }
    foreach ($case in $invalidCases) {
        $null = Assert-Throws { [Immich.Windows.TrayOptions]::Parse($case.Arguments) } ([ArgumentException]) $case.Name
    }

    $english = [Immich.Windows.TrayText]::ForCulture('en-US')
    $japanese = [Immich.Windows.TrayText]::ForCulture('ja-JP')
    $expectedEnglish = @{ Open = 'Open Immich'; OpenConfigFolder = 'Open configuration folder'; Start = 'Start Immich'; Stop = 'Stop Immich'; Update = 'Update Immich'; Exit = 'Exit tray (keep server running)'; Continue = 'Press Enter to close' }
    $expectedJapanese = @{ Open = 'Immichを開く'; OpenConfigFolder = '設定フォルダーを開く'; Start = 'Immichを起動'; Stop = 'Immichを停止'; Update = 'Immichを更新'; Exit = 'トレイを終了（サーバーは停止しません）'; Continue = 'Enterキーを押して閉じます' }
    foreach ($field in $expectedEnglish.Keys) { Assert-Equal $english.$field $expectedEnglish[$field] ("English $field") }
    foreach ($field in $expectedJapanese.Keys) { Assert-Equal $japanese.$field $expectedJapanese[$field] ("Japanese $field") }
    $textFields = @('Open', 'OpenConfigFolder', 'Start', 'Stop', 'Update', 'Exit', 'Busy', 'Failed', 'Cancelled', 'Continue', 'NotElevated', 'Started', 'Stopped', 'Updated', 'Language', 'Status', 'Running', 'NotRunning', 'Partial', 'Changing', 'Unknown')
    foreach ($culture in @('ja_JP', 'JA-jp', 'ja')) {
        $text = [Immich.Windows.TrayText]::ForCulture($culture)
        foreach ($field in $textFields) { Assert-Equal $text.$field $japanese.$field ("Japanese culture $culture / $field") }
    }
    foreach ($culture in @('en_US', 'en-GB', 'fr-FR', 'de-DE', 'unknown-language', '', $null)) {
        $text = [Immich.Windows.TrayText]::ForCulture($culture)
        foreach ($field in $textFields) { Assert-Equal $text.$field $english.$field ("English fallback $culture / $field") }
    }
    foreach ($field in $textFields) {
        Assert-True (-not [string]::IsNullOrWhiteSpace($english.$field)) ("Missing English $field")
        Assert-True (-not [string]::IsNullOrWhiteSpace($japanese.$field)) ("Missing Japanese $field")
    }

    foreach ($text in @($english, $japanese)) {
        foreach ($state in @('Running','Partial','Changing','Unknown')) {
            Assert-Equal $text.RuntimeStatus($state) $text.$state ("Localized runtime state $state")
        }
        Assert-Equal $text.RuntimeStatus('Stopped') $text.NotRunning 'Localized stopped state'
        foreach ($state in @('', $null, 'unexpected output', 'Running Stopped')) {
            Assert-Equal $text.RuntimeStatus($state) $text.Unknown 'Malformed status output stays unknown'
        }
    }
    Assert-Equal $japanese.Running '稼働中' 'Japanese running state'
    Assert-Equal $japanese.NotRunning '停止中' 'Japanese stopped state'
    Assert-Equal $japanese.Unknown '確認できません' 'Japanese unknown state'

    foreach ($scope in @('CurrentUser', 'AllUsers')) {
        $options.Scope = $scope
        foreach ($text in @($english, $japanese)) {
            $statusCommand = [Immich.Windows.TrayCommands]::BuildCommand($options, 'status', $text)
            $statusAst = Parse-Command $statusCommand "$scope / status"
            $statusInfo = [Immich.Windows.TrayCommands]::BuildStartInfo($options, 'status', $text)
            Assert-Equal $statusInfo.FileName $fakePowerShell 'Status reuses the configured PowerShell'
            Assert-True (-not $statusInfo.UseShellExecute -and $statusInfo.Verb -ne 'runas') 'Status never elevates, including AllUsers'
            Assert-True ($statusInfo.CreateNoWindow -and $statusInfo.RedirectStandardOutput -and $statusInfo.RedirectStandardError) 'Status uses an isolated quiet query'
            Assert-Equal @(Find-Command $statusAst 'Read-Host').Count 0 'Status never waits for interactive input'
            $statusCalls = @(Find-Command $statusAst 'Get-ImmichUserProcessSnapshot')
            Assert-Equal $statusCalls.Count 1 'Status uses the shared detection helper once'
            Assert-CommandParameter $statusCalls[0] 'InstallRoot' $installRoot 'Status'
            Assert-CommandParameter $statusCalls[0] 'DataRoot' $dataRoot 'Status'
            Assert-Equal @($statusCalls[0].CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'Scope' }).Count 0 'Process snapshot does not accept a Scope parameter'
            Assert-True (-not $statusCommand.Contains('immich.env')) 'Status does not require private env access'
            Assert-True $statusCommand.Contains('-DisableNameChecking') 'Import warnings cannot corrupt the status token'
            # Resolve only the active env's parent. The second installation has no env to read.
            foreach ($folderRoot in @($dataRoot, (Join-Path $base "Other 設定's `$dollar; [custom]"))) {
                $folderArguments = [string[]]$validArguments.Clone()
                $folderArguments[3] = $folderRoot; $folderArguments[5] = $scope
                $folderOptions = [Immich.Windows.TrayOptions]::Parse($folderArguments)
                $folderInfo = [Immich.Windows.TrayCommands]::BuildStartInfo($folderOptions, 'open-config-folder', $text)
                $label = "$scope / open-config-folder / $($text.OpenConfigFolder)"
                Assert-Equal $folderInfo.FileName ([IO.Path]::GetDirectoryName($folderOptions.EnvFile)) ($label + ': active env parent')
                Assert-Equal $folderInfo.FileName $folderRoot ($label + ': installation-specific data directory')
                Assert-True $folderInfo.UseShellExecute ($label + ': direct Windows shell open')
                Assert-Equal $folderInfo.Verb 'open' ($label + ': folder action must never request elevation')
                Assert-Equal $folderInfo.Arguments '' ($label + ': path stays literal, without a command interpreter')
                Assert-True (-not $folderInfo.RedirectStandardOutput -and -not $folderInfo.RedirectStandardError) ($label + ': no redirected process to drain')
            }
            foreach ($action in @('open', 'start', 'stop', 'update')) {
                $label = "$scope / $action / $($text.Open)"
                $command = [Immich.Windows.TrayCommands]::BuildCommand($options, $action, $text)
                $ast = Parse-Command $command $label
                $info = [Immich.Windows.TrayCommands]::BuildStartInfo($options, $action, $text)
                Assert-Equal $info.FileName $fakePowerShell ($label + ': configured PowerShell')
                Assert-Equal $info.WorkingDirectory $installRoot ($label + ': install working directory')
                Assert-True ($info.Arguments -cmatch '^-NoLogo -NoProfile -EncodedCommand ([A-Za-z0-9+/=]+)$') ($label + ': isolated encoded command arguments')
                $decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1]))
                Assert-Equal $decoded $command ($label + ': UTF-16 command round-trip')
                Assert-True ($command.Contains("`$ErrorActionPreference='Stop'")) ($label + ': terminating errors')
                Assert-True ($command.Contains('$global:LASTEXITCODE=0')) ($label + ': initialized native exit status')
                Assert-True ($command.Contains('$LASTEXITCODE -ne 0')) ($label + ': native failure propagation')
                Assert-True ($command.Contains('exit 0')) ($label + ': explicit successful exit')
                Assert-True ($command.Contains('exit 1')) ($label + ': explicit failed exit')
                if ($action -eq 'open') {
                    Assert-True (-not $info.UseShellExecute -and $info.Verb -ne 'runas') ($label + ': browser action must never elevate')
                    Assert-True ($info.CreateNoWindow -and $info.RedirectStandardOutput -and $info.RedirectStandardError) ($label + ': quiet browser launch with captured errors')
                    $imports = @(Find-Command $ast 'Import-Module')
                    Assert-Equal $imports.Count 1 ($label + ': shared Common module')
                    Assert-Equal $imports[0].CommandElements[1].Value $commonPath ($label + ': current Common module path')
                    $urls = @(Find-Command $ast 'Get-ImmichLocalUrl')
                    Assert-Equal $urls.Count 1 ($label + ': shared local-URL helper')
                    Assert-CommandParameter $urls[0] 'EnvFile' $envFile $label
                    Assert-CommandParameter $urls[0] 'InstallRoot' $installRoot $label
                    Assert-Equal @(Find-Command $ast 'Start-Process').Count 1 ($label + ': opens resolved URL')
                    Assert-True (-not $command.Contains('http://') -and -not $command.Contains('https://')) ($label + ': URL must not be hard-coded')
                    Assert-True ($command.Contains('[Console]::Error.WriteLine')) ($label + ': browser errors captured')
                    Assert-Equal @(Find-Command $ast 'Read-Host').Count 0 ($label + ': hidden browser action cannot wait for console input')
                } else {
                    Assert-True ($info.UseShellExecute -and -not $info.CreateNoWindow) ($label + ': visible management console')
                    Assert-Equal $info.WindowStyle ([Diagnostics.ProcessWindowStyle]::Normal) ($label + ': normal console window')
                    Assert-True (-not $info.RedirectStandardOutput -and -not $info.RedirectStandardError) ($label + ': output stays in console')
                    if ($scope -eq 'AllUsers') { Assert-True ($info.Verb -ieq 'runas') ($label + ': AllUsers requests elevation') }
                    else { Assert-Equal $info.Verb '' ($label + ': CurrentUser must not elevate') }
                    $scriptPath = switch ($action) { 'start' { $startPath } 'stop' { $stopPath } 'update' { $updatePath } }
                    $invocations = @(Find-Command $ast $scriptPath)
                    Assert-Equal $invocations.Count 1 ($label + ': exact current launcher/installer path')
                    Assert-Equal $invocations[0].InvocationOperator ([Management.Automation.Language.TokenKind]::Ampersand) ($label + ': script invocation')
                    Assert-CommandParameter $invocations[0] 'InstallRoot' $installRoot $label
                    Assert-CommandParameter $invocations[0] 'DataRoot' $dataRoot $label
                    if ($action -eq 'update') {
                        Assert-CommandParameter $invocations[0] 'Scope' $scope $label
                        Assert-CommandParameter $invocations[0] 'Language' $text.Language $label
                        Assert-True ($command.Contains(' -Interactive ')) ($label + ': updater retains shell result until Enter')
                        Assert-True ($command.Contains('if ($LASTEXITCODE -in @(10,20)) { exit $LASTEXITCODE }')) ($label + ': latest and acknowledged-failure outcomes remain distinct')
                    }
                    else { Assert-CommandParameter $invocations[0] 'EnvFile' $envFile $label }
                    $display = @(Find-Command $ast 'Write-Host')
                    $pause = @(Find-Command $ast 'Read-Host')
                    Assert-Equal $display.Count 1 ($label + ': displays failure')
                    Assert-Equal $pause.Count 1 ($label + ': retains failure until Enter')
                    Assert-Equal $pause[0].CommandElements[1].Value $text.Continue ($label + ': localized failure prompt')
                    Assert-True ($display[0].Extent.StartOffset -lt $pause[0].Extent.StartOffset) ($label + ': error appears before prompt')
                    Assert-True ($command.LastIndexOf('exit 1') -gt $pause[0].Extent.StartOffset) ($label + ': failure returned after Enter')
                    Assert-True (-not $info.Arguments.Contains('-NoExit')) ($label + ': successful actions do not leave shells resident')
                }
            }
        }
    }
    $options.Scope = 'CurrentUser'
    $null = Assert-Throws { [Immich.Windows.TrayCommands]::BuildCommand($options, 'invalid', $english) } ([ArgumentException]) 'Unknown action'
    $null = Assert-Throws { [Immich.Windows.TrayCommands]::BuildStartInfo($options, 'START', $english) } ([ArgumentException]) 'Action case validation'

    foreach ($case in @(
        @{Value=1;Expected='Stopped'}, @{Value=2;Expected='Changing'}, @{Value=3;Expected='Changing'},
        @{Value=4;Expected='Running'}, @{Value=5;Expected='Changing'}, @{Value=6;Expected='Changing'},
        @{Value=7;Expected='Partial'}, @{Value=0;Expected='Unknown'}, @{Value=99;Expected='Unknown'}
    )) {
        Assert-Equal ([Immich.Windows.RuntimeStatus]::ServiceState($case.Value)) $case.Expected 'SCM state mapping'
    }
    foreach ($case in @(
        @{First='Running';Second='Running';Expected='Running'}, @{First='Stopped';Second='Stopped';Expected='Stopped'},
        @{First='Running';Second='Stopped';Expected='Partial'}, @{First='Changing';Second='Running';Expected='Changing'},
        @{First='Unknown';Second='Stopped';Expected='Unknown'}, @{First='Running';Second='Unknown';Expected='Unknown'},
        @{First='Stopped';Second='Running';Expected='Partial'}, @{First='Partial';Second='Running';Expected='Partial'},
        @{First='Stopped';Second='Changing';Expected='Changing'}, @{First='Changing';Second='Unknown';Expected='Unknown'},
        @{First='Unknown';Second='Changing';Expected='Unknown'}, @{First='Partial';Second='Partial';Expected='Partial'}
    )) {
        Assert-Equal ([Immich.Windows.RuntimeStatus]::Combine($case.First,$case.Second)) $case.Expected 'Combined Server/ML state'
    }
    $identities=[Immich.Windows.ProcessSnapshot]::Parse("123:638712864000000001`n456:638712864000000002")
    Assert-Equal $identities.Count 2 'Snapshot has exactly two component identities'
    Assert-Equal $identities[0].State 'Running' 'Server identity marks the process running'
    Assert-Equal $identities[1].State 'Running' 'ML identity marks the process running'
    Assert-Equal $identities[0].Id 123 'Snapshot process ID'
    Assert-Equal $identities[1].Id 456 'Snapshot ML process ID'
    Assert-Equal $identities[0].Started ([long]638712864000000001) 'Creation ticks never round through a JSON number'
    Assert-Equal $identities[1].Started ([long]638712864000000002) 'Creation ticks remain distinct'
    foreach ($output in @($null, '', 'Running', "Stopped`nStopped`nStopped", "-1:123`nUnknown", "0:123`nUnknown", "123:0`nUnknown", "123:-1`nUnknown", "2147483648:123`nUnknown", "123:9223372036854775808`nUnknown", "+123:123`nUnknown", "123:1.5`nUnknown", "123:1:2`nUnknown", "garbage`nUnknown")) {
        $identities=[Immich.Windows.ProcessSnapshot]::Parse($output)
        Assert-Equal $identities.Count 2 'Malformed protocol still returns two safe component states'
        Assert-Equal $identities[0].State 'Unknown' 'Invalid identity protocol stays unknown'
        Assert-Equal $identities[1].State 'Unknown' 'Malformed protocol cannot silently mark ML running'
    }
    $identities=[Immich.Windows.ProcessSnapshot]::Parse("Stopped`nUnknown")
    Assert-Equal $identities[0].State 'Stopped' 'Explicit stopped identity'
    Assert-Equal $identities[1].State 'Unknown' 'Explicit inaccessible identity'
    $identities=[Immich.Windows.ProcessSnapshot]::Parse("Stopped`r`n456:638712864000000002`r`n")
    Assert-Equal $identities[0].State 'Stopped' 'Windows line endings preserve stopped component'
    Assert-Equal $identities[1].State 'Running' 'Windows line endings preserve running component'
    Assert-Equal $identities[1].Started ([long]638712864000000002) 'Windows line endings preserve exact creation ticks'

    # Reflectively construct the real context without publishing an icon or subscribing to OS events.
    $contextType=[Immich.Windows.TrayOptions].Assembly.GetType('Immich.Windows.TrayContext', $true)
    $flags=[Reflection.BindingFlags]'Instance,NonPublic'
    $context=[Activator]::CreateInstance($contextType,[object[]]@($options,$japanese,$null,$false))
    try {
        $statusItem=$contextType.GetField('statusItem',$flags).GetValue($context)
        Assert-True (-not $statusItem.Enabled) 'Status row cannot dispatch an action'
        Assert-Equal $statusItem.Text ($japanese.Status+$japanese.Unknown) 'Status starts unknown'
        Assert-True ($null -eq $contextType.GetField('runtimeMonitor',$flags).GetValue($context)) '--check has no OS subscriptions or query process'
    } finally { $context.Dispose() }

    # Exercise publication/error fencing without Start(), watchers, services, or a child shell.
    $monitorType=[Immich.Windows.TrayOptions].Assembly.GetType('Immich.Windows.RuntimeMonitor', $true)
    $monitor=[Activator]::CreateInstance($monitorType,[object[]]@($options,$english,[Action[string]]{ param($state) }))
    try {
        $states=$monitorType.GetField('states',$flags).GetValue($monitor)
        $states[0]='Stopped'; $states[1]='Stopped'
        $monitorType.GetField('published',$flags).SetValue($monitor,'Running')
        $null=$monitorType.GetMethod('Publish',$flags).Invoke($monitor,@())
        Assert-Equal $monitorType.GetField('published',$flags).GetValue($monitor) 'Unknown' 'Lost file watcher cannot publish stopped from old exit callbacks'
        $monitorType.GetField('userMonitoring',$flags).SetValue($monitor,$true)
        $null=$monitorType.GetMethod('Publish',$flags).Invoke($monitor,@())
        Assert-Equal $monitorType.GetField('published',$flags).GetValue($monitor) 'Stopped' 'Working watcher permits a stopped state'
        $observed=$monitorType.GetField('processes',$flags).GetValue($monitor)
        $observed[0]=[Diagnostics.Process]::GetCurrentProcess()
        $unknown=[Immich.Windows.ProcessSnapshot]::new()
        $null=$monitorType.GetMethod('AttachProcess',$flags).Invoke($monitor,[object[]]@(0,$unknown))
        Assert-True ($null -eq $observed[0]) 'An unknown replacement identity detaches the old process callback'
        Assert-Equal $states[0] 'Unknown' 'A failed replacement identity cannot remain running or become stopped'
    } finally { $monitor.Dispose() }

    # Exercise the production snapshot and ownership functions against inert OS adapters.
    # Extract only these PS5-compatible helpers, without importing the PS7 runtime module.
    $tokens = $null; $errors = $null
    $commonAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\runtime\Common.psm1'), [ref]$tokens, [ref]$errors)
    $statusFunctions = @('Get-ImmichUserProcess','Get-ImmichUserProcessSnapshot') | ForEach-Object {
        $name = $_
        $function = $commonAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        Assert-True ($null -ne $function) ("Production status helper $name exists")
        $function.Extent.Text
    }
    $statusFixture = @'
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script:Values=@{}
function Get-Content {
    [CmdletBinding()] param($LiteralPath,[switch]$Raw)
    if (-not $LiteralPath.EndsWith('.pid')) { throw 'Status must not read env or unrelated files.' }
    $script:Reads++
    $name=[IO.Path]::GetFileNameWithoutExtension($LiteralPath)
    $value=$script:Values[$name]
    if ($null -eq $value) { throw [Management.Automation.ItemNotFoundException]::new('Absent PID') }
    if ($value -eq 'Unreadable') { throw [UnauthorizedAccessException]::new('Private PID') }
    if ($value -eq 'Malformed') { return 'invalid-pid' }
    if ($value -eq 'Negative') { return '-1' }
    if ($value -eq 'Zero') { return '0' }
    if ($value -eq 'Empty') { return '' }
    if ($name -eq 'ImmichServer') { return '123' }; return '456'
}
function Get-Process {
    [CmdletBinding()] param($Id)
    $name=if ($Id -eq 123) { 'ImmichServer' } else { 'ImmichMachineLearning' }
    $value=$script:Values[$name]
    if ($value -eq 'Denied') { throw [UnauthorizedAccessException]::new('Query denied') }
    if ($value -eq 'Stale') {
        $queryError=[Management.Automation.ErrorRecord]::new([ArgumentException]::new('No process'),'NoProcessFoundForGivenId',[Management.Automation.ErrorCategory]::ObjectNotFound,$Id)
        $PSCmdlet.ThrowTerminatingError($queryError)
    }
    $path=Join-Path $script:Root 'current\runtime\node\node.exe'
    if ($value -eq 'Release') { $path=Join-Path $script:Root 'releases\test\runtime\node\node.exe' }
    if ($value -eq 'Foreign') { $path=Join-Path ($script:Root+'-other') 'current\runtime\node\node.exe' }
    if ($value -eq 'NoIdentity') { $path='' }
    $process=[pscustomobject]@{ Id=$Id; Handle=1; StartTime=[DateTime]::SpecifyKind([DateTime]'2025-01-01',[DateTimeKind]::Utc); Path=$path; HasExited=($value -eq 'Exited') }
    if ($value -eq 'HandleDenied') { $process | Add-Member -MemberType ScriptProperty -Name Handle -Value { throw [UnauthorizedAccessException]::new('Handle denied') } -Force }
    if ($value -eq 'StartTimeDenied') { $process | Add-Member -MemberType ScriptProperty -Name StartTime -Value { throw [UnauthorizedAccessException]::new('Start time denied') } -Force }
    $process|Add-Member ScriptMethod Dispose { $script:Disposed++ }
    return $process
}
function Get-CurrentReleaseTarget { param($InstallRoot) return Join-Path $InstallRoot 'releases\test' }
function Snapshot($InstallRoot,$DataRoot,$Server,$ML) {
    $script:Root=$InstallRoot; $script:Reads=0; $script:Disposed=0; $script:Values=@{}
    if ($null -ne $Server) { $script:Values.ImmichServer=$Server }
    if ($null -ne $ML) { $script:Values.ImmichMachineLearning=$ML }
    $result=@(Get-ImmichUserProcessSnapshot -InstallRoot $InstallRoot -DataRoot $DataRoot)
    $parsed=[Immich.Windows.ProcessSnapshot]::Parse(($result -join "`n"))
    $state=[Immich.Windows.RuntimeStatus]::Combine($parsed[0].State,$parsed[1].State)
    return [pscustomobject]@{State=$state;Reads=$script:Reads;Disposed=$script:Disposed;Lines=$result}
}
'@
    $statusModule = New-Module -ScriptBlock ([scriptblock]::Create(($statusFunctions -join "`n") + "`n" + $statusFixture))
    $startedTicks=[DateTime]::SpecifyKind([DateTime]'2025-01-01',[DateTimeKind]::Utc).Ticks.ToString([Globalization.CultureInfo]::InvariantCulture)
    $statusCases = @(
        @{Server='Running'; ML='Release'; Expected='Running'; Tokens=@(('123:'+$startedTicks),('456:'+$startedTicks))},
        @{Server='Running'; ML=$null; Expected='Partial'; Tokens=@(('123:'+$startedTicks),'Stopped')},
        @{Server=$null; ML=$null; Expected='Stopped'; Tokens=@('Stopped','Stopped')},
        @{Server='Exited'; ML='Stale'; Expected='Stopped'; Tokens=@('Stopped','Stopped')},
        @{Server='Foreign'; ML=$null; Expected='Stopped'; Tokens=@('Stopped','Stopped')},
        @{Server='NoIdentity'; ML=$null; Expected='Unknown'; Tokens=@('Unknown','Stopped')},
        @{Server='Denied'; ML=$null; Expected='Unknown'; Tokens=@('Unknown','Stopped')},
        @{Server='HandleDenied'; ML=$null; Expected='Unknown'; Tokens=@('Unknown','Stopped')},
        @{Server='StartTimeDenied'; ML=$null; Expected='Unknown'; Tokens=@('Unknown','Stopped')},
        @{Server='Unreadable'; ML=$null; Expected='Unknown'; Tokens=@('Unknown','Stopped')},
        @{Server='Malformed'; ML=$null; Expected='Unknown'; Tokens=@('Unknown','Stopped')},
        @{Server='Negative'; ML=$null; Expected='Unknown'; Tokens=@('Unknown','Stopped')},
        @{Server='Zero'; ML=$null; Expected='Unknown'; Tokens=@('Unknown','Stopped')},
        @{Server='Empty'; ML=$null; Expected='Unknown'; Tokens=@('Unknown','Stopped')}
    )
    foreach ($case in $statusCases) {
        $snapshot = & $statusModule { param($root,$data,$case) Snapshot $root $data $case.Server $case.ML } $installRoot $dataRoot $case
        $label="Snapshot CurrentUser: $($case.Server) / $($case.ML)"
        Assert-Equal $snapshot.State $case.Expected $label
        Assert-Equal $snapshot.Reads 2 ($label+': reads only the two managed PID files')
        Assert-Equal $snapshot.Lines.Count 2 ($label+': emits exactly two protocol lines')
        Assert-Equal $snapshot.Lines[0] $case.Tokens[0] ($label+': exact Server token')
        Assert-Equal $snapshot.Lines[1] $case.Tokens[1] ($label+': exact ML token')
        if ($case.Expected -eq 'Running') { Assert-Equal $snapshot.Disposed 2 'Snapshot disposes both inspected OS objects' }
    }

    $sid = 'S-1-5-21-111-222-333-1001'
    $key = [Immich.Windows.ImmichTray]::InstanceName($installRoot, $sid, 17)
    Assert-True ($key -cmatch '^Local\\ImmichTray-[0-9A-F]{64}$') 'Singleton uses a local, hashed key'
    foreach ($equivalent in @($installRoot.ToUpperInvariant(), $installRoot.ToLowerInvariant(), ($installRoot + '\'), ($installRoot + '/'), (Join-Path $installRoot '.\child\..'))) {
        Assert-Equal ([Immich.Windows.ImmichTray]::InstanceName($equivalent, $sid, 17)) $key 'Singleton normalizes equivalent install paths'
    }
    Assert-True ([Immich.Windows.ImmichTray]::InstanceName((Join-Path $base 'different-install'), $sid, 17) -cne $key) 'Different installations must not share a singleton'
    Assert-True ([Immich.Windows.ImmichTray]::InstanceName($installRoot, 'S-1-5-21-111-222-333-1002', 17) -cne $key) 'Different user SIDs must not share a singleton'
    Assert-True ([Immich.Windows.ImmichTray]::InstanceName($installRoot, $sid, 18) -cne $key) 'Different sessions must not share a singleton'
    Assert-Equal ([Immich.Windows.ImmichTray]::QuoteArgument('')) '""' 'Native quoting: empty argument'
    Assert-Equal ([Immich.Windows.ImmichTray]::QuoteArgument($installRoot)) ('"' + $installRoot + '"') 'Native quoting: Unicode, spaces and apostrophe'
    Assert-Equal ([Immich.Windows.ImmichTray]::QuoteArgument('C:\space here\')) '"C:\space here\\"' 'Native quoting: trailing slash'
    Assert-Equal ([Immich.Windows.ImmichTray]::QuoteArgument('a"b')) '"a\"b"' 'Native quoting: embedded quote'

    # These are actual compiled WinForms entry-point checks, not a substitute C# fixture.
    # A bogus pwsh.exe and throwing scripts prove --check never dispatches an action.
    foreach ($scope in @('CurrentUser', 'AllUsers')) {
        $checkArguments = [string[]]$validArguments.Clone(); $checkArguments[5] = $scope
        $result = Invoke-TestProcess $Executable ($checkArguments + '--check') ("--check $scope")
        Assert-Equal $result.ExitCode 0 ("--check $scope constructs icon/menu and exits")
        Assert-Equal $result.Stderr '' ("--check $scope should not report errors")
    }
    foreach ($path in @($fakePowerShell, $fixtureIcon, $commonPath, $startPath, $stopPath, $updatePath)) {
        $saved = $path + '.held-for-test'
        [IO.File]::Move($path, $saved)
        try {
            $missing = Assert-Throws { $options.ValidateFiles() } ([IO.FileNotFoundException]) ('Missing ' + [IO.Path]::GetFileName($path))
            Assert-Equal $missing.FileName $path 'Missing-file exception identifies the precise file'
            $result = Invoke-TestProcess $Executable ($validArguments + '--check') 'Missing-file --check'
            Assert-Equal $result.ExitCode 1 'Missing-file --check must fail without a popup'
            Assert-True ($result.Stderr.Contains([IO.Path]::GetFileName($path))) 'Missing-file --check reports the filename on stderr'
            Assert-True (-not ($result.Stdout + $result.Stderr).Contains('fixture-secret-must-not-leak')) 'Diagnostics must not reveal env contents'
        } finally { [IO.File]::Move($saved, $path) }
    }
    # AllUsers may be launched by an ordinary user while another admin owns immich.env.
    # The tray startup must not demand access to secrets before a command is selected.
    [IO.File]::Move($envFile, ($envFile + '.held-for-test'))
    try {
        $options.ValidateFiles()
        Assert-True $true 'Validation does not require access to the secret env file'
        $noEnvArguments = [string[]]$validArguments.Clone(); $noEnvArguments[5] = 'AllUsers'
        $result = Invoke-TestProcess $Executable ($noEnvArguments + '--check') 'Unavailable-env AllUsers --check'
        Assert-Equal $result.ExitCode 0 '--check must work without reading the private env file'
    } finally { [IO.File]::Move(($envFile + '.held-for-test'), $envFile) }
    [IO.File]::WriteAllText($fixtureIcon, 'Invalid icon fixture.')
    try {
        $result = Invoke-TestProcess $Executable ($validArguments + '--check') 'Corrupt-icon --check'
        Assert-Equal $result.ExitCode 1 '--check must really construct an Icon, not merely check File.Exists'
        Assert-True (-not [string]::IsNullOrWhiteSpace($result.Stderr)) 'Corrupt-icon --check must report an error without a popup'
    } finally { [IO.File]::WriteAllBytes($fixtureIcon, $iconBytes) }
    foreach ($arguments in @(
        @{ Value = [string[]]($validArguments + @('--check', '--unknown')) },
        @{ Value = [string[]]($validArguments + @('--check', '--check')) },
        @{ Value = [string[]]@('--check', '--install-root') }
    )) {
        $result = Invoke-TestProcess $Executable $arguments.Value 'Invalid CLI --check'
        Assert-Equal $result.ExitCode 1 'Invalid CLI --check must fail headlessly'
        Assert-True (-not [string]::IsNullOrWhiteSpace($result.Stderr)) 'Invalid CLI --check must explain the error'
    }
    $result = Invoke-TestProcess $Executable @('--install-root', $installRoot, '--exit-existing') 'Absent-instance exit'
    Assert-Equal $result.ExitCode 0 'Exit-existing is idempotent when no tray is running'

    # Execute generated management wrappers against inert scripts using this Windows PowerShell,
    # without BuildStartInfo's runas verb. The fake Read-Host records the Enter boundary.
    $hostPowerShell = Join-Path $PSHOME 'powershell.exe'
    $tracePath = Join-Path $base 'failure-prompt.txt'
    foreach ($action in @('start', 'stop', 'update')) {
        $scriptPath = switch ($action) { 'start' { $startPath } 'stop' { $stopPath } 'update' { $updatePath } }
        $modes = @('success', 'throw', 'native-nonzero')
        if ($action -eq 'update') { $modes += @('latest', 'acknowledged-failure') }
        foreach ($mode in $modes) {
            $body = switch ($mode) { 'success' { "Write-Output 'fixture success'" } 'throw' { "throw 'fixture controlled failure'" } 'native-nonzero' { 'exit 7' } 'latest' { 'exit 10' } 'acknowledged-failure' { 'exit 20' } }
            Write-Fixture $scriptPath ("param(`$InstallRoot, `$DataRoot, `$EnvFile, `$Scope, [switch]`$Interactive, `$Language)`r`n" + $body)
            if ([IO.File]::Exists($tracePath)) { [IO.File]::Delete($tracePath) }
            $text = if ($action -eq 'update') { $japanese } else { $english }
            $prelude = '$global:TrayTestTrace=' + (Quote-PowerShell $tracePath) + '; ' + @'
function Write-Host { param($Object, $ForegroundColor) [IO.File]::AppendAllText($global:TrayTestTrace, "display:" + [string]$Object + "`r`n") }
function Read-Host { param($Prompt) [IO.File]::AppendAllText($global:TrayTestTrace, "enter:" + $Prompt + "`r`n"); return '' }
'@
            $command = $prelude + "`r`n" + [Immich.Windows.TrayCommands]::BuildCommand($options, $action, $text)
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
            $result = Invoke-TestProcess $hostPowerShell @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) ("$action / $mode wrapper")
            if ($mode -eq 'success') {
                Assert-Equal $result.ExitCode 0 ("$action success returns zero")
                Assert-True (-not [IO.File]::Exists($tracePath)) ("$action success does not request Enter")
            } elseif ($mode -in @('latest', 'acknowledged-failure')) {
                $expectedExit = if ($mode -eq 'latest') { 10 } else { 20 }
                Assert-Equal $result.ExitCode $expectedExit ("$action $mode preserves the updater result")
                Assert-True (-not [IO.File]::Exists($tracePath)) ("$action $mode must not prompt or display a duplicate result")
            } else {
                Assert-Equal $result.ExitCode 1 ("$action $mode returns nonzero after Enter")
                Assert-True ([IO.File]::Exists($tracePath)) ("$action $mode displays and retains failure")
                $trace = [IO.File]::ReadAllText($tracePath)
                Assert-True ($trace.StartsWith('display:')) ("$action $mode displays error first")
                Assert-True ($trace.Contains('enter:' + $text.Continue)) ("$action $mode waits for localized Enter prompt")
                $expectedError = if ($mode -eq 'throw') { 'fixture controlled failure' } else { 'Exit code: 7' }
                Assert-True ($trace.Contains($expectedError)) ("$action $mode preserves diagnostic")
            }
        }
        Write-Fixture $scriptPath $inertScript
    }
    Write-Host ("PASS Tray-Controller: {0} assertions; {1} isolated child processes" -f $script:AssertCount, $script:ProcessCount)
} finally {
    if ([IO.Directory]::Exists($base)) { Remove-Item -LiteralPath $base -Recurse -Force }
}
