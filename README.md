# immich-windows

ImmichをWindowsで、WSLを使用することなくネイティブに動かす非公式プロジェクトです。

## インストール

PowerShell 7とPostgreSQL 18を準備し、[Releases](https://github.com/AkaakuHub/immich-windows/releases)から`Install.cmd`をダウンロードして実行します。詳しくは[導入手順](docs/install.md)を参照してください。

- `AllUsers`はWindowsサービスとしてPC起動時から常駐します。
- `CurrentUser`は現在のユーザーのサインイン時に起動します。

## 使い方

- [起動・停止・更新・バックアップ・削除](docs/operations.md)
- [WSLからの移行](docs/migration.md)
- [開発・上流バージョンへの追従](https://github.com/AkaakuHub/immich-windows/blob/main/docs/development.md)
