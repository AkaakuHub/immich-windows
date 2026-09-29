# WSLからWindowsへの移行

移行を行うPC内のWSLを対象にします。移行元と移行先のImmichの版をそろえます。PostgreSQLのLinux用データディレクトリはWindowsへコピーせず、ダンプから復元します。既にWindowsのHDDにある写真・動画はその場で使います。移行では導入前にDBをエクスポートするため、ReleaseのアプリZIPを展開してスクリプトを使います。導入にはReleaseに別添した`Install.cmd`を使います。

## 1. 移行先と入力値を準備する

[導入手順](install.md)に従い、WindowsのPostgreSQLを準備します。次の値を移行元の設定から確認してください。

| 入力 | 例・既定値 |
| --- | --- |
| WSLディストリビューション名 | `Debian`。`wsl.exe --list --quiet`で一覧表示できます |
| WSL内のComposeファイル | `/home/user/immich/docker-compose.yml`などの絶対パス |
| DBのComposeサービス名 | `database` |
| 停止するComposeサービス名 | `immich-server`、`immich-machine-learning` |
| DBユーザー名・DB名 | `postgres`、`immich`。既存の`.env`に合わせます |
| 旧メディアルート | Docker内でImmichが見ていたパス。通常は`/data` |
| 新メディアルート | 写真があるWindowsのフォルダー。例：`D:\Photos\Immich` |

対象WSLでDocker Composeを使える状態にします。以降のスクリプトがDocker操作を実行するため、手動のDockerコマンドは不要です。既存の`.env`もWindows側で読める場所に用意します。

## 2. Windowsからダンプを作る

メインZIPを展開した場所でPowerShell 7（`pwsh`）を開きます。以下の例のパス・ユーザー名は実際の値へ置き換えます。ダンプ保存先は事前に作成してください。

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\migration\Export-WslDatabase.ps1 `
  -Distro 'Debian' -ComposeFile '/home/user/immich/docker-compose.yml' `
  -Destination 'D:\immich-migration\immich.dump' `
  -DatabaseService 'database' -DatabaseUser 'postgres' -DatabaseName 'immich'
```

サービス名を変更している場合は`-ApplicationServices 'server','machine-learning'`も指定します。スクリプトは移行元Immichを停止し、DBのバイナリダンプをWindowsへ保存します。同名ファイルは上書きしません。失敗時は途中ファイルを削除し、移行元サービスの再起動を試みます。成功後は移行元を停止したままにします。

## 3. Windows版を起動せずに導入する

別にダウンロードした`Install.cmd`がある場所で実行します。

```powershell
.\Install.cmd -Scope AllUsers -EnvFile 'D:\immich-migration\.env' -MediaRoot 'D:\Photos\Immich' -DoNotStart
```

CurrentUserの場合は`-Scope CurrentUser`にし、先に[拡張の準備](install.md#currentuserの拡張準備)を完了します。導入先を指定した場合は以降も同じパスを使います。自動起動は登録されるため、移行完了まで再起動・サインアウトはしないでください。

## 4. DBを復元する

AllUsersでは管理者のPowerShellを使います。以下は既定のAllUsersのパスです。CurrentUserのパスは[共通の指定](operations.md#共通の指定)を参照してください。

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

復元は`immich.env`が指定する移行先DBを削除して作り直します。Immichは次の起動時に、DBに記録された旧メディアルートから`IMMICH_MEDIA_LOCATION`へのパス変更を自動実行します。先に`change-media-location`で書き換えないでください。メディアファイル自体はコピーしません。Storage TemplateなどDBに保存された設定も復元されます。

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

パス確認はDB内の対象パスを確認し、実ファイルは既定で各種最大2,000件を検査します。件数を変更する場合は`-FilesystemSample`を指定します。全ファイルの読み取り検査ではありません。

Windows版で、既存アカウントのログイン、タイムライン、元画像・動画、アルバム、外部ライブラリ、顔認識、Smart Search、Storage Templateの設定を確認します。顔・検索のインデックスはImmichのジョブから再構築できます。確認が終わるまで移行元WSLとダンプは残し、同じメディアへ旧環境と新環境から同時に書き込まないでください。
