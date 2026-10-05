# 日時メタデータのパッチ

Windows互換性の`patches/`とは別の目的の差分です。独立した適用処理は作らず、既存の`build/Prepare-Source.ps1`がWindowsの一覧に続けて`metadata-patches/series`を適用します。同じ内容ハッシュ・生成差分の検証・失敗時の復旧を使います。上流自動更新も両方を同じ順に処理し、競合時は停止します。

## 撮影日時のないファイル

対象は`MetadataService.getDates`で撮影日時を得られず、ファイル由来の日付へフォールバックする分岐だけです。

- 従来と同じ`earliestDate`（アップロード／外部ライブラリの`fileCreatedAt`、利用可能なbirthtime、mtimeの最も早い実時刻）を`dateTimeOriginal`に保存します
- 表示・タイムライン用の`localDateTime`は、その実時刻を採用したzoneへ変換してから`setZone('UTC', { keepLocalTime: true })`で保存します
- EXIF/GPS等から決まった`exifTags.zone`を優先します。なければLuxonが使うサーバープロセスのzone（`TZ`等）を使い、実際に採用したzoneを返します。利用者別のzoneを新設する変更ではありません
- 9時間などの固定値は加算しません。UTCや夏時間も同じ処理です
- 撮影日時がある分岐は、zoneがない場合を含めて変更しません。元画像、EXIF/XMP、DBスキーマやAPIはこのパッチでは変更しません

例：Tokyoで実時刻`03:00Z`のファイルなら、実時刻は`03:00Z`のまま、表示用の壁時計時刻を`12:00Z`として保存します。再処理も実時刻から計算し、9時間ずつ増えることはありません。

基準は[固定上流のgetDates](https://github.com/immich-app/immich/blob/db355f79d910bbfc6378117ed10868493c97b922/server/src/services/metadata.service.ts#L992)と[詳細表示](https://github.com/immich-app/immich/blob/db355f79d910bbfc6378117ed10868493c97b922/web/src/lib/components/asset-viewer/DetailPanelDate.svelte#L17)です。[Discussion #24116](https://github.com/immich-app/immich/discussions/24116)のzoneなし撮影日時を含めた変更案とは範囲が異なり、公式修正の取り込みではありません。

## 既存データについて

更新しただけで保存済み日時は変わりません。このパッチ自身は起動時のDB変更や一括再抽出を行いません。既存データの補正は別の[日時補正ツール](../runtime/metadata-date-repair/README.md)で、読み取り専用の計画を確認してから明示的に適用します。元ファイルの撮影日時・sidecar・保存値・ファイル日時を確認し、条件を満たしたasset IDの表示用日時とzoneだけを更新します。`timeZone`が空という条件だけでは対象を特定できません。

通常の「Refresh metadata」は日時専用処理ではありません。手動変更は読み取り可能なXMPに保存されていれば優先されますが、XMPの欠落・書き込み失敗や未反映の編集がある場合まで保護を保証できません。また、設定によってstorage templateのファイル移動やワークフロー、motion photo処理などが続きます。日時補正ツールはこのジョブを呼ばず、曖昧な対象を除外して保存値の競合も確認します。過去に削除されたsidecarや記録のないDB編集が存在しなかったことまでは保証できません。

テストは[開発手順](../docs/development.md)を参照してください。
