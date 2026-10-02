# 開発と上流更新

## ローカル開発環境

Windows x64、Git、PowerShell 7、Visual Studio 2022 Build ToolsのC++ x64ツールとWindows SDK、LLVMの`libclang.dll`、Rustup、PostgreSQL 18が必要です。libvipsのビルドにはDockerも使います。

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

ビルド結果は`dist/immich-windows-vX.Y.Z.R-win-x64`に出力されます。既存のlibvipsを使う場合は`-CustomSharpLibvipsBundle`を指定します。

`Fetch-MediaFixtures.ps1`は画像デコード検証用のサンプルを取得します。顔認識、動画変換、アップロードは別途確認してください。

ビルド済みコードから配布物だけを作り直す場合は、同じPowerShellセッションで実行します。

```powershell
./build/Bootstrap-BuildTools.ps1
./packaging/New-Package.ps1
```

ローカル検証では生成された`installer/Install.ps1`に`-PackageRoot`を渡して実行します。ネイティブ依存ZIPは検証先の`InstallRoot\cache\downloads`に置いてください。稼働中のメディアとDBは使わず、起動後に`tests/Smoke-Windows.ps1`で確認します。

## GitHub Actions

| Workflow | 実行内容 |
| --- | --- |
| `static-windows-port-audit` | PRとmainのコード変更時に構文・版比較・DirectML制御・上流へのパッチ適用を確認します |
| `build-windows-native` | PRとmainのコード変更で自動実行します。ビルド・両スコープで導入・稼働中の旧形式からの更新を確認し、mainでのみReleaseを公開します。手動`all`も同じです。`codec`・`postgres`・`migration`は成果物の検証のみでReleaseを上書きしません |
| `keep-native-build-cache` | 定期的に現在の設定に一致するキャッシュを参照します |
| `check-upstream-immich-release` | 上流の新しいstable版をIssueで通知します。自動で版を変更しません |

Windows runnerの使い捨てDBで起動・更新・設定保持・同一版拒否を検証します。GPUがないCIではCPUで小さいONNXモデルの推論を検証し、GPUフォールバック制御はモックテストします。RX 550での実モデル推論・PC再起動は実機検証が必要です。

本体版とWindows改訂は既存`upstream.json`の`version`と`windowsRevision`で管理します。例：`v3.2.2`と`1`から`v3.2.2.1`。配布に影響する変更は改訂番号を増やし、本体変更時は改訂を1へ戻します。公開済みタグと同じ/古い版はビルド前に失敗させます。Releaseは全テスト成功後にdraftを作り、全ファイルのアップロード成功後に公開します。既存assetsは上書きしません。

ドキュメントのみの変更では自動ビルドしません。native依存は内容ベースの既存キャッシュを再利用し、改訂番号だけでは再ビルドしません。アプリ側も復元したキャッシュの入力署名を確認して必要な段階だけ再ビルドします。

## 上流版を更新する

1. `upstream.json`のtag/commitと`dependencies/versions.json`の版を更新します。
2. `Prepare-Source.ps1`でパッチを確認します。上流で不要になったパッチを削除し、必要な差分だけを修正します。
3. 静的監査、ビルド、薄型パッケージからの両モード導入、画像・動画・顔認識・検索・バックアップ・復元を確認します。
4. Windows改訂番号を更新してPRの検証を通します。mainへマージすると自動ビルドし、すべて成功した版だけ公開します。

[構成](architecture.md)と[参照元](upstream-sources.md)も参照してください。
