# StackNest 用語集（日本語 → 英語）

この表が訳語の正本。新しい語を訳したらここに追記する（spec §6 は起点の写し）。
文体: メニューとボタンは Apple HIG の Title Case、説明文とエラーは文頭だけ大文字の文、省略記号は `…`（U+2026）。

| 日本語 | 英訳 | 備考 |
|---|---|---|
| ライブラリ／庫 | Library | 「庫」は略称。英語では区別しない |
| シェルフ／棚 | Shelf | |
| スマートシェルフ | Smart Shelf | |
| 本・書籍 | Book | 画像セット・動画も含めて Book |
| 巻 | Volume（略記 Vol.） | 巻送りは next/previous volume |
| シリーズ | Series | |
| 内蔵ビューア／外部ビューア | Built-in Viewer／External Viewer | |
| 表紙 | Cover | |
| 見開き | Two-Page Spread（短縮時 Spread） | |
| ページ送り | Page Turn | |
| 巻末 | End of Volume | |
| 続きから読む | Resume Reading | |
| ルーペ | Magnifier | |
| スタンプ | Stamp | |
| ブラウザ（属性列） | Browser | Web ブラウザと紛れる箇所は Column Browser |
| レート | Rating | |
| 未読／既読 | Unread／Read | |
| ロック／解錠 | Lock／Unlock | |
| 共有 | Sharing | |
| グラント | Access Grant | |
| トークン／編集トークン | Token／Edit Token | |
| リモート | Remote | |
| オフライン | Offline Copy／Available Offline | |
| 監視フォルダ | Watched Folder | |
| 取り込み | Import | |
| 破損チェック | Integrity Check | CLI の `integrity` と揃う |
| リンク切れ／再リンク | Missing File／Relink | |
| お知らせ | Notice | |
| 厚い本／薄い本／本の一部／画像セット／テキスト／ムービー | Thick Book／Thin Book／Part of Book／Image Set／Text／Movie | 既存訳のまま |
| ネタ | Content Notes | 書籍メタデータの自由記述欄（memo とは別枠）。CLI/MCP の `--neta`/`neta` は識別子のまま |
| ゴミ箱 | Trash | macOS 標準訳語 |

**文体**: メニューとボタンは Apple HIG の Title Case（例 "Reveal in Finder"）。説明文とエラー文は文頭だけ大文字の文。省略記号は `…`（U+2026）。
実装中に出た語は `docs/l10n-glossary.md` に追記する（そちらが正本。この表は起点）。

## 追加語彙（U5・ヘルプ英訳で新規に訳出した語）

| 日本語 | 英訳 |
|---|---|
| 命名プリセット | Naming Preset |
| 簡易チェック | Quick Check |
| 詳細（CRC）チェック | Detailed (CRC) Check |
| ページ送りの演出 | Page Turn Effect |
| ノンブル（章ごとのページ番号） | Page Number |
| 全画面で開く | Open in Full Screen |
| 配信インジケータ | Broadcast Indicator |
| 共有トークン | Sharing Token |

## 追加語（Task 16 / U8 Web で判明）

| 日本語 | 英訳 | 備考 |
|---|---|---|
| タイトル | Title | ソート項目・詳細列見出し |
| 作者／著者 | Author | Web の一覧では 2 種の日本語表記が混在（既存コード）。英訳はどちらも Author に統一 |
| ジャンル | Genre | ファセット ブラウズの列 |
| 追加日 | Date Added | |
| 最終読書／最終読書日 | Last Read／Last Read Date | 詳細行は「最終読書」、ソート項目は「最終読書日」（別の日本語文字列） |
| 評価 | Rating | レート（既存用語集）と同義の別表記 |
| 進行 | Progress | 詳細シートの読書進捗行 |
| ページ数 | Pages | |
| 検索／並び替え | Search／Sort | |
| グリッド／リスト／カラム（表示モード） | Grid／List／Column | ビュー切替セグメント |
| 表示件数 / スクロール | Items Per Page / Scroll | per-page ＋無限スクロールの統合セレクタ |
| 無限 | Unlimited | 上記セレクタの無限スクロール選択肢 |
| すべて | All | ファセット列の先頭項目（選択解除） |
| ステップ | Steps | 狭幅 column stepper のパンくず nav の aria-label |
| ペアリング | Pairing | Web 版のペアリング画面タイトル |
| トークン／パスワード | Token／Password | 入力欄のプレースホルダ |
| 接続／解錠 | Connect／Unlock | ボタン |
| 設定 | Settings | リーダーの歯車ボタン |
| リーダー設定 | Reader Settings | リーダー設定シートの見出し |
| 読み方向 | Reading Direction | |
| キャッシュ上限 | Cache Limit | |
| フル先読み（Tier3） | Full Prefetch (Tier 3) | |
| (無題) | (Untitled) | タイトル未設定の本のプレースホルダ |
| 本の詳細 | Book Details | 詳細モーダルの aria-label |
| 次の巻へ／先頭へ／本を閉じる | Next Volume／To the Beginning／Close the Book | 巻末ダイアログのボタン |
| 続きから（reader.js の巻送りダイアログ） | Resume | 「続きから読む」（Resume Reading）より短い、巻送り確認ダイアログ専用の文言 |

## G55 U7（CLI／MCP）追記（2026-09-27）

- CLI の `--help`／`abstract` は名詞句・小文字始まりの短いフレーズ（例 "Access token"）。エラー文・確認文は文（例 "Error: Not found (HTTP 404)."）。
- 複数形は `L10nEntry(one:other:)` で分岐。`%d 冊` → one "%d book" / other "%d books" のように単位語も英訳する。
- MCP（`mcp-stacknest/`）はテーブルを持たず、docstring と例外メッセージを直接英語で書く（言語切り替えなし・spec §1）。

## 実装中に追加した語（U1・2026-09-27）

| 日本語 | 英訳 | 備考 |
|---|---|---|
| メタデータ | Metadata | Finder タグ同期の対象フィールド未設定時の既定表示 |
| フィルタ | Filter | ツールバーボタン／ポップオーバー見出し兼用（単数形） |
| 詳細ペイン | Detail Pane | 右側パネルの呼称 |
| Finder タグ | Finder Tag(s) | 複数形は文脈依存（%lld との組み合わせ時は数値側で表現） |
| 同期／再照合 | Sync／Re-sync | 「今すぐ再照合」= "Re-sync Now" 相当 |
| ゴミ箱 | Trash | macOS 標準語彙 |
| ページ数 | Page Count | スマートシェルフの条件フィールド名 |
| 追加日 | Date Added | スマートシェルフの条件フィールド名 |
| 最終閲覧日 | Last Read Date | スマートシェルフの条件フィールド名（本文中の「続きから読む」とは別語） |
| 既読状態 | Read Status | フィルタポップオーバーの見出し |
| 消去 | Clear | スタンプ／テキストフィールドの値クリア chip・ボタン |
| スマートシェルフの演算子（が次と等しい／を含む／で始まる／で終わる／以上／以下／より前／である／ではない） | Equals／Contains／Starts With／Ends With／At Least／At Most／Before／Is／Is Not | Picker 項目、Title Case で統一 |
| 以内（日付フィルタ・スマートシェルフ共用） | within | 開発者コメント指定の訳（`DateFilterRow.swift`）。小文字のまま流用 |
| 以前 | older than | 同上 |
| ・（箇条書きの行頭記号として使う場合） | • (U+2022) または `, `（列挙の区切り） | 日本語のナカグロは英語では箇条書き記号／区切りとして意味を持たないため、英訳では US プレフィックス記号に置き換える（表示文字列そのものの変更で JA 側は不変） |

## 追記（G55 U2・内蔵ビューア／EPUB／メニュー／ウィザード／表紙・リネーム・再リンク系シート）

| 日本語 | 英訳 | 備考 |
|---|---|---|
| 単ページ | Single Page | 見開き（Spread）の対 |
| 上ペイン | Top Pane | ブラウズ／スタンプ／伏せ字を切り替える領域 |
| ファセット | Facets | 上ペインの一モード |
| 伏せ字 | Hidden | 上ペインの一モード（隠した項目の表示） |
| 続きから／最初から | Continue／Start Over | 再開ダイアログの二択 |
| ページ方向 | Page Direction | 右→左 (Right to Left) ／左→右 (Left to Right) |
| キー操作 | Key Bindings | ビューア内キー割当ヘルプの見出し |

## 追加語（Task 11 / U3・設定タブ全般）

| 日本語 | 英訳 | 備考 |
|---|---|---|
| 自動追加 | Auto-Add | 監視フォルダの自動取り込み機能名（LibrarySettingsSheet の GroupBox 見出し） |
| 自動分類 | Auto-Classify | 本の種類の自動判定機能名 |
| 既定に従う（現在: …） | Follow the Default (Currently: …) | 3-way ピッカー（既定に従う/このライブラリで有効/無効）の共通句 |

## 追記（U4・G55 リモート/オフライン/破損チェック）

| 日本語 | 英訳 | 備考 |
|---|---|---|
| お気に入り | Favorites | シェルフ一覧の特別項目。DB 保存名（`お気に入り`）は変えない（kind=="favorites" で判定・表示だけ訳す） |
| 管理者／編集可／閲覧のみ | Administrator／Editable／View Only | リモート接続 tier（admin/edit/read）の表示ラベル |
| プリセット／命名プリセット | Preset／Naming Preset | ファイル名フォーマットのプリセット |
| 破損／劣化 | Damaged／Degraded | 破損チェックの状態。「劣化」は前回 OK→今回破損（ビット腐敗疑い） |
| バックアップ | Backup | |
| メンテナンス | Maintenance | メタデータ補完・表紙再生成などの長時間ジョブの総称 |
| 自動分類 | Auto-Categorization | 本の種類の自動判定設定 |
| サブフォルダ | Subfolder | 取り込み設定の階層扱い |
| 中断（実行中の処理を止める操作・状態） | Stop／Stopped | 「キャンセル」ではなく実行中ジョブの停止を指す（スキャン・メンテナンス・ダウンロードの中断ボタンと要約文言の両方で使う語を統一） |

## 追記（U4 fix round 1）

| 日本語 | 英訳 | 備考 |
|---|---|---|
| ロック解除（パスワードロックを外す操作＝ disableLock） | Remove Lock | 「解錠」（生体認証/Apple Watch によるセッションの解錠）とは別物。ロック設定そのものを外す操作・確認文言に使う（U3 の LibrarySettingsSheet+Lock.swift と共有キーのため訳を揃える） |

## 追記（Task 14 / U6・AppCore・LibraryStore・アダプタ・サーバ）

| 日本語 | 英訳 | 備考 |
|---|---|---|
| タイトル／作者／ジャンル／登録日／読んだ日／未読／種類／関連／メモ／シリーズ／巻数 | Title／Author／Genre／Date Added／Date Read／Unread／Type／Relation／Memo／Series／Volume | 列ヘッダ・スタンプ・ブラウズ共通のフィールド名（BookColumn/StampField/LibrarySettings で共有） |
| キーワード A／B／C | Keyword A／B／C | |
| アーカイブ／画像／フォルダ／動画／テキスト | Archive／Image／Folder／Video／Text | `BookCategory`（ビューア設定の分類。書籍の種類ラベルとは別語彙） |
| 電子書籍 | E-Book | EPUB 用外部ビューア未設定時の表示名 |
| 円／正方形（ルーペの形） | Circle／Square | |
| 小／中／大（サイズ一般） | Small／Medium／Large | ルーペの大きさ |
| 全ライブラリ | All Libraries | グラントのスコープ表示 |
| ナビゲーション／ズーム／見開き・スライドショー／巻移動／その他 | Navigation／Zoom／Spread & Slideshow／Volume Navigation／Other | キー操作設定のセクション名 |
| 既定（プリセット名の種） | Default | 保存値は `既定` のまま。表示だけ `FilenameFormatPreset.displayName` で訳す |
| (既定) 閲覧／(既定) 編集（グラントの種） | (Default) View／(Default) Edit | 保存値は日本語のまま。表示だけ `GrantStore.displayLabel(for:)` で訳す |
| 厚い本 ほか 6 種（`@type` の値） | Thick Book ほか（上の表） | `canonicalLabel(for:)` はファイル名トークンなので日本語固定。表示は `BookTypeLabel.displayLabel(for:)` |

## 追記（Task S2-A・段 2 の穴埋め）

| 日本語 | 英訳 | 備考 |
|---|---|---|
| ファイル名では「%@」 | In filenames: “%@” | ラベル編集シートの本の種類行。英語 UI でのみ表示する補足キャプション（`@type` に入る正準名を明示）。日本語 UI では display==canonical のため出ない |
| libarchive の版不一致メッセージ | The libarchive header (%lld) and the runtime library (%lld) are different versions. | `LibarchiveVersion.mismatchMessage`。改行込みの単一キー（`Sources/StackNestL10n/Tables/L10n+Core.swift`） |
