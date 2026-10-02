# 導入手順

## 1. PowerShell 7とPostgreSQLを準備する

Windows x64とインターネット接続が必要です。[PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows)を導入してください。

[PostgreSQL 18 x64](https://www.postgresql.org/download/windows/)をインストールし、サービスを起動してください。

既定の設置先は`C:\Program Files\PostgreSQL\18`、サービス名は`postgresql-x64-18`です。変更した場合は`Install.cmd`に`-PostgresRoot`と`-PostgresService`を渡します。

既存の`.env`を使う場合、WindowsのPostgreSQLに同じDBユーザーとパスワードを用意してください。指定ユーザーにはDBと拡張の作成権限が必要です。インストーラーは既存ユーザーのパスワードを変更しません。

## 2. Install.cmdをダウンロードする

[Releases](https://github.com/AkaakuHub/immich-windows/releases)の`Install.cmd`をダウンロードします。GitHubの`Source code`は導入用ではありません。

必要な依存はインストーラーが取得します。

## 3. インストール範囲を選ぶ

| 項目 | AllUsers | CurrentUser |
| --- | --- | --- |
| 常駐開始 | PC起動時 | ユーザーのサインイン時 |
| Immich導入の権限 | UACで管理者承認 | 通常のユーザー権限 |
| アプリの既定位置 | `C:\Program Files\Immich` | `%LOCALAPPDATA%\Programs\Immich` |
| 設定・ログの既定位置 | `C:\ProgramData\Immich` | `%LOCALAPPDATA%\Immich` |
| PostgreSQL拡張の配置 | インストーラーが実施 | 事前に管理者が実施 |

サインアウト後も動かす場合はAllUsersを選びます。両方を同じPCで動かす場合はDB名、メディア、Server・ML・Valkeyのポートを分けてください。

これらは`-DatabaseName`、`-MediaRoot`、`-ServerPort`、`-MachineLearningPort`、`-RedisPort`で指定できます。

### CurrentUserの拡張準備

PostgreSQLサービスと拡張の初期設定は管理者が行います。対象Releaseの`native-dependencies.zip`を別フォルダーへ展開し、メインZIPを展開した場所で管理者のPowerShellから次を実行します。

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\installer\Install-PostgresExtensions.ps1 `
  -PackageRoot 'C:\Users\user\Downloads\native-dependencies' `
  -AdminPassword 'PostgreSQLで設定したパスワード'
```

`-PackageRoot`には`dependencies`フォルダーを含む展開先を指定します。対象版の拡張が既に利用できる場合、この操作は不要です。

## 4. Install.cmdを実行する

`Install.cmd`を実行し、範囲、`.env`、メディアフォルダー、DBパスワードを指定します。メディアフォルダーは事前に作成してください。

引数を指定する場合も、同じインストーラーを使います。

```powershell
.\Install.cmd -Scope AllUsers -EnvFile 'D:\immich\.env' -MediaRoot 'D:\Photos\Immich'
```

`.env`のDB名・ユーザー名・パスワードなどを読み込み、Windowsで必要なホスト名と実行パスを設定します。`DB_HOSTNAME=database`はローカルのPostgreSQLへ、`UPLOAD_LOCATION=/mnt/d/...`は`D:\...`へ変換します。それ以外のLinuxパスはWindowsの実パスを入力してください。元の`.env`は設定先の`immich.env`へ取り込みます。

`DB_URL`・`REDIS_URL`形式は導入時に使用しません。接続先を`DB_HOSTNAME`・`DB_PORT`・`DB_USERNAME`・`DB_PASSWORD`・`DB_DATABASE_NAME`と、`REDIS_HOSTNAME`・`REDIS_PORT`・`REDIS_USERNAME`・`REDIS_PASSWORD`へ分けて指定してください。内蔵Valkeyは既存の`REDIS_PASSWORD`を設定し、ユーザー名は未指定または`default`を使います。独自のRedis ACLユーザーを使う場合は`-RedisMode External`で既存のRedisへ接続します。

設定先を変える場合は`-DataRoot`を指定します。

成功後は`http://127.0.0.1:2283/`へアクセスします。新規DBには最初の管理者を作成します。既存DBを移行する場合は、[移行手順](migration.md)に従って`-DoNotStart`付きで導入してください。これは直後の起動だけを抑止し、自動起動の登録は行います。

### Machine LearningのDirectML

Windows版は`onnxruntime-directml`を使用し、CLIP、顔検出・顔認識、OCRのONNX推論をDirectML対応GPUへ送ることができます。`immich.env`で次を指定します。

```text
MACHINE_LEARNING_ACCELERATOR=cpu
MACHINE_LEARNING_DEVICE_ID=0
```

`MACHINE_LEARNING_ACCELERATOR`は`cpu`または`directml`です。既定の`cpu`は既存環境を維持するための明示的なCPUモードです。`directml`では未対応ノードのCPU実行、初期化失敗時・推論失敗時のCPU再試行をすべて禁止します。対応しないモデル・GPU・ドライバーは明確なエラーになります。以前の試験的な`directml-strict`設定は`directml`へ変更してください。

`MACHINE_LEARNING_DEVICE_ID`はDirectMLのDXGIアダプター番号です。複数GPUではDXGIのアダプター順を確認してください。タスクマネージャーのGPU番号と一致する保証はありません。画像デコード、リサイズ、NMS、OCRの後処理などONNXモデル外の処理はCPUで実行されます。

インストール引数で指定する場合は、例えば`-MachineLearningAccelerator directml -MachineLearningDeviceId 1`を使用します。新規導入時の値は`immich.env`へ保存されます。導入後はこのファイルを編集し、停止→起動で反映してください。AllUsersでも毎回のサービス起動時（PC起動時を含む）に読み直します。DirectMLの指定だけで全モデルの動作を保証するものではなく、RX 550上のCLIP・顔認識・OCRは実機で確認が必要です。

依存取得に失敗した場合はエラーを確認し、同じReleaseの`Install.cmd`と同じ引数に`-ResumeExistingRelease`を追加して再実行します。コピー済みのアプリから依存の設定を再開します。別のReleaseにはこの引数を使いません。

## 次回からの更新

スタートメニューの **Immich → Update Immich** を開きます。AllUsersはWindowsの管理者確認に応答してください。既存の設置先・設定を使って最新のWindows改訂へ更新します。詳しくは[更新手順](operations.md)を参照してください。
