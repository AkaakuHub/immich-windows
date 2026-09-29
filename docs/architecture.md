# 構成

このリポジトリはImmich上流の固定tag/commitを取得し、Windows固有の差分を適用して配布物を作成します。上流の履歴は取り込みません。パッチの順序は`patches/series`、上流版は`upstream.json`、依存版は`dependencies/versions.json`で管理します。

## ビルドと配布

- ActionsでServer・Web・CLI・プラグインとWindows用のpgvector・VectorChord・libvipsをビルドします。
- メインZIPにはアプリ、依存定義、インストーラー、日本語の操作手順を含めます。
- ネイティブDLLは別の`native-dependencies.zip`へまとめます。
- Node.js、Python、FFmpeg、ValkeyなどのランタイムとNode・Python依存は導入時に固定版を取得します。
- DockerはlibvipsのWindows DLLをクロスビルドする工程だけで使います。

## インストール後

```text
InstallRoot\
  releases\vX.Y.Z\    アプリと、その版の実行用依存
  current\             選択中のreleaseを指すジャンクション
  tools\               pnpm・uv
  cache\               依存のダウンロード・インストールキャッシュ

DataRoot\
  immich.env           継続利用する設定
  logs\                ログ
  cache\               MLモデル
  valkey\              Valkeyデータ
  services\            サービス定義またはユーザープロセスのPID
  database-backups\    DBバックアップ
  state\               更新・復旧記録
```

PostgreSQLのデータとメディアフォルダーはこれらのアプリディレクトリとは別に置きます。AllUsersはWindowsサービス、CurrentUserはサインイン時の起動登録と通常のプロセスを使います。Immichの処理を転送する独自APIや常時ポーリングの監視レイヤーは追加しません。

## 更新と復旧

更新はDBバックアップを作成し、プロセス停止中に`current`を切り替え、起動後のスモークテストとスキーマ確認で成否を判断します。失敗時は停止して旧版とバックアップの組を記録します。復旧にはその組を使い、アプリだけの巻き戻しは行いません。

DBスキーマ、API、ジョブ、メタデータ、Web、Storage Template、モバイルとの通信は上流実装を使用します。WindowsパッチはOS依存のパス、プロセス、外部コマンドなどに限定します。
