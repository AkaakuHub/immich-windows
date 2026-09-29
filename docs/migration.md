# WSLからWindowsへの移行

この手順は移行を実行するWindows PCで行います。WSL内のPostgreSQLデータディレクトリをコピーせず、論理バックアップを作成します。メディアが既にWindowsのドライブにある場合はコピーしません。移行元と移行先のImmichバージョンはそろえてください。

## 事前に確認する値

- WSLディストリビューション名と、WSL内の`compose.yml`の絶対パス
- ComposeのDBサービス名とImmichサービス名。既定値は`database`、`immich-server`、`immich-machine-learning`です
- 移行元DBのユーザー名とDB名。既定値は`postgres`、`immich`です
- Windows側のインストール先、`immich.env`、メディアフォルダーのパス
- Docker内の旧メディアルート。通常は`/data`です

`Export-WslDatabase.ps1`はWindowsからWSLのDocker Composeを呼び出します。Dockerコマンドを手で入力する必要はありません。移行元のImmichサービスを停止してからダンプを取得し、成功後も停止したままにします。失敗した場合はサービスの再起動を試み、途中のダンプを削除します。

## 1. 移行元DBのダンプを作る

WindowsのPowerShellで、解凍したパッケージから実行します。次の値は実際の環境に置き換えてください。

```powershell
.\migration\Export-WslDatabase.ps1 `
  -Distro 'Debian' `
  -ComposeFile '/home/user/immich/compose.yml' `
  -Destination 'D:\immich-migration\immich.dump' `
  -DatabaseService 'database' `
  -DatabaseUser 'postgres' `
  -DatabaseName 'immich'
```

作成先ディレクトリは事前に用意します。同名のダンプがある場合は上書きしません。Windowsの`pg_restore`でダンプを読めることを確認してから完了します。WSLのDocker連携が有効で、対象ディストリビューションから`docker compose`を実行できる必要があります。

## 2. Windows版をインストールする

パッケージの`Install.cmd`を実行し、`AllUsers`または`CurrentUser`を選びます。既存の`.env`を指定すると、DBパスワードなどを引き継げます。`UPLOAD_LOCATION`がLinuxの相対パスなら、実際のWindowsメディアフォルダーを指定します。メディアファイル自体は移動しません。

移行先DBに残したいデータがないことを確認してください。次の復元操作は、`.env`に指定したImmich用DBを削除して作り直します。

## 3. DBを復元し、メディアのパスを変更する

インストール後、Immichを停止した状態で次を実行します。`$installRoot`、`$envFile`、`$mediaRoot`にはインストール時の値を指定します。`AllUsers`の場合は管理者のPowerShellで実行します。

```powershell
$installRoot = 'C:\Program Files\Immich'
$envFile = 'C:\ProgramData\Immich\immich.env'
$mediaRoot = 'D:\Photos\Immich'
$release = Join-Path $installRoot 'current'

& (Join-Path $release 'migration\Import-Database.ps1') `
  -Backup 'D:\immich-migration\immich.dump' -EnvFile $envFile

& (Join-Path $release 'runtime\launchers\immich-admin.ps1') `
  -EnvFile $envFile change-media-location
```

`change-media-location`の質問には、旧メディアルートと`$mediaRoot`を指定します。これは上流Immichの管理コマンドです。Storage Templateの日付形式など、DBに保存された設定はそのまま引き継がれます。

外部ライブラリを使っていた場合のみ、各旧ルートに対して次を実行します。まず`-Apply`なしで変更件数を確認し、正しければ同じ引数に`-Apply`を追加します。`-RollbackBackup`には手順1のダンプを指定します。

```powershell
& (Join-Path $release 'migration\Change-ExternalLibraryPath.ps1') `
  -OldRoot '/external-library' -NewRoot 'D:\Photos\External' `
  -EnvFile $envFile -RollbackBackup 'D:\immich-migration\immich.dump'
```

## 4. 起動前に確認する

```powershell
& (Join-Path $release 'migration\Verify-Migration.ps1') `
  -MediaRoot $mediaRoot -EnvFile $envFile
& (Join-Path $release 'migration\Schema-Check.ps1') `
  -InstallRoot $installRoot -EnvFile $envFile
```

パスとスキーマの確認に成功してからWindows版を起動し、API、タイムライン、サムネイル、顔認識、Smart Searchを確認します。顔や検索の再構築ジョブは必要に応じてImmichから実行します。移行元WSLのサービスは、Windows側の確認が終わるまで停止したままにしてください。
