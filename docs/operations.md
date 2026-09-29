# 起動・更新・バックアップ

すべてPowerShell 7（`pwsh`）で操作します。AllUsersの管理操作は管理者として、CurrentUserは導入したユーザーとして実行します。

## 共通の指定

最初に実際の設置先を指定します。独自のパスを使った場合は同じ値に置き換えてください。

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

スモークテストはServer・ML、PostgreSQL拡張、Valkey、BullMQ、Sharp、FFmpeg、スキーマを確認します。写真のアップロードや顔認識などの全機能テストではありません。PostgreSQLの設置先を変えた場合は`-PostgresRoot`も指定します。

AllUsersのログは`$dataRoot\logs`にあります。設定は`$envFile`を使います。通常の閲覧先は`http://127.0.0.1:2283/`です。既定の待受ポートはServerが2283、MLが3003、Valkeyが6379、PostgreSQLが5432です。

## 新しいImmich版へ更新する

```powershell
& "$installRoot\current\installer\Update-FromRelease.ps1" -Scope $scope -InstallRoot $installRoot -DataRoot $dataRoot
```

公開済みの最新Releaseを取得し、DBバックアップ、停止、依存の設定、切り替え、起動確認を実施します。版を指定する場合は`-Version 'vX.Y.Z'`を追加します。本番PCでImmichやDLLのコンパイルは行いません。依存のダウンロードキャッシュは`$installRoot\cache`に残して再利用します。

同じImmich版のWindows向け修正版を入れる場合、更新コマンドは版が同じとして終了します。新しいZIPを展開し、その`Install.cmd`へ既存の`-Scope`、`-InstallRoot`、`-DataRoot`、`-EnvFile`を渡して再導入してください。既存DBを移行する操作は不要です。

更新失敗時は`$dataRoot\state\upgrade-recovery.json`に旧版とDBバックアップの組を記録します。復旧は次で行います。DBは更新前の状態へ戻るため、対象を確認して応答してください。

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
