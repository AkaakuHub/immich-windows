# 起動・更新・バックアップ

PowerShell 7で操作します。AllUsersは管理者として、CurrentUserは導入したユーザーとして実行してください。

## 右下の常駐アイコン

サインインすると、通知領域（画面右下。隠れている場合は「＾」）に本家Immichのアイコンが出ます。スタートメニューへの操作項目の自動追加は行いません。

アイコンのダブルクリックで既定のブラウザーを開きます。右クリックメニューには「Immichを開く」「Immichを起動」「Immichを停止」「Immichを更新」があります。表示はWindowsのUI言語に合わせた日本語・英語で、その他の言語は英語です。「トレイを終了」はアイコンだけを終了し、サーバーは停止しません。

OpenのURLはその都度immich.envのIMMICH_HOST/IMMICH_PORTから読み、未設定・ワイルドカードのホストはlocalhostを使います。ブラウザーは管理者権限で起動しません。別の管理者アカウントで導入したAllUsers環境など、設定ファイルを読めないユーザーには、インストール・更新時に保存したURLだけの公開情報を使います。DBパスワード等を含む設定ファイルの権限は広げません。AllUsersの起動・停止・更新だけにUAC確認が出ます。

常駐部分はWindows標準の.NET Framework/Windows Formsを使う小さなEXEです。新しいランタイムやNuGetパッケージ、常駐PowerShell、定期的な状態ポーリングは追加しません。PowerShellは操作を選んだときだけ起動します。

Install.cmdは通常のデスクトップから実行してください。全ユーザー用のインストール処理が昇格しても、完了後のトレイは元の一般権限のプロセスから起動します。管理者コンソールから実行した場合も、現在のデスクトップのエクスプローラーを通じて一般権限のトレイを起動します。エクスプローラーのないサービス・CIセッションではUIを起動せず、次のデスクトップへのサインイン時に起動します。

## 共通の指定

設置先を変更している場合は、次のパスを置き換えてください。

```powershell
Set-ExecutionPolicy -Scope Process Bypass
$scope = 'AllUsers'
$installRoot = 'C:\Program Files\Immich'
$dataRoot = 'C:\ProgramData\Immich'
$envFile = Join-Path $dataRoot 'immich.env'
```

CurrentUserの場合は最初の3変数を次の値にします。

```powershell
$scope = 'CurrentUser'
$installRoot = Join-Path $env:LOCALAPPDATA 'Programs\Immich'
$dataRoot = Join-Path $env:LOCALAPPDATA 'Immich'
$envFile = Join-Path $dataRoot 'immich.env'
```

## 起動・停止・確認

```powershell
# 起動
& "$installRoot\current\runtime\launchers\Start-Immich.ps1" -InstallRoot $installRoot -DataRoot $dataRoot -EnvFile $envFile

# 停止
& "$installRoot\current\runtime\launchers\Stop-Immich.ps1" -InstallRoot $installRoot -DataRoot $dataRoot -EnvFile $envFile

# 起動後の確認
& "$installRoot\current\tests\Smoke-Windows.ps1" -InstallRoot $installRoot -DataRoot $dataRoot
```

スモークテストは写真のアップロードや顔認識を確認しません。PostgreSQLの設置先を変えた場合は`-PostgresRoot`も指定します。

ログは`$dataRoot\logs`、設定は`$envFile`にあります。閲覧先は`http://127.0.0.1:2283/`です。

## 更新する（通常はトレイメニューから）

右下のImmichアイコンを右クリックし、**Immichを更新**（英語表示では **Update Immich**）を選びます。AllUsersの場合は管理者確認に応答します。最新のWindows版を取得し、既存の設置先・写真・設定を維持して停止・更新・再起動します。最新版の場合は設定やトレイを変更せず、「最新版です。適用できる更新はありません。」と表示します。更新完了・失敗の場合も結果をシェルに表示し、Enterキーを押すまで閉じません。Windows Terminalが既定のコンソールホストでも同じです。UACを取り消した場合は更新しません。

最新Releaseの`Install.cmd`からも既存環境を更新できます。標準の設置先が1つなら自動検出します。設置先を変更した環境では、既存の`-Scope`、`-InstallRoot`、`-DataRoot`を指定してください。

**v3.2.2.8からv3.2.4.0へ移る場合は、初回だけ新しいReleaseの`Install.cmd`をダウンロードし直して実行してください。** v3.2.2.8に入っているトレイ用更新スクリプトは末尾が`.0`の版を拒否するため、新しいコードを取得する前に止まります。保存済みの古い`Install.cmd`も旧版専用です。

```powershell
# 新しいReleaseからダウンロードしたInstall.cmdを、既存の範囲・設置先で実行
.\Install.cmd -Scope $scope -InstallRoot $installRoot -DataRoot $dataRoot
```

新しいインストーラーは既存の`immich.env`と設置先を読み、新版の更新処理へ引き継ぎます。アンインストールやDB・写真の作り直しは不要です。更新時に`-MediaRoot`やDB設定の上書き引数は渡さないでください。この初回更新後は、新しいトレイから末尾`.0`の版も更新できます。


手動で実行する場合：

```powershell
& "$installRoot\current\installer\Update-FromRelease.ps1" -Scope $scope -InstallRoot $installRoot -DataRoot $dataRoot
```

版を指定する場合は`-Version 'v3.2.4.0'`のようにWindows改訂を含めます。バージョンの4桁目はWindows改訂番号です。同じ版の上書きやダウングレードはしません。

### 更新中の表示

ファイル確認・コピーでは処理名、実際の処理件数、経過時間を表示します。件数の総数が分かったコピーでは処理済み/総数を表示し、長い処理の表示は約2秒間隔に抑えます。依存インストールの出力は終了まで隠さず、その場で表示します。停止・DBバックアップ・切り替え・起動・動作確認も開始/完了を表示します。表示はWindows表示言語に応じた日本語または英語です。

コンソールのタイトルに「選択」と表示される場合はEscで選択を解除してください。文字選択によって出力が一時停止する場合があります。

### 依存ファイルの再利用

更新時は現在のインストールを先に調べます。同じNode・FFmpeg・Valkey・WinSWは、要求する配布物の情報を照合して新版の準備領域へローカルコピーします。ZIPキャッシュがなくても再取得しません。uv・pnpmは既存の版別ツールを引き続き使います。

Nodeの依存はpackage.json・ロックファイル・インストール設定・同梱SDKの内容が同じ場合、プロジェクトごとに再インストールを省きます。Pythonは同じランタイムを再利用し、requirementsが変わった場合だけ同期します。この内部Pythonはモジュールとして起動するため、旧パスを埋め込んだScriptsのランチャーは複製しません。

pnpmが必要な場合も、固定ロックファイルと共有ストアを使い、`--prefer-offline`で保存済みデータの再確認を避け、不足分だけ取得します。uvは既存のキャッシュを使います。キャッシュを使うために追加の独自パッケージ管理やオフライン失敗後の再試行は行いません。

Sharp・PostgreSQL拡張・VCランタイムは、新版のファイル別SHA256と旧版の実ファイルを照合します。版番号が同じでも中身が変われば更新します。不足・変更したnativeファイルがある場合は配布単位のnative ZIPを取得し、必要なファイルを取り込みます。アプリ本体の配布ZIPは毎回取得します。バイナリ差分配信ではありません。

稼働中の旧版を直接書き換えたり、旧版と書き込み可能なファイルを共有したりしません。不完全な依存や予期しないリンクは再利用せず、通常の取得・インストールに戻します。

同じ更新の中で依存準備を二度実行しません。停止後にDB関連ファイルを一度比較して、その結果に従ってバックアップと切り替えを行います。Node・FFmpegなどの展開済み一時ファイルは移動して配置し、同じボリュームでのコピー後削除を避けます。既存版から新版への独立した依存コピーと、アプリZIP全体の取得は引き続き行います。Sharpの差し替えは別ファイルを作ってから置き換え、pnpmのハードリンク先やキャッシュを上書きしません。

### 更新中の処理とバックアップ

- 新しい版の依存ファイルを別のreleaseディレクトリに準備してから、稼働中のImmichを停止します。準備失敗時は稼働中の版を止めません
- 本体commit、サーバーコード・依存ロック、Node、PostgreSQL拡張・VCランタイムの内容が同一と確認できる改訂では、更新用DBバックアップとインストーラーのDB変更処理を省きます。版番号だけで省略しません
- 本体・DB関連の変更、または同一性を確認できない場合は、停止後にDBバックアップを作ってから更新します。バックアップ失敗時には切り替えません
- 写真・動画全体のコピーは行いません。通常の写真・DBバックアップは別途維持してください
- 切り替え後に起動とスモークテストを行います。失敗時はエラーを表示して停止し、CPUや旧版へ自動切り替えしません
- 起動・スモークテストが成功して更新を確定した後、この更新で記録した直前版のディレクトリだけを削除します。`releases`一覧は走査せず、以前から溜まっていた旧版には触れません。写真・動画、DB、設定、モデル、共有キャッシュは削除しません。リンク、保存先の重なり、使用中のファイルなどで安全に削除できない直前版は残して警告します。整理の失敗で正常なサーバーを止めません。トレイ・Install.cmd・手動更新は共通の処理を使い、動作確認後に同じユーザー・セッションの旧トレイへ終了を通知し、プロセス終了を待ってから直前版を削除し、新版のトレイを起動します。削除に失敗しても新版トレイの起動を試みます。別の管理者アカウントで昇格した場合は他ユーザーのトレイを操作せず警告します。その場合は元のユーザーで旧トレイを終了してから残った直前版を整理してください

### 更新に失敗した場合

`$dataRoot\state\upgrade-recovery.json`に状態を保存します。準備中・DBバックアップ前の失敗なら新しい版はまだDBに触れていません。原因を解消して再実行できます。切り替え・起動後に失敗した場合は、原因を確認して明示的に復旧します：

```powershell
& "$installRoot\current\installer\Recover-Upgrade.ps1" -Scope $scope -InstallRoot $installRoot -DataRoot $dataRoot
```

`current`がない場合は、展開済みの候補パッケージ内の`installer/Recover-Upgrade.ps1`を同じ引数で実行します。DB変更を伴う更新の復旧は、対応するDBバックアップへ戻すため更新後のDB書き込みを失います。DB同一性を確認した更新ではDBを復元せずアプリ・設定だけを戻します。復旧はいずれも確認を求めます。

この復旧手順は、失敗した更新で旧版が残っている場合のものです。正常更新後の整理で旧版が削除された後は、その旧版への即時切り戻しはできません。作成済みのDBバックアップは別に保持します。

CurrentUserでPostgreSQL拡張の版も変わった場合は、管理者が旧版に対応する拡張を準備してから復旧します。DBを変更した更新では、アプリだけ旧版へ戻して更新後のDBを開かないでください。

## DBバックアップ

```powershell
& "$installRoot\current\migration\New-DatabaseBackup.ps1" -EnvFile $envFile
```

保存先は既定で`$dataRoot\database-backups`です。変更する場合は`-DestinationDirectory 'E:\ImmichBackup'`を追加します。DBバックアップに写真・動画は含まれないため、メディアと`immich.env`は別途保管します。復元コマンドと起動前の確認は[移行手順](migration.md)を参照してください。

## アンインストール

```powershell
& "$installRoot\current\installer\Uninstall.ps1" -Scope $scope -InstallRoot $installRoot -DataRoot $dataRoot
```

常駐登録とアプリを削除します。PostgreSQL、DB、アプリ外のメディア、設定・ログ・モデルキャッシュは残ります。設定先も削除する場合のみ`-RemovePersistentData`を付けます。
