#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('ja','en')][string]$Language = $(if ([Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'ja') { 'ja' } else { 'en' }),
    # Internal UAC handoff only; independently matched against installed registrations.
    [Parameter(DontShow)][string]$ElevatedSelection,
    [Parameter(DontShow)][switch]$PauseOnExit
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$result = 1
function Write-RepairMessage([string]$English, [string]$Japanese) {
    Write-Host $(if ($Language -eq 'ja') { $Japanese } else { $English })
}
try {
    if (-not $IsWindows) { throw 'WindowsRequired' }
    Import-Module (Join-Path $PSScriptRoot '../Common.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'MetadataDateRepair.Launcher.psm1') -Force
    $candidates = @(Get-RepairInstallCandidates -AllUsersOnly:([bool]$ElevatedSelection))
    if (-not $candidates.Count) { throw 'NoInstallation' }
    if ($ElevatedSelection) {
        if (-not (Test-ImmichElevated)) { throw 'InvalidSelection' }
        $selection = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ElevatedSelection)) | ConvertFrom-Json
        if (@($selection.PSObject.Properties.Name).Count -ne 3 -or $selection.Scope -cne 'AllUsers' -or
            $selection.DataRoot -isnot [string] -or $selection.InstallRoot -isnot [string]) { throw 'InvalidSelection' }
        $matches = @($candidates | Where-Object { $_.Scope -ceq 'AllUsers' -and (Test-RepairSamePath $_.DataRoot $selection.DataRoot) })
        if ($matches.Count -ne 1) { throw 'InvalidSelection' }
        $chosen = $matches[0]
        if ($selection.InstallRoot) {
            if ($chosen.InstallRoot -and -not (Test-RepairSamePath $chosen.InstallRoot $selection.InstallRoot)) { throw 'InvalidSelection' }
            # A service-only registration must resolve to the exact pre-UAC root below.
            $chosen.InstallRoot = $selection.InstallRoot
        }
    } elseif ($candidates.Count -eq 1) { $chosen = $candidates[0] }
    else {
        Write-RepairMessage 'Choose the installed Immich to repair:' '修復する Immich のインストールを選んでください:'
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            Write-Host ('  {0}. {1} | {2}' -f ($i + 1), $candidates[$i].Scope, $candidates[$i].DataRoot)
        }
        $answer = Read-Host $(if ($Language -eq 'ja') { '番号（Enter で中止）' } else { 'Number (Enter to cancel)' })
        if (-not $answer) { throw 'Cancelled' }
        $number = 0
        if (-not [int]::TryParse($answer, [ref]$number) -or $number -lt 1 -or $number -gt $candidates.Count) { throw 'InvalidChoice' }
        $chosen = $candidates[$number - 1]
    }
    if ($chosen.Scope -eq 'AllUsers' -and -not (Test-ImmichElevated)) {
        $payload = @{ Scope='AllUsers'; InstallRoot=[string]$chosen.InstallRoot; DataRoot=[string]$chosen.DataRoot } | ConvertTo-Json -Compress
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
        $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-Language',$Language,'-ElevatedSelection',$encoded,'-PauseOnExit')
        $argumentLine = ($arguments | ForEach-Object { ConvertTo-WindowsArgument -Value $_ }) -join ' '
        Write-RepairMessage 'Windows administrator permission is needed to read this AllUsers installation.' 'AllUsers インストールを読み込むため、Windows の管理者権限が必要です。'
        try {
            $child = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList $argumentLine -Verb RunAs -Wait -PassThru -ErrorAction Stop
        } catch { throw 'ElevationFailed' }
        $result = $child.ExitCode
        if ($result -ne 0) { Write-RepairMessage "Repair did not finish successfully (exit code $result). See the administrator window." "修復は正常に完了しませんでした（終了コード $result）。管理者ウィンドウを確認してください。" }
    } else {
        # CurrentUser is never elevated or re-discovered under a different identity.
        $install = Resolve-RepairInstall -Candidate $chosen
        Write-RepairMessage ("Installation: {0} | {1}" -f $install.Scope,$install.DataRoot) ("インストール: {0} | {1}" -f $install.Scope,$install.DataRoot)
        Write-RepairMessage '1. Start a new scan  2. Resume a previous repair  0. Cancel' '1. 新しくスキャンする  2. 前回の修復を再開する  0. 中止'
        $mode = Read-Host $(if ($Language -eq 'ja') { '番号（Enter で 1）' } else { 'Number (Enter for 1)' })
        $resumeDirectory = $null
        switch (([string]$mode).Trim()) {
            '' { }
            '1' { }
            '2' {
                $resumeDirectory = Select-RepairResumeFolder -OutputRoot $install.OutputRoot -Language $Language
                if ([string]::IsNullOrEmpty($resumeDirectory)) { throw 'Cancelled' }
                if (-not [IO.Path]::IsPathFullyQualified($resumeDirectory)) { throw 'InvalidChoice' }
            }
            '0' { throw 'Cancelled' }
            default { throw 'InvalidChoice' }
        }
        $nodeArguments = @((Join-Path $install.ReleaseRoot 'runtime/metadata-date-repair/guided.cjs'), '--release-root', $install.ReleaseRoot, '--output-root', $install.OutputRoot, '--language', $Language)
        if ($resumeDirectory) { $nodeArguments += @('--resume-directory', $resumeDirectory) }
        $previousEnvironment = [Environment]::GetEnvironmentVariables('Process')
        try {
            Clear-RepairConnectionEnvironment
            $startupTimezone = Resolve-RepairStartupTimezone -Scope $install.Scope -UserTimezone $(if ($install.Scope -eq 'CurrentUser') { [Environment]::GetEnvironmentVariable('TZ','User') } else { $null }) -MachineTimezone ([Environment]::GetEnvironmentVariable('TZ','Machine'))
            if (-not [string]::IsNullOrEmpty($startupTimezone)) { [Environment]::SetEnvironmentVariable('TZ', $startupTimezone, 'Process') }
            # The existing loader is used with no ServiceRole: no server/service action.
            . (Join-Path $install.ReleaseRoot 'runtime/launchers/Load-ImmichEnv.ps1') -EnvFile $install.EnvFile
            Push-Location -LiteralPath $install.ReleaseRoot
            try {
                & (Join-Path $install.ReleaseRoot 'runtime/node/node.exe') @nodeArguments
                $result = $LASTEXITCODE
            } finally { Pop-Location }
        } finally {
            foreach ($name in @([Environment]::GetEnvironmentVariables('Process').Keys)) {
                if (-not $previousEnvironment.Contains($name)) { Remove-Item -LiteralPath ("Env:" + $name) -ErrorAction Stop }
            }
            foreach ($name in $previousEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process') }
        }
    }
} catch {
    # Never print raw exceptions: env parsers and connection failures can include secrets.
    $failureCode = if ($_.Exception.Message -cin @('NoInstallation','ElevationFailed','Cancelled','InvalidChoice','MissingRuntime','UnsafeOutput','InvalidRegistration','ConflictingRegistration','InvalidSelection','WindowsRequired')) { $_.Exception.Message } else { 'InitializationFailed' }
    switch ($failureCode) {
        'NoInstallation' { Write-RepairMessage 'No registered Immich installation was found. Run this from the Windows account that installed Immich.' '登録済みの Immich が見つかりません。Immich をインストールした Windows アカウントで実行してください。' }
        'ElevationFailed' { Write-RepairMessage 'Administrator permission was cancelled or could not be obtained. Repair did not run.' '管理者権限がキャンセルされたか、取得できませんでした。修復は実行されていません。' }
        'Cancelled' { Write-RepairMessage 'Cancelled. No repair was started.' '中止しました。修復は開始されていません。'; $result = 0 }
        'InvalidChoice' { Write-RepairMessage 'Please run the launcher again and select one of the displayed numbers.' 'ランチャーを再実行し、表示された番号を選んでください。' }
        'MissingRuntime' { Write-RepairMessage 'The installed guided repair runtime is incomplete. Install a release containing this tool first.' 'インストール済みのガイド付き修復ランタイムが不足しています。このツールを含むリリースを先にインストールしてください。' }
        'UnsafeOutput' { Write-RepairMessage 'The repair output location is not a normal private data directory. Repair stopped.' '修復結果の保存先が通常のデータディレクトリではありません。修復を停止しました。' }
        default { Write-RepairMessage 'The registered installation could not be safely verified or loaded. Repair stopped. Check the installation and its configuration using the installing Windows account.' '登録済みのインストールを安全に確認または読み込みできませんでした。修復を停止しました。インストールした Windows アカウントで設定を確認してください。' }
    }
    if ($result -ne 0) { Write-RepairMessage ("Error code: $failureCode") ("エラーコード: $failureCode") }
} finally {
    if ($PauseOnExit) {
        try { $null = Read-Host $(if ($Language -eq 'ja') { 'Enter キーで閉じる' } else { 'Press Enter to close' }) } catch { }
    }
}
exit $result
