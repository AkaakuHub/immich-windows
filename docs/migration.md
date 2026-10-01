# WSLからWindowsへの移行

同じPCのWSLからWindowsへ移行します。移行元と移行先のImmichの版をそろえ、DBはダンプから復元します。Windows上の写真・動画はそのまま使います。Releaseの移行ツールZIPと`Install.cmd`を用意してください。

DBのエクスポート、Windows版の導入、DBの復元、起動確認の順に進めます。エクスポート用スクリプトが移行元を停止します。

## 1. 移行先と入力値を準備する

[導入手順](install.md)に従い、WindowsのPostgreSQLを準備します。次の値を移行元の設定から確認してください。

| 入力 | 例・既定値 |
| --- | --- |
| WSLディストリビューション名 | `Debian`。`wsl.exe --list --quiet`で一覧表示できます |
| WSL内のComposeファイル | `/home/user/immich/docker-compose.yml`などの絶対パス |
| DBのComposeサービス名 | `database` |
| 停止するComposeサービス名 | `immich-server`、`immich-machine-learning` |
| DBユーザー名・DB名 | `postgres`、`immich`。既存の`.env`に合わせます |
| 新メディアルート | 写真があるWindowsのフォルダー。例：`D:\Photos\Immich` |

WSLでDocker Composeを使える状態にし、既存の`.env`をWindowsから読める場所に置いてください。

## 2. Windowsからダンプを作る

移行ツールZIPを展開し、PowerShell 7で実行します。パスとユーザー名を実際の値に置き換え、ダンプ保存先を事前に作成してください。

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\migration\Export-WslDatabase.ps1 `
  -Distro 'Debian' -ComposeFile '/home/user/immich/docker-compose.yml' `
  -Destination 'D:\immich-migration\immich.dump' `
  -DatabaseService 'database' -DatabaseUser 'postgres' -DatabaseName 'immich'
```

サービス名を変更している場合は`-ApplicationServices 'server','machine-learning'`も指定します。スクリプトは移行元を停止してダンプを保存し、成功後も停止したままにします。

## 3. Windows版を起動せずに導入する

`Install.cmd`がある場所で実行します。

```powershell
.\Install.cmd -Scope AllUsers -EnvFile 'D:\immich-migration\.env' -MediaRoot 'D:\Photos\Immich' -DoNotStart
```

CurrentUserの場合は`-Scope CurrentUser`にし、先に[拡張を準備](install.md#currentuserの拡張準備)してください。自動起動は登録されるため、移行完了まで再起動・サインアウトはしないでください。

## 4. DBを復元する

AllUsersでは管理者のPowerShellを使います。CurrentUserのパスは[共通の指定](operations.md#共通の指定)を参照してください。

```powershell
Set-ExecutionPolicy -Scope Process Bypass
$installRoot = 'C:\Program Files\Immich'
$dataRoot = 'C:\ProgramData\Immich'
$envFile = Join-Path $dataRoot 'immich.env'
$release = Join-Path $installRoot 'current'
$mediaRoot = 'D:\Photos\Immich'
$backup = 'D:\immich-migration\immich.dump'

& "$release\migration\Import-Database.ps1" -Backup $backup -EnvFile $envFile
```

復元は`immich.env`が指定する移行先DBを削除して作り直します。次の起動時にImmichがメディアのパスを自動変更するため、先に`change-media-location`を実行しないでください。メディアファイルはコピーしません。

外部ライブラリを使っていた場合のみ、各旧ルートを変更します。まず次のプレビューを確認し、正しければ同じコマンドに`-Apply`を追加します。

```powershell
& "$release\migration\Change-ExternalLibraryPath.ps1" `
  -OldRoot '/external-library' -NewRoot 'D:\Photos\External' `
  -EnvFile $envFile -RollbackBackup $backup
```

## 5. 起動して移行結果を確認する

```powershell
& "$release\migration\Schema-Check.ps1" -InstallRoot $installRoot -EnvFile $envFile
& "$release\runtime\launchers\Start-Immich.ps1" -InstallRoot $installRoot -DataRoot $dataRoot -EnvFile $envFile
& "$release\migration\Verify-Migration.ps1" -MediaRoot $mediaRoot -EnvFile $envFile
& "$release\tests\Smoke-Windows.ps1" -InstallRoot $installRoot -DataRoot $dataRoot
```

`Verify-Migration.ps1`はDB内のパスと、既定で各種最大2,000件の実ファイルを確認します。件数は`-FilesystemSample`で変更できます。

既存アカウントでログインし、タイムライン、元画像・動画、アルバム、外部ライブラリ、顔認識、Smart Searchを確認してください。人物の分類と検索用の特徴量はダンプに含まれます。DBの復元時には検索用インデックスが再作成されます。VectorChord更新時のインデックス再構築にも、写真の全件再解析は不要です。確認が終わるまで移行元WSLとダンプを残し、旧環境と新環境から同じメディアへ同時に書き込まないでください。
