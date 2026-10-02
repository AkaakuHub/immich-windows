# 起動・更新・バックアップ

PowerShell 7で操作します。AllUsersは管理者として、CurrentUserは導入したユーザーとして実行してください。

## スタートメニュー

**Immich** フォルダーに、本家Immichのアイコンを使った4つの項目を登録します。文字列は日本語・英語のみを持ち、インストール・更新を実行したユーザーのWindows表示言語が日本語なら日本語、それ以外なら英語を選びます。追加ライブラリは不要です。

- **Immichを開く / Open Immich**：保存済みの接続先・ポートで既定ブラウザーを開きます
- **Immichを起動 / Start Immich**：サーバーと機械学習を起動します
- **Immichを停止 / Stop Immich**：サーバーと機械学習を停止します。写真・設定は残ります
- **Immichを更新 / Update Immich**：更新の進行状況を表示し、最新版へ更新します

起動・停止はバックグラウンドで処理し、失敗時はエラーダイアログを表示します。AllUsersの起動・停止・更新にはWindowsの管理者確認が出ます。「開く」は昇格せず、ブラウザーも通常権限で開きます。接続先は開くたびに`immich.env`から読みます。

Windowsの表示言語を変えた場合は「更新」を開くと、最新版が既に入っていてもメニューの言語を再生成します。以前の言語の項目は削除し、重複を残しません。AllUsersでは共有メニューのため、実行したユーザーの表示言語で統一されます。

アイコンは上流のWeb配布物に含まれる`favicon.ico`をそのまま使い、ネットワークから別途取得しません。

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

## 更新する（通常はショートカットだけ）

スタートメニューの **Immich → Immichを更新**（英語表示では **Update Immich**）を開きます。AllUsersの場合は管理者確認に応答します。最新のWindows版を取得し、既存の設置先・写真・設定を維持して停止・更新・再起動します。最新版の場合はアプリを変更せず、メニューの表示言語を反映します。

旧形式の`v3.2.2`などから最初に移行する場合だけ、最新Releaseの`Install.cmd`を実行します。標準の設置先が1つなら自動検出します。設置先を変更した環境は最初の1回だけ既存の`-Scope`、`-InstallRoot`、`-DataRoot`を指定してください。旧版の更新スクリプトは4桁の版を認識しないため、そのままでは移行できません。導入後は上記ショートカットを使えます。

手動で実行する場合：

```powershell
& "$installRoot\current\installer\Update-FromRelease.ps1" -Scope $scope -InstallRoot $installRoot -DataRoot $dataRoot
```

版を指定する場合は`-Version 'v3.2.2.2'`のようにWindows改訂を含めます。`v3.2.2.1 → v3.2.2.2`は同じImmich本体のWindows改訂です。同じ版の上書きやダウングレードはしません。

### 更新中の表示

ファイル確認・コピーでは処理名、実際の処理件数、経過時間を表示します。件数の総数が分かったコピーでは処理済み/総数を表示し、長い処理の表示は約2秒間隔に抑えます。依存インストールの出力は終了まで隠さず、その場で表示します。停止・DBバックアップ・切り替え・起動・動作確認も開始/完了を表示します。表示はWindows表示言語に応じた日本語または英語です。

コンソールのタイトルに「選択」と表示される場合はEscで選択を解除してください。文字選択によって出力が一時停止する場合があります。

v3.2.2の旧形式のML管理情報に依存定義のハッシュがなくても更新できます。その場合はコピー済みのパッケージをuvで確認・同期し、本当に変更された依存だけを更新します。旧CPU版のonnxruntimeからDirectML対応版への変更などは必要な更新です。

### 依存ファイルの再利用

更新時は現在のインストールを先に調べます。同じNode・FFmpeg・Valkey・WinSWは、要求する配布物の情報を照合して新版の準備領域へローカルコピーします。ZIPキャッシュがなくても再取得しません。uv・pnpmは既存の版別ツールを引き続き使います。

Nodeの依存はpackage.json・ロックファイル・インストール設定・同梱SDKの内容が同じ場合、プロジェクトごとに再インストールを省きます。Pythonは同じランタイムを再利用し、requirementsが変わった場合だけ同期します。この内部Pythonはモジュールとして起動するため、旧パスを埋め込んだScriptsのランチャーは複製しません。

Sharp・PostgreSQL拡張・VCランタイムは、新版のファイル別SHA256と旧版の実ファイルを照合します。版番号が同じでも中身が変われば更新します。不足・変更したnativeファイルがある場合は配布単位のnative ZIPを取得し、必要なファイルを取り込みます。アプリ本体の配布ZIPは毎回取得します。バイナリ差分配信ではありません。

稼働中の旧版を直接書き換えたり、旧版と書き込み可能なファイルを共有したりしません。不完全な依存や予期しないリンクは再利用せず、通常の取得・インストールに戻します。

### 更新中の処理とバックアップ

- 新しい版の依存ファイルを別のreleaseディレクトリに準備してから、稼働中のImmichを停止します。準備失敗時は稼働中の版を止めません
- 本体commit、サーバーコード・依存ロック、Node、PostgreSQL拡張・VCランタイムの内容が同一と確認できる改訂では、更新用DBバックアップとインストーラーのDB変更処理を省きます。版番号だけで省略しません
- 本体・DB関連の変更、または同一性を確認できない場合は、停止後にDBバックアップを作ってから更新します。バックアップ失敗時には切り替えません
- 写真・動画全体のコピーは行いません。通常の写真・DBバックアップは別途維持してください
- 切り替え後に起動とスモークテストを行います。失敗時はエラーを表示して停止し、CPUや旧版へ自動切り替えしません

### 更新に失敗した場合

`$dataRoot\state\upgrade-recovery.json`に状態を保存します。準備中・DBバックアップ前の失敗なら新しい版はまだDBに触れていません。原因を解消して再実行できます。切り替え・起動後に失敗した場合は、原因を確認して明示的に復旧します：

```powershell
& "$installRoot\current\installer\Recover-Upgrade.ps1" -Scope $scope -InstallRoot $installRoot -DataRoot $dataRoot
```

`current`がない場合は、展開済みの候補パッケージ内の`installer/Recover-Upgrade.ps1`を同じ引数で実行します。DB変更を伴う更新の復旧は、対応するDBバックアップへ戻すため更新後のDB書き込みを失います。DB同一性を確認した更新ではDBを復元せずアプリ・設定だけを戻します。復旧はいずれも確認を求めます。

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
