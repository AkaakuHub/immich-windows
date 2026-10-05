# 構成

Immichの固定tag/commitに、Windows向けの`patches/series`、メタデータ補正用の`metadata-patches/series`の順でパッチを適用します。上流版は`upstream.json`、依存版は`dependencies/versions.json`で管理します。

## ビルドと配布

- ActionsでServer・Web・CLI・プラグインとWindows用のpgvector・VectorChord・libvipsをビルドします。
- アプリとネイティブDLLを別のZIPで配布します。
- ランタイムと依存は導入時に取得します。
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

PostgreSQLのデータとメディアは別の場所に置きます。AllUsersはWindowsサービス、CurrentUserはサインイン時に起動するプロセスを使います。

## 更新と復旧

更新前にDBをバックアップし、停止中に`current`を切り替えます。起動後の確認に失敗した場合は、旧版とバックアップの組から復旧します。

WindowsパッチはOS依存のパス、プロセス、外部コマンドに限定します。OS非依存のメタデータ補正は別の`metadata-patches/`で管理し、同じソース準備・上流更新・検証経路を使います。
