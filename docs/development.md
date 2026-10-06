# 開発と上流更新

## ローカル開発環境

Windows x64、Git、PowerShell 7、Visual Studio 2022 Build ToolsのC++ x64ツールとWindows SDK、LLVMの`libclang.dll`、Rustup、PostgreSQL 18が必要です。libvipsのビルドにはDockerも使います。

リポジトリのルートで実行します。

```powershell
pwsh -NoProfile -File .\tests\Static-RepositoryAudit.ps1
pwsh -NoProfile -File .\build\Prepare-Source.ps1
```

`.work/immich`は生成物です。直接変更せず、Windows固有の変更は`patches/`へ追加します。[パッチ方針](../patches/README.md)を守ってください。日時メタデータの挙動修正は別の`metadata-patches/`で管理します（[対象範囲](../metadata-patches/README.md)）。

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
| `check-upstream-immich-release` | 毎日19:43 UTC（翌04:43 JST）に上流stable版を確認し、新しい版だけ固定コミット・依存版・パッチを準備してPRを作成し、既存の検証workflowを一度起動します |
| `complete-qualified-upstream` | 成功した自動更新のrun・artifact・PRのhead/base/treeを照合し、自動マージ後に同じ成果物の公開を起動します |

Windows runnerの使い捨てDBで起動・更新・設定保持・同一版拒否を検証します。トレイは組み込みの.NET Frameworkコンパイラでビルドし、Windows PowerShell 5.1上で日英ラベル、引数の引用、UAC分離、NotifyIconの生成、両スコープのスタートアップ登録、旧メニュー削除を検証します。CurrentUserの起動判定には保持したProcessオブジェクトを使い、ロード直後にPathがまだ取得できない状態を終了扱いしません。GPUがないCIではCPUで小さいONNXモデルの推論を検証し、GPUフォールバック制御はモックテストします。RX 550での実モデル推論・PC再起動は実機検証が必要です。

本体版とWindows改訂は既存`upstream.json`の`version`と`windowsRevision`で管理します。例：`v3.2.4`と`0`から`v3.2.4.0`。新しい上流stable版では改訂を自動で0へ戻します。同じ本体版でWindows側の配布内容を修正するときは、改訂を1、2、…と増やします。公開済みタグより古い版、または公開済み版の配布入力を変えたまま改訂していない場合はビルド前に失敗させます。`.github/`と配布されない`docs/development.md`だけの変更は、同じ版のままCIを検証でき、新しいReleaseは作りません。Releaseは全テスト成功後にdraftを作り、全ファイルのアップロード成功後に公開します。既存assetsは上書きしません。

ドキュメントのみの変更では自動ビルドしません。native依存は内容ベースの既存キャッシュを再利用し、改訂番号だけでは再ビルドしません。アプリ側も復元したキャッシュの入力署名を確認して必要な段階だけ再ビルドします。

assembleのCorepack保存先は既存の `.cache/corepack` に固定し、pinと取得スクリプトが一致するダウンロードキャッシュにpnpm本体も含めます。移行時は同じ入力の旧キャッシュを復元してから新キーへ保存します。新規の本体検証ではツール版確認・アプリ入力署名・導入テストを省略しません。`.tools` 全体やユーザープロファイルはキャッシュしません。

### CI変更と本体検証の分離

CI用Pythonスクリプトとworkflow契約のテストは、軽量なUbuntuの`ci-tools`で毎回実行します。計画処理とこのジョブだけで固定版`PyYAML==6.0.3`を使い、重複キー・alias・mergeキー・明示的な型タグを拒否してworkflowを比較します。配布パッケージへの追加依存はありません。

公開済み版のCIだけを変更するpush/PRでは、直近の成功したmainのrun、または同じPRの成功runから、元のSHA・run attempt・必須ジョブ・artifact digest・パッケージ内のsource/versionを検証します。配布内容、ビルド、Windowsテスト、pin、未知のファイル、workflowのコマンド・runner・env・権限・checkout・条件が変われば本体を再検証します。既知のCIテストジョブの移動、固定パスのCorepackキャッシュ移行、ZIP転送時の圧縮率だけを明示的に同等として扱います。workflow全体や`.github/`全体を無視しません。

更新元Releaseは元のassembleログに記録された版と一致させ、現在のReleaseと必要なSHA-256付きassetsが検証runより前から変更されていないことも確認します。ログやartifactの失効、証拠不足、より新しい失敗・実行中の検証があれば古い成功で隠しません。再利用時はWindowsのビルド・導入・更新を繰り返さず、元の検証SHAをsummaryへ記録します。新しいパッケージや「新SHAで導入テスト済み」という記録は作りません。Release昇格は従来どおり完全に同じGit treeだけに限定します。

圧縮済みの配布ZIPとmigration ZIPは`compression-level: 0`でartifactへ転送し、二重圧縮を避けます。

### Windows移植の回帰検証

パッチは既存の`Prepare-Source.ps1`で、`patches/series`、`metadata-patches/series`の順に固定コミットへ適用します。両方の一覧・パッチ内容が同じ準備状態に含まれます。準備済みソースの再利用は、現在のコミット・タグとパッチ内容のハッシュで判定します。生成時の差分と一致しない編集は上書きしません。全ソースファイルのハッシュ走査は追加していません。

機械学習は上流のアイドル終了を保ち、Windowsでも既存のUvicorn管理機能で1ワーカーを再起動します。CIでは両スコープの更新後に、使用前の安定待機、予測要求後の複数回のワーカー交換、停止時に子プロセスが残らないことを短いTTLで確認します。GPUや実モデルの性能測定をこの検証の代わりにはしません。

### 撮影日時のないファイルの回帰検証

既存のビルド後に`tests/Metadata-DateFallback.cjs`を一度実行し、準備済みの実際の`getDates`とサーバーのLuxonを検証します。PNG/JPEGを想定した合成入力だけを使い、画像・DB・サービスにはアクセスしません。

```powershell
node ./tests/Metadata-DateFallback.cjs ./.work/immich --server-root ./artifacts/application/server
```

Tokyo・UTC・夏時間の夏冬と切替前後、GPS由来のzone優先、撮影日時がある既存分岐の不変、再処理での二重加算防止を確認します。`tests/Source-Preparation.ps1`は両パッチ一覧の適用順・内容変更・再利用・失敗時の復旧・手作業の変更の保護を確認します。アプリのキャッシュキーにはメタデータパッチも含み、ローカルの既存`sourceDiff`署名にも反映されます。

### GLibのWindows初期化の検証

GLib 2.89.3には、Windows用TLS（thread-local storage）コールバックの参照がリンカーから失われる問題があります。`media-patches/libvips`で[上流の修正29dce8a5](https://github.com/GNOME/glib/commit/29dce8a5a7878cd0863373255889d3dff79906c9)をバックポートします。通信のTLS証明書の問題ではありません。

ネイティブビルドの入力ハッシュにパッチを含め、修正前のGLibをキャッシュから再利用しません。生成したDLLのPE TLSディレクトリを検査し、Sharpの実画像変換とインストール後の検証ではGLibのCRITICALを失敗として扱います。終了コードだけで合格にしません。

### 同じPR内のReleaseツール変更だけを検証する場合

同一リポジトリの同じPR・同じbaseに、有効な完全検証済み成果物がある場合だけ、変更されていないWindows検証を再利用します。Gitの全ファイルのpath・mode・type・blobを比較し、例外は配布されない `docs/development.md` と `.github/scripts/` の `qualified_release.py`、`publish_qualified.py`、対応する `test_qualified_release.py`、`test_publish_qualified.py` だけです。

- workflow、再利用判定自身、インストーラー、全Windowsテスト、ビルドスクリプト、パッチ、依存pin、配布ドキュメント、未知のファイルの変更は完全検証を必要とします
- GitHubの同一workflow/run/attemptと必須ジョブの成功、元のPR merge commit、artifact ID・SHA-256、配布ファイルのハッシュを照合します。失敗・実行中の新しいrunを古い成功で隠しません。成果物が欠落・期限切れなら完全検証へ戻します
- 再利用時も現在のPython Releaseツール回帰テストは実行します。ビルド、Windows静的検証、両スコープの導入・更新などは既存の合格証拠を参照し、実行を繰り返しません。summaryには実際に検証した元のcommitとrunを残します
- 新しいcommitが実機検証済みだったとは記録せず、新しいqualified成果物も作りません。mainへの公開は下記の完全なtree一致の境界を維持します。このPR専用の省略runをReleaseの合格証拠として使いません

### PRからmainへの成果物の再利用

- PRの実際のcheckout（GitHubが作るmerge commit）と、4つの配布ファイルのSHA-256を、パッケージ作成後・導入テスト前に準備します。これは合格記録ではありません。全テスト成功後、checkoutと配布ファイルが変わっていないことを再確認して初めて成果物をアップロードします。自動更新はmain上の信頼済みスクリプトでPR番号とhead/baseを確認してから、その固定merge commitを検証します。成果物は14日保持します
- mainの対象コミットにマージされた同一リポジトリのPR、正しいworkflow/run/attempt、必須ジョブの成功、GitHubが返すartifact IDとSHA-256を確認します。自動更新の完了処理は、マージ前にも同じ証拠を検査します。スキップされたテストを成功扱いしません
- 記録されたcommitをGitHubのGitオブジェクトで検証し、PRのbase/headを親に持つことと、実際にテストされたGit treeがmainと完全一致することを確認します。squashでcommit SHAが変わっても、treeが同じなら再実行しません
- fork、期限切れ・欠落した成果物、変更されたソースや実行attemptなど、再利用の証拠が揃わない場合は通常の検証へ戻します。ハッシュ不一致など不正・破損の疑いは自動で無視せず失敗させます
- キャッシュはビルドを速めるためだけに使い、合格の証拠として使いません。信頼の前提は、同一リポジトリ内でレビューされmainにマージされたコードと、GitHubに結び付いた不変のrun/artifactです。forkの成果物を特権付きジョブに持ち込みません
- 公開ジョブでは成果物内のプログラムを実行せず、ファイル名・ハッシュ・package manifestだけ検査します。検証済みZIPを再圧縮せず、manifestの実際のbuild commitも書き換えません。Release本文にmainのcommit、build commit、tree、run、artifact digestを残します
- 静的監査は`validate`で実行します。ブランチ保護の静的監査の必須チェックには`validate`を指定します。リポジトリの保護設定は自動変更しません

参考: [GitHubのPR実行コミット](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#pull_request)、[成果物の共有](https://docs.github.com/en/actions/tutorials/store-and-share-data)、[特権workflowの安全性](https://securitylab.github.com/resources/github-actions-preventing-pwn-requests/)

## 上流版の自動更新

通常の上流更新は手作業で版を書き換えず、次のフローで進みます。

1. GitHubの公式latest stableとmainの固定版を比較します。同じ版や古い版なら、PR作成・版の書き換え・ビルドを行いません。
2. 新しい版のtagを不変のcommitへ解決し、Windows改訂を0にします。上流の本番base-imageからNode・FFmpeg・メディア依存を、miseとpackage情報からビルドツール・Sharpを同期します。Windows専用のDB・DirectMLなどは既存の明示的な互換性方針を維持します。
3. 固定された旧版・新版のソースだけを使ってパッチを確認します。通常適用（行位置の移動を含む）、既に上流へ入った差分の除去、競合のないGit three-way適用を自動処理します。内容を推測してコードを書き換えることはありません。競合や未対応の依存関係・構造変更では、対象を示して停止します。
4. 版ごとの専用branchとdraft PRをGit Data APIで作成し、main上の既存workflowへPR番号・固定head/baseを明示して検証を依頼します。同じhead/baseに実行中・成功・失敗のrunがあれば重複ビルドしません。別の自動更新がまだ検証中なら新しい版は次の毎日確認まで待ち、既存ビルドをキャンセルしません。
5. 静的監査、パッチ適用、ネイティブビルド、新しいDBへの導入、実際の前のReleaseからの両スコープ更新など、必要なゲートを通します。mainが進んだ場合は、自動生成したことを確認できるheadだけを最新mainへ作り直して再検証します。人が変更したheadを自動で上書きしません。
6. 成功後、mainのスクリプトがrun・attempt・artifact digest・PRのhead/base・Git treeを再確認し、Git Data APIの`force:false`更新でmainを検証済みのmerge commitそのものへ進めます。mainのSHA・tree・親commitとPRのマージ結果が検証内容に一致することを確認してから、検証済みZIPを再ビルド・再圧縮せず公開します。

GitHub Actions標準の`GITHUB_TOKEN`だけを使います。botが作るPRやmergeからの通常イベントに頼らず、検証と公開を明示的にdispatchします。新しいPATやGitHub App秘密鍵は不要です。リポジトリではActionsによるPR作成を許可してください。権限が足りない場合はエラーを表示し、別のtokenを作ったり設定を変更したりはしません。

失敗した同一候補を毎日繰り返しビルドしません。検証自体は成功していて、完了処理だけが一時的に失敗した場合は、毎日の確認で同じ検証結果に限定して完了処理を再開します。進行中の完了処理と重複実行しません。競合・テスト失敗などの原因を修正した場合や一時的な障害の場合は、対象runを確認して再実行できます。新しい上流版の検出は継続し、過去の失敗だけで新しい版を永久に止めません。閉じた更新PRも勝手に作り直しません。

自動更新がmainへ入った後、配布ファイルのアップロードや公開だけが一時的に失敗した場合は、毎日の確認が同じmainと検証済み成果物に限定して公開を再開します。再ビルドはしません。既にアップロードしたファイルは検証済みSHA-256と一致するときだけ保持し、不足分だけ追加します。出所が異なるdraftや内容が違う既存assetは上書きせず、具体的な不整合をエラーにします。

手動で調査する場合は`Prepare-Source.ps1`、静的監査、Windowsの全検証ゲートを使います。実際の写真や稼働中DBを使って移行を試さないでください。

[構成](architecture.md)と[参照元](upstream-sources.md)も参照してください。
