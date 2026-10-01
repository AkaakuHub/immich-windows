# 起動・更新・バックアップ

PowerShell 7で操作します。AllUsersは管理者として、CurrentUserは導入したユーザーとして実行してください。

## 共通の指定

設置先を変更している場合は、次のパスを置き換えてください。

```powershell
Set-ExecutionPolicy -Scope Process Bypass
$scope = 'AllUsers'
$installRoot = 'C:\Program Files\Immich'
$dataRoot = 'C:\ProgramData\Immich'
$envFile = Join-Path $dataRoot 'immich.env'
```

CurrentUserの場合は最初の3変数を次の値にします。

```powershell
$scope = 'CurrentUser'
$installRoot = Join-Path $env:LOCALAPPDATA 'Programs\Immich'
$dataRoot = Join-Path $env:LOCALAPPDATA 'Immich'
$envFile = Join-Path $dataRoot 'immich.env'
```

## 起動・停止・確認

```powershell
# 起動
& "$installRoot\current\runtime\launchers\Start-Immich.ps1" -InstallRoot $installRoot -DataRoot $dataRoot -EnvFile $envFile

# 停止
& "$installRoot\current\runtime\launchers\Stop-Immich.ps1" -InstallRoot $installRoot -DataRoot $dataRoot -EnvFile $envFile

# 起動後の確認
& "$installRoot\current\tests\Smoke-Windows.ps1" -InstallRoot $installRoot -DataRoot $dataRoot
```

スモークテストは写真のアップロードや顔認識を確認しません。PostgreSQLの設置先を変えた場合は`-PostgresRoot`も指定します。

ログは`$dataRoot\logs`、設定は`$envFile`にあります。閲覧先は`http://127.0.0.1:2283/`です。

## 新しいImmich版へ更新する

```powershell
& "$installRoot\current\installer\Update-FromRelease.ps1" -Scope $scope -InstallRoot $installRoot -DataRoot $dataRoot
```

最新Releaseへ更新します。版を指定する場合は`-Version 'vX.Y.Z'`を追加してください。更新時はDBバックアップを作成します。

同じImmich版のWindows向け修正版を入れる場合、更新コマンドは版が同じとして終了します。更新されたReleaseの`Install.cmd`を再取得し、既存の`-Scope`、`-InstallRoot`、`-DataRoot`、`-EnvFile`を渡して再導入してください。既存DBを移行する操作は不要です。

更新失敗時は`$dataRoot\state\upgrade-recovery.json`にエラーと、作成できたDBバックアップを記録します。バックアップ作成前に失敗した場合、候補版の導入は始まっていません。原因を解消して旧版を起動できます。バックアップ作成後に候補版の導入・起動が失敗した場合は次で復旧します。DBは更新前の状態へ戻るため、対象を確認して応答してください。

```powershell
& "$installRoot\current\installer\Recover-Upgrade.ps1" -Scope $scope -InstallRoot $installRoot -DataRoot $dataRoot
```

CurrentUserでPostgreSQL拡張の版も変わった場合は、管理者が旧版に対応する拡張を準備してから復旧します。アプリの`current`だけを旧版へ戻して、更新後のDBを開かないでください。

## DBバックアップ

```powershell
& "$installRoot\current\migration\New-DatabaseBackup.ps1" -EnvFile $envFile
```

保存先は既定で`$dataRoot\database-backups`です。変更する場合は`-DestinationDirectory 'E:\ImmichBackup'`を追加します。DBバックアップに写真・動画は含まれないため、メディアと`immich.env`は別途保管します。復元コマンドと起動前の確認は[移行手順](migration.md)を参照してください。

## アンインストール

```powershell
& "$installRoot\current\installer\Uninstall.ps1" -Scope $scope -InstallRoot $installRoot -DataRoot $dataRoot
```

常駐登録とアプリを削除します。PostgreSQL、DB、アプリ外のメディア、設定・ログ・モデルキャッシュは残ります。設定先も削除する場合のみ`-RemovePersistentData`を付けます。
