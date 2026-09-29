# 開発と上流更新

通常の導入・更新ではビルド環境は不要です。利用者向けの操作は[導入手順](install.md)と[更新手順](operations.md)にまとめています。

## ローカル開発環境

Windows x64、Git、PowerShell 7、Visual Studio 2022 Build ToolsのC++ x64ツールとWindows SDK、LLVMの`libclang.dll`、Rustup、PostgreSQL 18が必要です。libvipsを新しくビルドする場合のみLinuxコンテナーを実行できるDockerも使います。Node.js・pnpmなどの版はビルドスクリプトが準備します。

リポジトリのルートで実行します。

```powershell
pwsh -NoProfile -File .\tests\Static-RepositoryAudit.ps1
pwsh -NoProfile -File .\build\Prepare-Source.ps1
```

`.work/immich`は生成物です。直接変更せず、Windows固有の変更は`patches/`へ追加します。[パッチ方針](../patches/README.md)を守ってください。

## ビルドと検証

PowerShell 7で次を実行します。初回はネイティブ依存のビルドに時間がかかります。

```powershell
$fixtures = @(./tests/Fetch-MediaFixtures.ps1 -Destination './.cache/media-fixtures')
./build/Build-Release.ps1 -PostgresRoot 'C:\Program Files\PostgreSQL\18' -InstallCargoPgrx -SharpFixture $fixtures
./packaging/New-NativeDependenciesArchive.ps1
```

`Build-Release.ps1`は`dist/immich-windows-vX.Y.Z-win-x64`に未圧縮のアプリを作ります。ローカルのデバッグでは、このフォルダーを使えます。ZIP作成や全削除を毎回行う必要はありません。既存のlibvipsを明示する場合は`-CustomSharpLibvipsBundle`を指定します。

`Fetch-MediaFixtures.ps1`はJPEG・PNG・WebP・AVIF・HEIC・RAW・JXLの公開サンプルを取得します。これは画像デコード検証用です。顔認識、動画変換、アップロードなどの実機確認は別途必要です。

ビルド済みコードから配布物だけを作り直す場合は、同じPowerShellセッションで実行します。

```powershell
./build/Bootstrap-BuildTools.ps1
./packaging/New-Package.ps1
```

配布フォルダーの`Install.cmd`を使って検証します。公開前のネイティブ依存ZIPは、検証用`InstallRoot\cache\downloads`に同じファイル名で置けば、インストーラーが再利用します。稼働環境のメディアとDBは使用しません。起動後は`tests/Smoke-Windows.ps1`を実行し、必要なメディア機能を確認します。

## GitHub Actions

| Workflow | 実行内容 |
| --- | --- |
| `static-windows-port-audit` | mainのコード変更時に構文・設定・上流へのパッチ適用を確認します |
| `build-windows-native` | 手動実行します。`all`でビルド・インストール確認を行い、mainでのみReleaseを公開します。`codec`と`postgres`は該当依存だけをビルドします |
| `keep-native-build-cache` | 定期的に現在の設定に一致するキャッシュを参照します |
| `check-upstream-immich-release` | 上流の新しいstable版をIssueで通知します。自動で版を変更しません |

重いビルドはpushのたびには実行しません。キャッシュは上流版・依存・パッチ・ビルドコードに応じて使い分けます。設定が一致しない古いキャッシュを新しい成果物として保存することはありません。GitHub側の容量制限や削除によるキャッシュ消失時は再ビルドが必要です。

`all`は作成したアプリをWindows runnerへ導入し、スモークテスト成功後にZIPを公開します。ユーザー操作、実データ移行、再起動、長時間のジョブ処理の全検証を代替するものではありません。

## 上流版を更新する

1. `upstream.json`のtag/commitと、上流が要求する`dependencies/versions.json`の版を更新します。PostgreSQLのChocolatey配布版もこのファイルで指定します。
2. `Prepare-Source.ps1`でパッチを確認します。上流で不要になったパッチを削除し、必要な差分だけを修正します。
3. 静的監査、ビルド、薄型パッケージからの両モード導入、画像・動画・顔認識・検索・バックアップ・復元を確認します。
4. 論理単位でコミットし、公開する変更を確定してからActionsの`all`を実行します。

[構成](architecture.md)と[参照元](upstream-sources.md)も参照してください。
