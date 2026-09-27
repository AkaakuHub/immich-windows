# immich-windows

ImmichをWindows x64でネイティブ実行するための非公式プロジェクトです。PostgreSQL、Valkey、Immich Server、Machine LearningをWindows上で動かします。本番実行にDocker、WSL2、Linux VMは使いません。

Immich本体はforkせず、[upstream.json](upstream.json)で固定した上流の版に[Windows patch](patches/README.md)を適用します。DB schemaとmigrationは上流のままです。Windows固有の修正だけをpatchとして管理します。

ビルドにはPowerShell 7、Git for Windows、Visual Studio Build Tools、LLVM、Rust、PostgreSQLが必要です。custom libvipsを作る工程だけDockerのLinuxコンテナを使用します。本番PCにビルドツールは必要ありません。

生成物はWindowsネイティブのパッケージディレクトリです。インストールと更新のスクリプトが含まれ、公開Releaseからの更新にも対応します。GitHub Actionsは上流の新版確認、patch適用の監査、Windowsパッケージのビルドを行います。

Linux/WSL2からの移行では、同じImmich版を使用し、PostgreSQLの論理バックアップをWindowsへ復元します。NTFS上のメディアは元の場所を使用できます。手順と設計は[architecture.md](docs/architecture.md)を参照してください。
