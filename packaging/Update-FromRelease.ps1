#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$Version,
    [ValidateSet('AllUsers','CurrentUser')][string]$Scope='AllUsers',
    [string]$InstallRoot,
    [string]$DataRoot,
    [string]$PostgresRoot,
    [string]$PostgresService,
    [switch]$Interactive,
    [ValidateSet('en','ja')][string]$Language=$(if ([Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'ja') {'ja'} else {'en'})
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Get-UpdateText([string]$Key) {
    $messages=@{
        close=@('Press Enter to close this window','Enterキーを押してこの画面を閉じます')
        checking=@('Checking for updates…','更新を確認しています…')
        downloading=@('Downloading the update…','更新をダウンロードしています…')
        validating=@('Verifying the downloaded package…','ダウンロードしたパッケージを検証しています…')
        applying=@('Applying the update. Keep this window open.','更新を適用しています。この画面を閉じないでください。')
        latest=@('You have the latest version. No update is needed.','最新版です。適用できる更新はありません。')
        updated=@('Immich was updated successfully.','Immichの更新が完了しました。')
        failed=@('The update could not be completed.','更新を完了できませんでした。')
        installed=@('Installed version','インストール済みバージョン')
        log=@('Update log','更新ログ')
        noLog=@('The update log could not be created.','更新ログを作成できませんでした。')
        init=@('Could not prepare the update. Check permissions and installation paths.','更新の準備に失敗しました。権限とインストール先を確認してください。')
        locked=@('Another update is already running for this installation. Wait for it to finish.','このインストールでは別の更新を実行中です。完了するまでお待ちください。')
        check=@('Could not check the release server. Check your connection and try again.','公開バージョンを確認できませんでした。接続を確認して再試行してください。')
        inspect=@('Could not read the installed version.','インストール済みのバージョンを読み取れませんでした。')
        invalid=@('The release version is invalid. No update was applied.','公開バージョンが不正です。更新は適用していません。')
        missing=@('This release does not contain the Windows package.','このリリースにはWindows用パッケージがありません。')
        downgrade=@('The installed version is newer than this release. No downgrade was performed.','インストール済みのバージョンの方が新しいため、ダウングレードはしていません。')
        download=@('Could not download or extract the update package.','更新パッケージのダウンロードまたは展開に失敗しました。')
        validate=@('The downloaded package failed validation. No update was applied.','パッケージの検証に失敗しました。更新は適用していません。')
        apply=@('The update or its final health check failed. Review the log before retrying.','更新処理または最終動作確認に失敗しました。再試行する前にログを確認してください。')
        recovery=@('A previous update is incomplete. Recover it before checking for another update.','前回の更新が完了していません。復旧してから更新を再確認してください。')
        refresh=@('The current version is installed, but tray startup repair failed.','現在のバージョンはインストール済みですが、トレイの起動設定の修復に失敗しました。')
        cleanup=@('The update succeeded, but downloaded staging files could not be removed.','更新は完了しましたが、ダウンロードした一時ファイルを削除できませんでした。')
    }
    return $messages[$Key][$(if ($Language -eq 'ja') {1} else {0})]
}

function Get-UpdateFailureMessage($Record,[string]$EnvFile) {
    # Preserve the useful native/server error without dumping source, env or recovery state.
    # If private config cannot be read, omit arbitrary exception text rather than risk secrets.
    try {
        if (-not (Test-Path -LiteralPath $EnvFile -PathType Leaf)) { return $null }
        $values=Read-EnvFile $EnvFile
        $diagnostic=[string]$Record.Exception.Message
        foreach ($key in $values.Keys) {
            if ($key -match '(?i)PASS|SECRET|TOKEN|KEY|CREDENTIAL|CONNECTION') {
                $value=[string]$values[$key]
                if ($value) {
                    $diagnostic=$diagnostic.Replace($value,'[redacted]').Replace([Uri]::EscapeDataString($value),'[redacted]')
                }
            }
        }
        $diagnostic=$diagnostic -replace '(?im)((?:[\w]*PASSWORD|[\w]*SECRET|[\w]*TOKEN|API_KEY|Pwd|Authorization)\s*[:=]\s*).+', '$1[redacted]'
        $diagnostic=$diagnostic -replace '(?i)([a-z][a-z0-9+.-]*://)[^/\s@]+@', '$1[redacted]@'
        if ($diagnostic.Length -gt 2048) { $diagnostic=$diagnostic.Substring(0,2048)+'…' }
        return $diagnostic
    } catch { return $null }
}

$logPath=$null
$mutex=$null
$locked=$false
$phase='init'
$reason='init'
$currentVersion=$null
$releaseVersion=$null
$nativeExit=0
$failure=$null
$outcome=$null
$warning=$null
function Set-UpdatePhase([string]$Name,[string]$Progress) {
    $script:phase=$Name
    $script:reason=$Name
    if ($Progress) { Write-Host (Get-UpdateText $Progress) }
}

try {
    Import-Module (Join-Path $PSScriptRoot '..\runtime\Common.psm1') -Force
    if ($Scope -eq 'AllUsers') { Assert-Administrator }
    $paths=Resolve-ImmichInstallPaths -Scope $Scope -InstallRoot $InstallRoot -DataRoot $DataRoot
    $InstallRoot=$paths.InstallRoot
    $DataRoot=$paths.DataRoot
    New-Item -ItemType Directory -Path $DataRoot -Force|Out-Null

    # Same identity as Update.ps1. A nested call on this thread acquires it recursively;
    # both finally blocks release their own acquisition. Check/download are serialized too.
    $lockKey=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes([IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($InstallRoot)).ToUpperInvariant())))
    $mutex=[Threading.Mutex]::new($false,"Global\ImmichWindowsUpdate-$lockKey")
    try { $locked=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked=$true }
    if (-not $locked) { $reason='locked'; throw [InvalidOperationException]::new('Update already running.') }

    if ($Version -and $Version -cnotmatch '\Av(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z') { $reason='invalid'; throw 'Invalid requested release version.' }
    Set-UpdatePhase check checking
    $releaseUri=if($Version){"https://api.github.com/repos/AkaakuHub/immich-windows/releases/tags/$Version"}else{'https://api.github.com/repos/AkaakuHub/immich-windows/releases/latest'}
    $release=Invoke-RestMethod -Uri $releaseUri -Headers @{'User-Agent'='immich-windows'} -TimeoutSec 60
    $releaseVersion=[string]$release.tag_name
    if ($releaseVersion -cnotmatch '\Av(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z') { $reason='invalid'; throw 'Invalid returned release version.' }
    if ($Version -and $releaseVersion -ne $Version) { $reason='invalid'; throw 'Requested and returned versions differ.' }

    Set-UpdatePhase inspect ''
    $current=Get-CurrentReleaseTarget -InstallRoot $InstallRoot
    if (-not $current) { throw 'An existing Immich installation is required.' }
    $currentVersion=Get-WindowsPackageVersion (Get-Content -Raw -LiteralPath (Join-Path $current 'manifest.json')|ConvertFrom-Json)
    if ($currentVersion -eq [version]$releaseVersion.TrimStart('v')) {
        Set-UpdatePhase recovery ''
        Assert-ImmichStartupAllowed -EnvFile (Join-Path $DataRoot 'immich.env') -InstallRoot $InstallRoot
        # A tray check is a no-op when current. Keep the explicit CLI repair behavior.
        if (-not $Interactive) {
            Set-UpdatePhase refresh ''
            Write-ImmichTrayConnectionHint -InstallRoot $InstallRoot -DataRoot $DataRoot
            Remove-ImmichLegacyStartMenu -Scope $Scope
            Set-ImmichTrayStartup -InstallRoot $InstallRoot -DataRoot $DataRoot -Scope $Scope
            Start-ImmichTray -InstallRoot $InstallRoot -DataRoot $DataRoot -Scope $Scope
        }
        $outcome='latest'
    } else {
        if ([version]$releaseVersion.TrimStart('v') -lt $currentVersion) { $reason='downgrade'; throw 'Refusing to downgrade.' }
        $folder="immich-windows-$releaseVersion-win-x64"
        $assetName="$folder.zip"
        $asset=@($release.assets|Where-Object name -eq $assetName|Select-Object -First 1)
        if ($asset.Count -ne 1) { $reason='missing'; throw 'Native Windows package is missing.' }

        Set-UpdatePhase download downloading
        $stagingBase=Join-Path (Resolve-Path -LiteralPath $DataRoot).Path 'staging'
        $stage=Join-Path $stagingBase $releaseVersion
        $candidate=Join-Path $stage $folder
        $stagingPath=[IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($stagingBase))+[IO.Path]::DirectorySeparatorChar
        $stagePath=[IO.Path]::GetFullPath($stage)
        if (-not $stagePath.StartsWith($stagingPath,[StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid staging path.' }
        $readyPath=Join-Path $stage '.ready'
        if (-not (Test-Path -LiteralPath $readyPath -PathType Leaf)) {
            if (Test-Path -LiteralPath $stage) {
                $item=Get-Item -LiteralPath $stage -Force
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Staging path is a junction.' }
                Remove-Item -LiteralPath $stage -Recurse -Force
            }
            New-Item -ItemType Directory -Path $stage -Force|Out-Null
            $archive=Join-Path $stage $assetName
            try {
                Invoke-WebRequest -Uri $asset[0].browser_download_url -OutFile $archive
                Expand-Archive -LiteralPath $archive -DestinationPath $stage -Force
            } finally { Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue }
        }
        Set-UpdatePhase validate validating
        $global:LASTEXITCODE=0
        & (Join-Path $PSScriptRoot 'Test-ReleasePackage.ps1') -PackageRoot $candidate -Version $releaseVersion
        if ($LASTEXITCODE -ne 0) { $nativeExit=$LASTEXITCODE; throw 'Package validation returned a nonzero exit code.' }
        if (-not (Test-Path -LiteralPath $readyPath -PathType Leaf)) {'ready'|Set-Content -Encoding ascii -LiteralPath $readyPath}
        Set-UpdatePhase apply applying
        $global:LASTEXITCODE=0
        & (Join-Path $candidate 'installer\Update.ps1') -PackageRoot $candidate -Scope $Scope -InstallRoot $InstallRoot -DataRoot $DataRoot -PostgresRoot $PostgresRoot -PostgresService $PostgresService
        if ($LASTEXITCODE -ne 0) { $nativeExit=$LASTEXITCODE; throw 'Update returned a nonzero exit code.' }
        # An installer that silently returns without switching the release is not success.
        $installed=Get-CurrentReleaseTarget -InstallRoot $InstallRoot
        $installedVersion=Get-WindowsPackageVersion (Get-Content -Raw -LiteralPath (Join-Path $installed 'manifest.json')|ConvertFrom-Json)
        if ($installedVersion -ne [version]$releaseVersion.TrimStart('v')) { throw 'Installed version does not match the requested update.' }
        $outcome='updated'
        try { Remove-Item -LiteralPath $stage -Recurse -Force }
        catch { $warning=Get-UpdateText cleanup }
    }
} catch {
    $failure=$_
    # Nested scripts may turn a native failure into a throw before returning to our check.
    if ($phase -in @('validate','apply') -and (Get-Variable LASTEXITCODE -ErrorAction SilentlyContinue)) { $nativeExit=$LASTEXITCODE }
    $diagnostic=if ($DataRoot) {Get-UpdateFailureMessage $failure (Join-Path $DataRoot 'immich.env')} else {$null}
    $detail="phase=$phase; reason=$reason; exception=$($failure.Exception.GetType().FullName); hresult=$($failure.Exception.HResult); nativeExit=$nativeExit"
    $response=$failure.Exception.PSObject.Properties['Response']
    if ($response -and $response.Value -and $response.Value.PSObject.Properties['StatusCode']) { $detail+="; HTTP=$([int]$response.Value.StatusCode)" }
    if ($diagnostic) { $detail+="`n$diagnostic" }
    # Keep one small diagnostic for this failure, not a transcript or per-check file history.
    # A competing request must not overwrite the active updater's diagnostic.
    if ($locked) {
        try {
            $logs=Join-Path $DataRoot 'logs'
            New-Item -ItemType Directory -Path $logs -Force|Out-Null
            $logPath=Join-Path $logs 'update-last-error.log'
            Set-Content -LiteralPath $logPath -Encoding utf8 -Value ([DateTime]::UtcNow.ToString('o')+" $detail")
        } catch { $logPath=$null }
    }
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
}

if ($failure) {
    $message=(Get-UpdateText failed)+"`n`n"+(Get-UpdateText $reason)+"`n"+$detail
} else {
    $message=(Get-UpdateText $outcome)+"`n`n"+(Get-UpdateText installed)+": v$(if ($outcome -eq 'updated') {$installedVersion} else {$currentVersion})"
    if ($warning) { $message+="`n`n$warning" }
}
if ($failure -and $logPath) { $message+="`n`n"+(Get-UpdateText log)+": $logPath" }
elseif ($failure -and $locked) { $message+="`n`n"+(Get-UpdateText noLog) }
Write-Host $message
if ($Interactive) {
    # Wait inside the real elevated PowerShell session. This works when Windows Terminal
    # is the default console host too; never launch/wait on wt.exe as a proxy for the shell.
    # This process survives CurrentUser updates replacing the resident tray.
    [void](Read-Host (Get-UpdateText close))
    # Tray protocol: 0=updated, 10=already current, 20=failure already acknowledged.
    # The tray must never treat a handled failure as success or show the result twice.
    if ($failure) { exit 20 }
    if ($outcome -eq 'latest') { exit 10 }
    exit 0
}
if ($failure) { throw $failure }
$global:LASTEXITCODE=0
