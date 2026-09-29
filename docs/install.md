# 導入手順

## 1. PowerShell 7とPostgreSQLを準備する

Windows x64とインターネット接続が必要です。[PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows)を導入し、`pwsh`を実行できる状態にします。以降の操作はPowerShell 7で行います。

[PostgreSQLのWindows版](https://www.postgresql.org/download/windows/)からPostgreSQL 18 x64をインストールし、サービスを起動してください。ImmichのインストーラーはPostgreSQL本体をインストールしません。

既定の設置先は`C:\Program Files\PostgreSQL\18`、サービス名は`postgresql-x64-18`です。変更した場合は`Install.cmd`に`-PostgresRoot`と`-PostgresService`を渡します。

既存の`.env`の`DB_PASSWORD`を引き継ぐ場合、WindowsのPostgreSQLにも同じユーザー名・パスワードを用意します。標準の`postgres`を使う場合はPostgreSQL導入時のパスワードを合わせます。インストーラーは認証情報を利用しますが、既存のPostgreSQLユーザーのパスワードは変更しません。指定ユーザーにはDB・拡張を作成できる権限が必要です。

## 2. Install.cmdをダウンロードする

[Releases](https://github.com/AkaakuHub/immich-windows/releases)の`Install.cmd`をダウンロードします。実行すると、同じReleaseのアプリZIPを自動取得・展開します。CMDはZIPに含めません。GitHubが表示する`Source code`は導入用ではありません。

`native-dependencies.zip`もインストーラーが自動取得します。Node.js、Python、pnpm、FFmpeg、Valkeyの手動インストールや、本番PCでのコンパイルは不要です。

## 3. インストール範囲を選ぶ

| 項目 | AllUsers | CurrentUser |
| --- | --- | --- |
| 常駐開始 | PC起動時 | ユーザーのサインイン時 |
| Immich導入の権限 | UACで管理者承認 | 通常のユーザー権限 |
| アプリの既定位置 | `C:\Program Files\Immich` | `%LOCALAPPDATA%\Programs\Immich` |
| 設定・ログの既定位置 | `C:\ProgramData\Immich` | `%LOCALAPPDATA%\Immich` |
| PostgreSQL拡張の配置 | インストーラーが実施 | 事前に管理者が実施 |

常時稼働するサーバーには、サインアウト後も動くAllUsersを選びます。CurrentUserのインストール先と設定先は`%LOCALAPPDATA%`配下に指定します。両方を同じPCで動かす場合はDB名、メディア、Server・ML・Valkeyのポートを分けてください。

これらは`-DatabaseName`、`-MediaRoot`、`-ServerPort`、`-MachineLearningPort`、`-RedisPort`で指定できます。

### CurrentUserの拡張準備

PostgreSQLサービスと拡張の初期設定は管理者が行います。対象Releaseの`native-dependencies.zip`を別フォルダーへ展開し、メインZIPを展開した場所で管理者のPowerShellから次を実行します。

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\installer\Install-PostgresExtensions.ps1 `
  -PackageRoot 'C:\Users\user\Downloads\native-dependencies' `
  -AdminPassword 'PostgreSQLで設定したパスワード'
```

`-PackageRoot`には`dependencies`フォルダーを含む展開先を指定します。pgvector・VectorChordの配置とPostgreSQLの設定変更・再起動を行います。既に対象版の拡張が利用できる場合、この準備は不要です。拡張が更新された場合も管理者による配置が必要です。

## 4. Install.cmdを実行する

ダウンロードした`Install.cmd`をダブルクリックし、範囲、既存の`.env`、メディアフォルダー、DBパスワードを指定します。AllUsersを選ぶとUAC確認が表示され、承認後に処理が続きます。写真を置くフォルダーは事前に作成してください。

引数を指定する場合も、同じインストーラーを使います。

```powershell
.\Install.cmd -Scope AllUsers -EnvFile 'D:\immich\.env' -MediaRoot 'D:\Photos\Immich' -InstallRoot 'C:\SharedC\immich-app'
```

`.env`のDB名・ユーザー名・パスワードなどを読み込み、Windowsで必要なホスト名と実行パスを設定します。`DB_HOSTNAME=database`はローカルのPostgreSQLへ、`UPLOAD_LOCATION=/mnt/d/...`は`D:\...`へ変換します。それ以外のLinuxパスはWindowsの実パスを入力してください。元の`.env`は設定先の`immich.env`へ取り込みます。

`DB_URL`・`REDIS_URL`形式は導入時に使用しません。接続先を`DB_HOSTNAME`・`DB_PORT`・`DB_USERNAME`・`DB_PASSWORD`・`DB_DATABASE_NAME`と、`REDIS_HOSTNAME`・`REDIS_PORT`・`REDIS_USERNAME`・`REDIS_PASSWORD`へ分けて指定してください。内蔵Valkeyは既存の`REDIS_PASSWORD`を設定し、ユーザー名は未指定または`default`を使います。独自のRedis ACLユーザーを使う場合は`-RedisMode External`で既存のRedisへ接続します。

メディア・DBのデータはアプリのインストール先と分けます。`current`が現在のアプリを指すため、バージョン更新でも利用するパスは変わりません。設定先を変える場合は`-DataRoot`を指定します。

成功後は`http://127.0.0.1:2283/`へアクセスします。新規DBには最初の管理者を作成します。既存DBを移行する場合は、[移行手順](migration.md)に従って`-DoNotStart`付きで導入してください。これは直後の起動だけを抑止し、自動起動の登録は行います。

依存取得に失敗した場合はエラーを確認し、同じReleaseの`Install.cmd`と同じ引数に`-ResumeExistingRelease`を追加して再実行します。コピー済みのアプリから依存の設定を再開します。別のReleaseにはこの引数を使いません。
