# 上流と参照元

Immichの動作は上流実装を使用し、既存のネイティブ移植の構成も参考にしています。

## Immich

- [immich-app/immich](https://github.com/immich-app/immich)：Server、Web、ML、CLI、プラグイン、DBスキーマの上流です。
- [immich-app/base-images](https://github.com/immich-app/base-images)：公式Linux版のコーデックとネイティブ依存を確認する参照元です。

## ネイティブ構成

- [arter97/immich-native](https://github.com/arter97/immich-native)：LinuxでのServer・Web・MLの構築手順を参照しています。
- [daemonless/immich-server](https://github.com/daemonless/immich-server)：FreeBSDでのSharp・libvips・FFmpegの扱いを参照しています。
- [4v3ngR/immich-native-macos](https://github.com/4v3ngR/immich-native-macos)：macOS向けのネイティブ構成を参照しています。

## Windows依存

- [pgvector](https://github.com/pgvector/pgvector)、[VectorChord](https://github.com/supervc-stack/VectorChord)、[VectorChordのWindows移植例](https://github.com/grimmjoww/vchord-windows-port)
- [Valkey Windows](https://github.com/valkey-windows/valkey-windows)、[Jellyfin FFmpeg](https://github.com/jellyfin/jellyfin-ffmpeg)、[WinSW](https://github.com/winsw/winsw)
- [libvipsのWindowsビルド](https://github.com/libvips/build-win64-mxe)

採用するリポジトリと版は`dependencies/versions.json`を正とします。外部コードを取り込む場合はライセンスと帰属表示を確認し、配布物にも必要な表示を残します。
