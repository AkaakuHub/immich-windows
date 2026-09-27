# immich-windows

ImmichをWindows x64でネイティブ実行するための非公式プロジェクトです。PostgreSQL、Valkey、Immich Server、Machine LearningをWindows上で動かします。本番実行にDocker、WSL2、Linux VMは使いません。

Immich本体はforkせず、[upstream.json](upstream.json)で固定した上流の版に[Windows patch](patches/README.md)を適用します。DB schemaとmigrationは上流のままです。Windows固有の修正だけをpatchとして管理します。

ビルドにはPowerShell 7、Git for Windows、Visual Studio Build Tools、LLVM、Rust、PostgreSQLが必要です。custom libvipsを作る工程だけDockerのLinuxコンテナを使用します。本番PCにビルドツールは必要ありません。

生成物はWindowsネイティブのパッケージディレクトリです。インストールと更新のスクリプトが含まれ、公開Releaseからの更新にも対応します。GitHub Actionsは上流の新版確認、patch適用の監査、Windowsパッケージのビルドを行います。

インストール範囲は`-Scope AllUsers`または`-Scope CurrentUser`で選べます。`AllUsers`はProgram FilesとProgramDataに配置し、Windowsサービスとして起動するため管理者権限が必要です。`CurrentUser`は`%LOCALAPPDATA%`に配置し、ユーザー権限でログオン中に常駐します。サインイン時に起動するよう現在のユーザーへ登録します。PostgreSQL本体と、パッケージと同じ版のpgvector、VectorChordが事前に利用可能である必要があります。更新と削除にも同じ`-Scope`を指定します。

パッケージ内の`Install.cmd`を起動すると、範囲や不足している設定を対話式に入力できます。既存の`.env`を指定する場合は、`Install.cmd -EnvFile "C:\path\to\.env" -Scope AllUsers`のように渡します。`DB_PASSWORD`などのDB設定を引き継ぎ、既存`.env`自体は書き換えません。`UPLOAD_LOCATION`が相対パスの場合は、Windows上のメディアルートを尋ねます。従来の`Install.ps1`の引数も引き続き使えます。

Linux/WSL2からの移行では、同じImmich版を使用し、PostgreSQLの論理バックアップをWindowsへ復元します。NTFS上のメディアは元の場所を使用できます。手順と設計は[architecture.md](docs/architecture.md)を参照してください。
