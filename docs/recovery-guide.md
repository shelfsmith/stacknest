# StackNest ライブラリDB 復旧ガイド

StackNest は編集後にライブラリ DB の世代バックアップをバンドル内 `Backups/` に保存します（Phase 2.8 B22）。
通常はアプリ起動時に破損を検知し「最新の正常なバックアップから復元しますか？」と案内します。
自動復元で直らない・もっと古い状態に戻したい場合は、以下の手順を参照してください。

> 作業前に、必ずライブラリバンドルごと別の場所にコピーしてバックアップを取ってください。

## 1. バックアップの場所

```
<ライブラリ名>.stacknest/Backups/library-<日時>.sqlite
```

新しいものほど日時（`yyyyMMdd-HHmmss`）が大きい。Finder で開くには、`.stacknest` を右クリック →「パッケージの内容を表示」。
バックアップは編集のあったセッションを閉じるたびに 1 世代追加され、設定した世代数を超えると古いものから削除されます（世代数はライブラリ設定で変更可）。

## 2. 手動で世代を差し戻す

1. StackNest を終了する。
2. バンドル直下の `library.sqlite` を `library.broken.sqlite` にリネーム（退避）。
3. `Backups/` の戻したい世代を、バンドル直下に `library.sqlite` という名前でコピー。
4. `library.sqlite-journal` / `library.sqlite-wal` / `library.sqlite-shm` が残っていれば削除する（古い状態と不整合を起こすため）。
5. StackNest で開き直す。

> アプリの異常ダイアログで「復元する」を選んだ場合、壊れた本体は自動で `library.corrupt-<日時>.sqlite` に退避されます。手動で `.recover`（手順 3）したいときはこのファイルを入力に使えます。

## 3. `sqlite3 .recover` による修復（最終手段）

バックアップも壊れている、あるいは世代が存在しない場合は、SQLite 同梱の復旧コマンドで救出を試みます。
`library.broken.sqlite`（または退避された `library.corrupt-<日時>.sqlite`）を入力に:

```bash
sqlite3 library.broken.sqlite ".recover" | sqlite3 library.recovered.sqlite
```

成功したら `library.recovered.sqlite` を上記「2. 手動で世代を差し戻す」の手順 3〜5 と同様に `library.sqlite` として配置します。

`.recover` は壊れた B-tree からできる限りのデータを救い出すコマンドで、完全性は保証されません（一部レコードの欠落・順序変化が起こりえます）。
StackNest 本体にはこの機能を組み込んでいないため、CLI で手動実行してください。

## 4. それでも開けないとき

`.recover` 後も開けない場合、その DB は救出不能の可能性があります。
画像ファイル本体はライブラリ DB の外（元の場所）にあり消えていないため、新規ライブラリを作成して再インポートすれば、メタデータ（タグ・評価・シリーズ等）は失われますが画像はそのまま管理し直せます。
