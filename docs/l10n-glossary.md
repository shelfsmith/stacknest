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
