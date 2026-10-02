# 起動・更新・バックアップ

PowerShell 7で操作します。AllUsersは管理者として、CurrentUserは導入したユーザーとして実行してください。

## スタートメニュー

**Immich** フォルダーに、本家Immichのアイコンを使った4つの項目を登録します。

- **Immichを開く**：保存済みの接続先・ポートで既定ブラウザーを開きます
- **Immichを起動**：サーバーと機械学習を起動します
- **Immichを停止**：サーバーと機械学習を停止します。写真・設定は残ります
- **Immichを更新**：更新の進行状況を表示し、最新版へ更新します

起動・停止はバックグラウンドで処理し、失敗時はエラーダイアログを表示します。AllUsersの起動・停止・更新にはWindowsの管理者確認が出ます。「開く」は昇格せず、ブラウザーも通常権限で開きます。接続先は開くたびに`immich.env`から読みます。

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

スタートメニューの **Immich → Immichを更新** を開きます。AllUsersの場合は管理者確認に応答します。最新のWindows版を取得し、既存の設置先・写真・設定を維持して停止・更新・再起動します。最新版なら何も変更せず終了します。

旧形式の`v3.2.2`などから最初に移行する場合だけ、最新Releaseの`Install.cmd`を実行します。標準の設置先が1つなら自動検出します。設置先を変更した環境は最初の1回だけ既存の`-Scope`、`-InstallRoot`、`-DataRoot`を指定してください。旧版の更新スクリプトは4桁の版を認識しないため、そのままでは移行できません。導入後は上記ショートカットを使えます。

手動で実行する場合：

```powershell
& "$installRoot\current\installer\Update-FromRelease.ps1" -Scope $scope -InstallRoot $installRoot -DataRoot $dataRoot
```

版を指定する場合は`-Version 'v3.2.2.2'`のようにWindows改訂を含めます。`v3.2.2.1 → v3.2.2.2`は同じImmich本体のWindows改訂です。同じ版の上書きやダウングレードはしません。

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
