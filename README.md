# immich-windows

ImmichをWindows x64でネイティブ実行する非公式プロジェクトです。固定した上流版に必要最小限のWindows向けパッチを適用します。Immich本体の履歴、DBスキーマ、マイグレーションは変更しません。

## インストール

PowerShell 7とPostgreSQLを準備し、[Releases](https://github.com/AkaakuHub/immich-windows/releases)から`Install.cmd`だけをダウンロードして実行します。アプリZIPは自動取得します。準備、既存の`.env`の指定、インストール先の選択は[導入手順](docs/install.md)を参照してください。

- `AllUsers`はWindowsサービスとしてPC起動時から常駐します。
- `CurrentUser`は現在のユーザーのサインイン時に起動します。

メインZIPにNode.js、Python、`node_modules`、`site-packages`は含めません。固定版のランタイムと依存をインストール時に取得し、キャッシュを再利用します。重いネイティブビルドはGitHub Actionsで行います。本番でDocker・WSL2・Linux VMは使用しません。

## 使い方

- [起動・停止・更新・バックアップ・削除](docs/operations.md)
- [WSLからの移行](docs/migration.md)
- [開発・上流バージョンへの追従](https://github.com/AkaakuHub/immich-windows/blob/main/docs/development.md)

Windows上のメディアは既存のNTFSフォルダーをそのまま使えます。DBは論理バックアップから復元し、DB内のLinuxパスをWindowsパスへ変更します。
