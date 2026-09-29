# パッチ方針

このリポジトリはImmichのWindows配布用です。上流のソースと履歴をマージ・submodule化しません。`upstream.json`の固定tag/commitへ、`patches/series`の順序でパッチを適用します。

- パッチは1つの目的に絞り、Windowsで必要な差分だけにします。
- DBスキーマ、マイグレーション、API、データモデルは変更しません。
- Linuxでの動作を維持するクロスプラットフォーム実装を優先します。
- `.work/immich`を直接変更せず、`patches/`の差分を更新します。
- `Prepare-Source.ps1`で上流への適用を確認します。適用不能なパッチを無視しません。
- 同じ対応が上流へ入ったら、このリポジトリのパッチを削除します。

## 対応箇所

| パッチ | 目的 |
| --- | --- |
| `server/0001-*` | FFmpegの出力先にOSのnullデバイスを使います |
| `server/0002-*` | PostgreSQLコマンドの場所とnull出力に対応します |
| `server/0003-*` | Windowsのドライブ・UNC絶対パスを扱います |
| `server/0004-*` | WindowsでGNU gzipへの依存をなくします |
| `server/0005-*` | メディア移行でWindowsのパス区切りに対応します |
| `server/0006-*` | メディアルートの内外判定にOSのパス規則を使います |
| `server/0007-*` | Windowsパスでフォルダー一覧を作成します |
| `server/0008-*` | 外部ライブラリのパスをglob用に変換します |
| `machine-learning/0001-*` | Windowsでは同じMLアプリをUvicornで起動します |

上流更新と検証の実行手順は[開発手順](../docs/development.md)にまとめています。
