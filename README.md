# immich-windows

ImmichをWindows x64でネイティブ実行する非公式プロジェクトです。Immich本体はforkせず、固定した上流版にWindows向けpatchを適用します。DB schemaとmigrationは変更しません。

本番環境ではDocker、WSL2、Linux VMを使わず、Windows上のPostgreSQL、Valkey、Immich Server、Machine Learningを動かします。

## Install

公開Releaseの`Install.cmd`を実行します。対話式でインストール範囲や設定を指定できます。

配布アーカイブにはNode.jsの実行時依存を含めず、インストール時に固定pnpmで取得します。依存storeはInstallRoot内に保持して更新時に再利用するため、初回と新しい依存の取得時にはネット接続が必要です。

- `AllUsers`: Windowsサービスとして常駐。管理者権限が必要です。
- `CurrentUser`: ユーザーのサインイン中に常駐。管理者権限は不要です。

既存の`.env`を使う場合は、`Install.cmd -EnvFile "C:\path\to\.env" -Scope CurrentUser`のように指定します。PostgreSQLと、[固定バージョン](dependencies/versions.json)に合うpgvectorおよびVectorChordが必要です。

`AllUsers`の設置先は`-InstallRoot "C:\SharedC\immich-app"`で指定できます。更新後も`C:\SharedC\immich-app\current`を使用します。配布用フォルダーのバージョン名は設置先に影響しません。

## Migration

Linux/WSL2からのDB復元とメディアパス更新は[移行手順](docs/migration.md)を参照してください。既存のメディアファイルはNTFS上でそのまま使用できます。

## Development

上流の固定版、Windows patch、ビルド手順は[patch policy](patches/README.md)とGitHub Actionsを参照してください。Dockerはcustom libvipsのビルド時だけ使用します。
