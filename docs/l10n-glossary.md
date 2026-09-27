# StackNest 用語集（日本語 → 英語）

この表が訳語の正本。新しい語を訳したらここに追記する（spec §6 は起点の写し）。
文体: メニューとボタンは Apple HIG の Title Case、説明文とエラーは文頭だけ大文字の文、省略記号は `…`（U+2026）。

段 1（8 単位の並列翻訳）の追記節は、段 2（Task S2-B・2026-09-27）で分野ごとの表にまとめ直した。
割れていた訳は 1 つに決め、決めた訳だけを残している（経緯は `.superpowers/sdd/2026-09-27-phase-g55-localization/task-S2B-report.md`）。
App の文字列カタログは **1 つの日本語キーに 1 つの英訳**しか持てない。同じ日本語を別の意味で使っている箇所は、S2-C で英語のドット区切りキーに分けた（§5）。

## 1. 基本語（起点の表）

| 日本語 | 英訳 | 備考 |
|---|---|---|
| ライブラリ／庫 | Library | 「庫」は略称。英語では区別しない |
| シェルフ／棚 | Shelf | サイドバーのセクション見出しは複数形 Shelves |
| スマートシェルフ | Smart Shelf | サイドバーのセクション見出しは複数形 Smart Shelves（キー `sidebar.section.smartShelves`・§5） |
| 本・書籍 | Book | 画像セット・動画も含めて Book |
| 巻 | Volume（略記 Vol.） | 巻送りは Next Volume／Previous Volume |
| シリーズ | Series | |
| 内蔵ビューア／外部ビューア | Built-in Viewer／External Viewer | `Built-In` とは書かない |
| 表紙 | Cover | |
| 見開き | Two-Page Spread（短縮時 Spread） | ビューアの HUD・トグルは Spread |
| ページ送り | Page Turn | 設定名・演出名。キー操作の動作名は Next Page（§4） |
| 巻末 | End of Volume | Web の巻末ダイアログの見出しも End of Volume |
| 続きから読む | Resume Reading | 再開ダイアログは Resume／Start Over（§2.2） |
| ルーペ | Magnifier | 倍率は Magnifier Zoom |
| スタンプ | Stamp | |
| ブラウザ（属性列） | Browser | Web ブラウザと紛れる箇所は Column Browser |
| レート／評価 | Rating | 「評価」は同義の別表記 |
| 未読／既読 | Unread／Read | |
| ロック／解錠 | Lock／Unlock | ロック設定そのものを外す操作は Remove Lock（§2.4） |
| 共有 | Sharing | |
| グラント | Access Grant | CLI の `grant` グループでは短く grant（List grants 等）。コマンド名に合わせた略 |
| トークン／編集トークン | Token／Edit Token | |
| リモート | Remote | |
| オフライン | Offline Copy／Available Offline | |
| 監視フォルダ | Watched Folder | |
| 取り込み | Import | |
| 破損チェック | Integrity Check | CLI の `integrity` と揃う。メニューは Integrity Check… |
| リンク切れ／再リンク | Missing File／Relink | |
| お知らせ | Notice | |
| 厚い本／薄い本／本の一部／画像セット／テキスト／ムービー | Thick Book／Thin Book／Part of Book／Image Set／Text／Movie | 表示だけの訳。`@type` のファイル名トークン（`canonicalLabel(for:)`）は日本語のまま |
| ネタ | Content Notes | 書籍メタデータの自由記述欄（memo とは別枠）。CLI/MCP の `--neta`/`neta` は識別子のまま |
| ゴミ箱 | Trash | macOS 標準訳語 |

## 2. 分野別の語彙

### 2.1 本のフィールド・一覧・フィルタ

| 日本語 | 英訳 | 備考 |
|---|---|---|
| タイトル／作者・著者／ジャンル | Title／Author／Genre | 「作者」「著者」はどちらも Author |
| 登録日・追加日 | Date Added | |
| 読んだ日 | Date Read | 列ヘッダ・スタンプ |
| 最終閲覧日・最終読書日 | Last Read Date | 「最終読書」（Web の詳細行）は Last Read |
| 最後に読んだ日 | Last Read | 既存カタログの訳 |
| 種類 | Type | |
| 関連 | Related | `neta` 列の既定の表示名。§1 の「ネタ」（Content Notes）とは別の日本語 |
| メモ | Memo | |
| キーワード A／B／C | Keyword A／B／C | |
| 巻数 | Volume | |
| ページ数 | Page Count（App のスマートシェルフ条件）／Pages（Web のソート・詳細） | §4 |
| 進行 | Progress | Web の詳細シート |
| メタデータ | Metadata | |
| フィルタ | Filter | 単数形 |
| 既読状態 | Read Status | |
| 消去 | Clear | |
| 検索／並び替え | Search／Sort By（App のメニュー）・Sort（Web） | §4 |
| グリッド／リスト／カラム | Grid／List／Column | |
| 表示 | View | 設定のタブ名・ツールバーの表示切替 Picker（ヘルプの Settings ▸ View と一致） |
| 表示モード | View Mode | App・Web 共通 |
| リスト/アイコン表示 | List/Icon View | 既存カタログの訳（メニュー） |
| 最近の項目 | Recent Items | 既存カタログの訳 |
| 未読チェック | Toggle Unread | メニュー項目はすべてトグル。キー `menu.toggleUnread`（§5）。日本語キー「未読チェック」の既存訳 Mark as Unread はもう使われない |
| 書籍が選択されていません | No Book Selected（詳細ペインの空状態）／No books selected.（リモートの一括ダウンロードの要約文。キー `remote.batch.noBooksSelected`） | §5 |
| お気に入り | Favorites | DB 保存名 `お気に入り` は変えない（kind で判定・表示だけ訳す） |
| ラベル | Label（グラントのラベル欄）／Labels（ライブラリ設定のタブ名。キー `settings.tab.labels`） | §5 |
| (無題) | (Untitled) | |
| すべて | All | ファセット列の先頭項目 |
| 詳細ペイン | Detail Pane | 表紙の表示切替は Detail Pane Cover／ツールチップ Show or hide the cover in the detail pane |
| 上ペイン／ファセット／伏せ字 | Top Pane／Facets／Hidden | |
| ・（箇条書きの行頭記号） | • (U+2022) または `, `（列挙の区切り） | 列挙に使うと主語が複数になりうるので、動詞の数に依存しない語順にする（例 Spotlight indexing is turned off for “%@”） |

スマートシェルフの演算子（Picker 項目・Title Case）:

| 日本語 | 英訳 |
|---|---|
| が次と等しい／を含む／で始まる／で終わる | Equals／Contains／Starts With／Ends With |
| 以上／以下 | At Least／At Most |
| 以内／より前（日付） | Within／Older Than |
| である／ではない | Is／Is Not |

日付フィルタ（`DateFilterRow`）の方向 Picker も同じ訳（以内 → Within、以前 → Older Than）。英語では Picker が数値の前に来る（Within [7] days）。

### 2.2 ビューア・EPUB

| 日本語 | 英訳 | 備考 |
|---|---|---|
| 単ページ | Single Page | Spread の対 |
| 表紙独立／先頭からペア | Cover on Its Own Page／Paired from First Page | |
| ページ方向 | Page Direction | Right to Left／Left to Right |
| 読み方向（Web） | Reading Direction | 選択肢は Left to Right／Right to Left (Manga) |
| 続きから／最初から | Resume／Start Over | App の再開ダイアログ・Web の巻送りダイアログ共通。問いは Resume reading? |
| キー操作・キー割り当て | Key Bindings | |
| ページ送りの演出 | Page Turn Effect | |
| ノンブル | Page Number | |
| 全画面で開く | Open in Full Screen | |
| 次の巻へ／先頭へ／本を閉じる | Next Volume／To the Beginning／Close the Book | Web の巻末ダイアログ |
| ルーペの形・大きさ | Circle／Square、Small／Medium／Large | |
| キー操作のセクション | Navigation／Zoom／Spread & Slideshow／Volume Navigation／Other | |
| アーカイブ／画像／フォルダ／動画／テキスト | Archive／Image／Folder／Video／Text | `BookCategory`（ビューア選択の分類。本の種類ラベルとは別語彙） |
| 電子書籍 | E-Book | EPUB 用外部ビューア未設定時の表示名。複数形 E-Books (EPUB) |

### 2.3 ファイル操作・取り込み・監視

| 日本語 | 英訳 | 備考 |
|---|---|---|
| ファイル名を変更…／ファイルを移動…／ファイルをゴミ箱に移動… | Rename Files…／Move Files…／Move to Trash… | 選択中の本（複数可）に効くメニュー。ヘルプのキー表も同じ |
| ライブラリから削除 | Remove from Library | Undo 名も Remove %lld Item(s) from Library |
| ファイルを再指定… | Relink File… | |
| リンク切れを検出…／リンク切れの検出と再リンク | Find Missing Files…／Find Missing Files and Relink | 「検出」は Find（Detect は使わない）。開始ボタンは Start、再実行は Find Again |
| 重複を検出… | Find Duplicates… | |
| 命名プリセット／プリセット | Naming Preset／Preset | 既定のプリセット名 `既定` は保存値のまま、表示は Default |
| （プリセットの）のコピー | copy（小文字・Finder と同じ） | 例 “Default copy” |
| 自動追加 | Auto-Add | |
| 自動分類 | Auto-Classify | 本の種類の自動判定。U4 の Auto-Categorization から統一（§3） |
| 既定に従う（現在: …） | Follow the Default (Currently: …) | |
| 有効／無効 | On／Off | このライブラリで有効 → On for This Library |
| サブフォルダ | Subfolder | 選択肢 Don't Import Subfolders／Import Each Subfolder as One Book／Import Subfolder Contents Individually |
| 既存も取り込む | Import Existing Files | |
| 厚い本判定閾値 | Thick Book Threshold | ハイフンを付けない |
| Finder タグ | Finder Tag(s) | |
| 同期／再照合 | Sync／Re-sync | 今すぐ再照合 → Re-sync Now、メニュー Re-sync Finder Tags。CLI・MCP・ヘルプも Re-sync（Reconcile は使わない） |

### 2.4 共有・リモート・ロック

| 日本語 | 英訳 | 備考 |
|---|---|---|
| 管理者／編集可／閲覧のみ | Admin／Can Edit／View Only | 接続 tier の表示とグラントの Picker。macOS の「ユーザとグループ」の Admin に合わせる（§3） |
| 共有トークン | Sharing Token | |
| 全ライブラリ／%lld 庫 | All Libraries／%lld Library(ies) | グラントのスコープ表示 |
| (既定) 閲覧／(既定) 編集 | (Default) View／(Default) Edit | 保存値は日本語のまま。表示だけ `GrantStore.displayLabel(for:)` で訳す |
| 接続 | Connect（ボタン）／Connection（共有設定のセクション見出し。キー `sharing.section.connection`） | §5 |
| 変更（サーバ名の変更シートのボタン） | Rename | キー `remote.server.rename`（§5）。ロック設定の「変更」ボタンは Change のまま |
| ペアリング | Pairing | |
| 配信インジケータ | Broadcast Indicator | |
| ロック解除（パスワードロックを外す操作） | Remove Lock | 生体認証・Apple Watch によるセッションの「解錠」（Unlock）とは別物 |
| パスワードロックを設定する（トグル） | Lock This Library with a Password | |
| 表示件数 / スクロール（Web） | Items Per Page / Scroll | 選択肢は {n} per page／Infinite Scroll |
| 1ページ [n] 件（App のリモート一覧） | Show [n] per page | 2 つの素のキー「1ページ」「件」の訳 |

### 2.5 破損チェック・メンテナンス・バックアップ

| 日本語 | 英訳 | 備考 |
|---|---|---|
| ファイルの破損チェック(…) | Integrity Check(…) | メニュー・ウィンドウ題 |
| 簡易チェック／詳細（CRC）チェック | Quick Check／Detailed (CRC) Check | |
| 未検査をスキャン／全件やり直し／前回破損のみ再検査 | Scan Unchecked／Recheck All／Recheck Damaged Only | ヘルプも同じ語 |
| 破損／劣化 | Damaged／Degraded | 「劣化」は前回 OK → 今回破損 |
| バックアップ | Backup | |
| メンテナンス | Maintenance | |
| データベースを検査 | Check Database | |
| 表紙を再生成 | Regenerate Cover（詳細ペインの右クリック・1 冊）／Regenerate Covers（ライブラリ設定のメンテナンス・全体。キー `settings.maintenance.regenerateCovers`） | §5。ヘルプも同じ |
| 中断 | Stop／Stopped | 実行中ジョブの停止（Cancel ではない） |

### 2.6 その他（段 2 までに個別に決めたもの）

| 日本語 | 英訳 | 備考 |
|---|---|---|
| ファイル名では「%@」 | In filenames: “%@” | ラベル編集シートの補足キャプション（英語 UI でのみ出る） |
| libarchive の版不一致メッセージ | The libarchive header (%lld) and the runtime library (%lld) are different versions. | `LibarchiveVersion.mismatchMessage` |
| フル先読み（Tier3）／キャッシュ上限 | Full Prefetch (Tier 3)／Cache Limit | Web のリーダー設定 |
| リーダー設定／本の詳細／ステップ | Reader Settings／Book Details／Steps | Web |

## 3. 文体の規則

- **Title Case**: メニュー項目・ボタン・タブ・設定項目の見出し・Picker の選択肢・ツールバーのラベル・ビューア HUD のうち名詞句や状態のもの（Spread、Magnifier On、Last Page、Loading Next Volume…）。
- **文（文頭だけ大文字）**: 説明文・エラー・確認・ステータス行・**NSAlert の messageText と SwiftUI の `.alert`／`.confirmationDialog` の題**・ビューア HUD のうち動詞を含む節（Can't open the next volume、Moved to the first page）。
- **末尾の句点**: アラートの題とステータス行・短いエラー行には付けない（Couldn't open the library）。複数の文からなる説明・本文の文には付ける。日本語が 。 で終わる短い文は付けてよい（段 1 の訳の多くはこれに従っている）。
- **エラーの言い回し**: できなかったことは `Couldn't …`、恒常的にできないことは `Can't …`。`Failed to …`／`… Failed` は使わない（「%lld 件失敗」のような件数の要約だけは `%lld failed`）。
- **件数**: 「件」は item(s)、「冊」は book(s)。本の削除確認のように対象を明示したい文では book(s) を使ってよい。`(s)` は使わない。単数・複数を 1 つのキーで持てない 2 つの数の文は、名詞を数の前に出して数に依存しない形にする（Missing files: %1$lld (in folders: %2$lld)）。
- **省略記号** `…`（U+2026）。引用には “ ” を使う（UI の項目名の引用も “Move to Trash”）。**アポストロフィはまっすぐな `'`**（don't、library's）。段 1 で ’ を使っていた訳は S2-B で ' に揃えた。
- **CLI**: `--help`／abstract は文頭だけ大文字の名詞句・動詞句（例 "Access token"、"List shelves in the library"）。エラー文・確認文は文。複数形は `L10nEntry(one:other:)`。
- **MCP**（`mcp-stacknest/`）: テーブルを持たず、docstring と例外メッセージを直接英語で書く（言語切り替えなし）。
- **Web**: タッチ操作を前提に tap と書く（Couldn't load. Tap to retry）。

## 4. 文脈で訳し分ける語

| 日本語 | 訳し分け | 理由 |
|---|---|---|
| ページ送り | 設定・演出名は Page Turn、キー操作の動作名（`ViewerActionDisplay`）は Next Page | 動作名は「ページ戻し」→ Previous Page と対になる |
| ページ数 | App のスマートシェルフ条件は Page Count、Web のソート・詳細行は Pages | Web は狭い列に入る短い語 |
| 並び替え | App のメニューは Sort By、Web のボタンは Sort | Web は単独のボタン |
| 設定 | App の外部表紙シートのボタンは Set、Web のリーダーの歯車は Settings | 別の画面・別の辞書で意味が違う |
| 以内／以前 | どちらも Picker の選択肢として Title Case（Within／Older Than） | 段 1 の小文字 within／older than は Picker の他の項目と揃わなかった |

## 5. 文脈で分けたキー（S2-C）

App のカタログは同じ日本語キーに 1 つの訳しか持てない。同じ日本語を意味の違う箇所で使っていたものは、
合わない側の呼び出しだけを **英語のドット区切りキー＋元の日本語の `defaultValue`** に分けた
（`String(localized: "sidebar.section.smartShelves", defaultValue: "スマートシェルフ")`）。
日本語 UI は `defaultValue`（とカタログの `ja`）がそのまま出るので一字一句変わらない。

- 訳は `tools/l10n/fragments/S2C.json` に `{ "key": { "ja": "元の日本語", "en": "English" } }` の形で書く。
  `merge_fragments.py` が `ja` と `en` の両方の localization を書く（ドット区切りキーに `ja` が無ければ止まる）。
- `l10n-lint.py` は `.stringsdata` の `value`（＝`defaultValue`）で抽出を照合し、ドット区切りキーには
  en の訳に加えて ja の値が `defaultValue` と一字一句同じであることを求める（`app-missing`）。
- キー名は `領域.種類.名前`（lowerCamel）。新しく分けるときもこの形にする。

| 元の日本語キー | 分けた箇所 | 新しいキー | 英訳 | 元のキーの英訳（そのまま残る箇所） |
|---|---|---|---|---|
| 表紙を再生成 | ライブラリ設定のメンテナンス（ローカル・リモート） | `settings.maintenance.regenerateCovers` | Regenerate Covers | Regenerate Cover（1 冊の右クリック） |
| スマートシェルフ | リモートのサイドバーのセクション見出し（ローカルの `SidebarView` には見出しが無い） | `sidebar.section.smartShelves` | Smart Shelves | Smart Shelf（編集シートの題） |
| 接続 | 共有設定のセクション見出し | `sharing.section.connection` | Connection | Connect（ボタン） |
| ラベル | ライブラリ設定のタブ名（ローカル・リモート） | `settings.tab.labels` | Labels | Label（グラントのラベル欄） |
| 変更 | リモートのサーバ名変更シートのボタン | `remote.server.rename` | Rename | Change（ロック設定のボタン） |
| 書籍が選択されていません | リモートの一括ダウンロードの要約文 | `remote.batch.noBooksSelected` | No books selected. | No Book Selected（詳細ペインの空状態） |
| 未読チェック | メニュー項目すべて（6 箇所。いずれもトグル） | `menu.toggleUnread` | Toggle Unread | （使われなくなった。カタログに Mark as Unread が残る） |
