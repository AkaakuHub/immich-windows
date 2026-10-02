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
| `build-windows-native` | PRで静的監査・パッチ適用・ビルド・両スコープの導入と更新を一度検証します。mainでは同じ内容の検証済み成果物を再利用し、そのままReleaseへ公開します。再利用の証拠がない場合は通常の検証を実行します。手動`all`は明示的な再検証、`codec`・`postgres`・`migration`は個別成果物のみです |
| `keep-native-build-cache` | 定期的に現在の設定に一致するキャッシュを参照します |
| `check-upstream-immich-release` | 上流の新しいstable版をIssueで通知します。自動で版を変更しません |

Windows runnerの使い捨てDBで起動・更新・設定保持・同一版拒否を検証します。トレイは組み込みの.NET Frameworkコンパイラでビルドし、Windows PowerShell 5.1上で日英ラベル、引数の引用、UAC分離、NotifyIconの生成、両スコープのスタートアップ登録、旧メニュー削除を検証します。CurrentUserの起動判定には保持したProcessオブジェクトを使い、ロード直後にPathがまだ取得できない状態を終了扱いしません。GPUがないCIではCPUで小さいONNXモデルの推論を検証し、GPUフォールバック制御はモックテストします。RX 550での実モデル推論・PC再起動は実機検証が必要です。

本体版とWindows改訂は既存`upstream.json`の`version`と`windowsRevision`で管理します。例：`v3.2.2`と`1`から`v3.2.2.1`。配布に影響する変更は改訂番号を増やし、本体変更時は改訂を1へ戻します。公開済みタグより古い版、または公開済み版の配布入力を変えたまま改訂していない場合はビルド前に失敗させます。`.github/`と配布されない`docs/development.md`だけの変更は、同じ版のままCIを検証でき、新しいReleaseは作りません。Releaseは全テスト成功後にdraftを作り、全ファイルのアップロード成功後に公開します。既存assetsは上書きしません。

ドキュメントのみの変更では自動ビルドしません。native依存は内容ベースの既存キャッシュを再利用し、改訂番号だけでは再ビルドしません。アプリ側も復元したキャッシュの入力署名を確認して必要な段階だけ再ビルドします。

### GLibのWindows初期化の検証

GLib 2.89.3には、Windows用TLS（thread-local storage）コールバックの参照がリンカーから失われる問題があります。`media-patches/libvips`で[上流の修正29dce8a5](https://github.com/GNOME/glib/commit/29dce8a5a7878cd0863373255889d3dff79906c9)をバックポートします。通信のTLS証明書の問題ではありません。

ネイティブビルドの入力ハッシュにパッチを含め、修正前のGLibをキャッシュから再利用しません。生成したDLLのPE TLSディレクトリを検査し、Sharpの実画像変換とインストール後の検証ではGLibのCRITICALを失敗として扱います。終了コードだけで合格にしません。

### PRからmainへの成果物の再利用

- PRの実際のcheckout（GitHubが作るmerge commit）と、4つの配布ファイルのSHA-256を全テスト成功後に記録します。成果物は14日保持します
- mainの対象コミットにマージされた同一リポジトリのPR、正しいworkflow/run/attempt、必須ジョブの成功、GitHubが返すartifact IDとSHA-256を確認します。スキップされたテストを成功扱いしません
- 記録されたcommitをGitHubのGitオブジェクトで検証し、PRのbase/headを親に持つことと、実際にテストされたGit treeがmainと完全一致することを確認します。squashでcommit SHAが変わっても、treeが同じなら再実行しません
- fork、期限切れ・欠落した成果物、変更されたソースや実行attemptなど、再利用の証拠が揃わない場合は通常の検証へ戻します。ハッシュ不一致など不正・破損の疑いは自動で無視せず失敗させます
- キャッシュはビルドを速めるためだけに使い、合格の証拠として使いません。信頼の前提は、同一リポジトリ内でレビューされmainにマージされたコードと、GitHubに結び付いた不変のrun/artifactです。forkの成果物を特権付きジョブに持ち込みません
- 公開ジョブでは成果物内のプログラムを実行せず、ファイル名・ハッシュ・package manifestだけ検査します。検証済みZIPを再圧縮せず、manifestの実際のbuild commitも書き換えません。Release本文にmainのcommit、build commit、tree、run、artifact digestを残します
- 静的監査は`validate`へ統合しました。以前の`static-windows-port-audit / audit`をブランチ保護の必須チェックに指定している場合は、`validate`へ変更してください（この変更でリポジトリの保護設定自体は変更しません）

参考: [GitHubのPR実行コミット](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#pull_request)、[成果物の共有](https://docs.github.com/en/actions/tutorials/store-and-share-data)、[特権workflowの安全性](https://securitylab.github.com/resources/github-actions-preventing-pwn-requests/)

## 上流版を更新する

1. `upstream.json`のtag/commitと`dependencies/versions.json`の版を更新します。
2. `Prepare-Source.ps1`でパッチを確認します。上流で不要になったパッチを削除し、必要な差分だけを修正します。
3. 静的監査、ビルド、薄型パッケージからの両モード導入、画像・動画・顔認識・検索・バックアップ・復元を確認します。
4. Windows改訂番号を更新してPRの検証を通します。mainへマージすると検証済み成果物を照合し、同一内容なら再ビルドせず公開します。検証結果を再利用できない場合はビルド・検証を通してから公開します。

[構成](architecture.md)と[参照元](upstream-sources.md)も参照してください。
