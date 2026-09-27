# Linuxからの移行

同じImmichバージョンのPostgreSQL論理バックアップと、既存のメディアフォルダーをWindowsネイティブ版へ引き継ぎます。DockerのDBデータディレクトリはコピーしません。移行先のWindowsデータベースは`Import-Database.ps1`が削除して作り直すため、残しておく必要のあるDBには実行しないでください。

## 手順

1. Linux側と同じImmichバージョンのWindowsパッケージを使います。WindowsのPostgreSQL 18と、そのパッケージに含まれる版のpgvector、VectorChordを準備します。
2. Linux側でImmichを停止し、PostgreSQLのカスタム形式バックアップを作成します。`pg_dump -Fc --no-owner`で作成した`.dump`を使用できます。
3. Windowsにある既存のメディアフォルダーを`Install.cmd`の`-EnvFile`から読み込みます。Linuxの`.env`にある`DB_PASSWORD`は再利用されます。`UPLOAD_LOCATION`がLinuxの相対パスなら、インストーラーに実際のWindowsメディアルートを入力します。メディアファイルはコピーしません。
4. Windows版をインストールします。次のDB復元スクリプトは選択中の`AllUsers`または`CurrentUser`に応じてImmichを停止します。
5. `migration\Import-Database.ps1`に`.dump`とWindows側の`immich.env`を指定します。この処理は移行先のImmichデータベースを作り直してバックアップを復元し、Immichのサービスまたはユーザープロセスを停止したままにします。
6. パッケージの`runtime\launchers\immich-admin.ps1`から`change-media-location`を実行します。表示される質問には、Linux側で使っていたメディアルート（Docker内では通常`/data`）と、Windows側の`IMMICH_MEDIA_LOCATION`を指定して確認します。これは上流Immichのコマンドで、DB内のファイルパスの接頭部分を変更します。
7. 外部ライブラリを登録していた場合は、各Linuxパスを`migration\Change-ExternalLibraryPath.ps1`でWindowsパスへ変更します。`-Apply`を指定する前にプレビューを確認します。
8. `migration\Verify-Migration.ps1`で、DBの管理対象パスとWindows上の実ファイルを確認します。続けて`migration\Schema-Check.ps1`を実行します。
9. `AllUsers`ではImmichのWindowsサービスを起動し、`CurrentUser`では`runtime\launchers\Start-Immich.ps1`を実行します。API応答後、タイムライン、サムネイル、顔認識、Smart Searchを確認します。

Storage Templateの有効状態と日付形式はDB内のImmich設定に保存されています。復元後も設定が引き継がれ、メディアルートの変更では日付フォルダー部分を変更しません。Windowsで元ファイルにアクセスできることは、起動前に`Verify-Migration.ps1`で確認してください。

実データを使った復元確認は、Linux側のバックアップを受け取ってから行います。
