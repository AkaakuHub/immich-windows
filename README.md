# immich-windows

ImmichをWindows x64でネイティブ実行するための非公式プロジェクトです。PostgreSQL、Valkey、Immich Server、Machine LearningをWindows上で動かします。本番実行にDocker、WSL2、Linux VMは使いません。

Immich本体はforkせず、[upstream.json](upstream.json)で固定した上流の版に[Windows patch](patches/README.md)を適用します。DB schemaとmigrationは上流のままです。

## 現状

Immich v3.2.2とPostgreSQL 18を対象にしています。このPCの使い捨てDBでは、写真・動画の取込、thumbnail、metadata、transcode、顔認識、Smart Search、album、バックアップと復元、LinuxからWindowsへのDB移行リハーサルを確認しました。実運用DBとHDDでの移行は未検証です。

## ビルド

ビルドPCにはPowerShell 7、Git for Windows、Visual Studio 2022 Build Tools、LLVM、Rust、PostgreSQL 18が必要です。custom libvipsを初めて作るときだけDockerのLinuxコンテナを使います。本番PCにはこれらのビルドツールは不要です。

```powershell
pwsh.exe -NoProfile -File .\tests\Static-RepositoryAudit.ps1
$fixtures = @(Get-ChildItem C:\immich-fixtures -File -Filter 'fixture-*' | Select-Object -ExpandProperty FullName)
pwsh.exe -NoProfile -File .\build\Build-Release.ps1 `
  -PostgresRoot 'C:\Program Files\PostgreSQL\18' `
  -InstallCargoPgrx `
  -SharpFixture $fixtures
```

`C:\immich-fixtures`にはJPEG、PNG、WebP、AVIF、複数種類のHEIC/HEIF、RAW、JXLの実画像を置きます。出力は`dist\immich-windows-v3.2.2-win-x64\`という**ディレクトリ**です。ZIPへの変換は不要です。

## インストールと更新

本番PCにはPostgreSQL 18をインストールし、PowerShell 7を管理者として実行します。初回インストールでは、ビルドしたディレクトリを本番PCへコピーしてから実行します。

```powershell
$package = 'D:\staging\immich-windows-v3.2.2-win-x64'
& "$package\installer\Install.ps1" -PackageRoot $package -MediaRoot 'D:\Immich' -DatabasePassword '<password>'
```

次の版への更新も、新しい**パッケージディレクトリ**を本番PCへ置いて実行します。ZIP、Docker、ビルドツールは不要です。

```powershell
$candidate = 'D:\staging\immich-windows-vNEXT-win-x64'
& "$candidate\installer\Update.ps1" -PackageRoot $candidate
```

更新スクリプトは更新直前のDBバックアップを作成し、既存設定とサービスを引き継ぎます。失敗時は候補パッケージの`installer\Recover-Upgrade.ps1`で、旧アプリと対応するDBバックアップを一緒に戻します。

## Linux/WSL2からの移行

元の環境と**同じImmich版**のWindowsパッケージを使います。PostgreSQLは`pg_dump`で論理バックアップし、`migration/Import-Database.ps1`でWindowsへ復元します。LinuxのDB data directoryはコピーしません。NTFS上の写真は同じ場所を使い、`IMMICH_MEDIA_LOCATION`にWindowsパスを設定します。

復元後の`/data`などの管理パスは、初回起動時に上流Immichが更新します。初回起動前に`immich-admin change-media-location`は実行しません。External Libraryがある場合は、初回起動前に`migration/Change-ExternalLibraryPath.ps1`でWindowsパスへ変更します。起動後は`migration/Verify-Migration.ps1`でDBのパスと実ファイルを確認します。

## 開発方針

版は[upstream.json](upstream.json)と[dependencies/versions.json](dependencies/versions.json)で管理します。`.work/immich`は直接編集せず、Windows固有の修正だけを`patches/`へ追加します。開発中は`build/Build-All.ps1`を使うと、入力が変わった段階だけを再ビルドします。配布ディレクトリを毎回作り直す必要はありません。

構成の詳細は[docs/architecture.md](docs/architecture.md)を参照してください。
