# Changelog

**日本語** | [English](#changelog-english)

本ファイルは StackNest の主な変更を記録します。形式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に準じ、バージョンは [Semantic Versioning](https://semver.org/lang/ja/) に従います。
リリースは ad-hoc 署名の Universal ビルド（Apple 公証なし）で、[Releases](https://github.com/shelfsmith/stacknest/releases) から配布します（個人利用前提・現在は prerelease）。
各フェーズの詳細は計画リポジトリのロードマップを参照（本リポジトリの README「ロードマップ」が要約）。

## [0.9.0] - 2026-06-07 — ライブラリ保全 & DB 修復（Phase 2.8 / 2.9）

### Added
- **DB 予防保全（B22）**: 編集のあったセッションを閉じるたびに、バンドル内 `Backups/` へ世代バックアップを自動取得（SQLite Online Backup API・閲覧のみの無編集セッションはスキップ）。保持世代数はライブラリごとに 1〜20（既定 5）で設定可能。
- **整合性チェック（B22）**: ライブラリを開く際に `PRAGMA quick_check` を実行し、破損を検知すると「最新の正常なバックアップから復元しますか？」と案内。設定に手動の整合性チェック／今すぐバックアップ／バックアップフォルダ表示ボタンを追加。
- **アプリ内 DB 修復 `.recover`（B23）**: バックアップからの復元ができない場合、「.recover で修復を試す」からシステムの `sqlite3 .recover` を実行して可能な範囲のデータを救出。救出できた本の件数を提示し、正常なら差し替えて開く（壊れた本体は `library.corrupt-*` / `library.prerecover-*` として保持）。
- **リンク切れ再指定（A19）**: 本体ファイル／フォルダの移動で参照切れになった本を再リンク。右クリック「ファイルを再指定…」（即時）と、メニュー「リンク切れを検出…」（個別列挙＋フォルダ一括再マップ）。
- **復旧ガイド**: `docs/recovery-guide.md` を追加（手動 `sqlite3 .recover` 手順・退避ファイルの説明）。

### Fixed
- **NFC 正規化**: macOS のファイル名（NFD）由来のシリーズ／タイトルが、入力・取り込み由来（NFC）と別文字列として扱われ、ブラウズのファセットが分裂したりフィルタで取りこぼす不具合を修正。保存時に NFC 正規化し、既存データは migration v16 で一括バックフィル。

### Notes
- ad-hoc 署名 Universal（arm64 + x86_64・macOS 15+）、prerelease。

## [0.8.0] - 2026-06-06 — ブラッシュアップ & 性能（Phase 2.7）

### Added
- **重複検出（A20 / B11）**: 別ディレクトリにある同一内容の本を SHA-256 のバイト一致で検出（＋ series+volume 一致）。解決シート（登録のみ削除／ファイルもゴミ箱／グループ無視）。
- **ラベルカスタマイズ（A22 / A23）**: 内容系フィールドと bookType の表示名をライブラリごとに任意の名前へ。全表示箇所（列ヘッダ・ソート・詳細・フィルタ・スタンプ・ブラウズ・スマートシェルフ）へ一貫反映。
- **ビューワキー再割当 UI**: ビューワの全操作キーを設定「キー」タブで自由に割り当て（競合は拒否・ヘルプ自動生成）。
- **複数命名フォーマットプリセット（B6）**: 命名フォーマットを複数保存し、リネーム時に選択。
- **配布**: CI（GitHub Actions）による ad-hoc 署名 Universal ビルドのリリース配布を開始（初の tag 付きリリース）。

### Changed
- **ソート性能最適化（B9）**: DSU + ICU sort key（`ucol_getSortKey`）で大規模ライブラリのソートを高速化（実スケール 5,000 件で起動時の体感を大幅改善）。

---

0.8.0 より前（2.1〜2.6 系）の経緯は README「ロードマップ」を参照してください（互換インポータ・グリッド／リスト・検索・編集・マルチライブラリ・ファイル CRUD・内蔵ビューワ・初回ウィザード・各種ロック等）。

---

<a id="changelog-english"></a>
# Changelog (English)

[日本語](#changelog) | **English**

This file records notable changes to StackNest. It follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/).
Releases are ad-hoc-signed Universal builds (not Apple-notarized), distributed from [Releases](https://github.com/shelfsmith/stacknest/releases) (personal-use; currently prerelease).
For per-phase detail see the planning repo's roadmap (the README "Roadmap" is the summary).

## [0.9.0] - 2026-06-07 — Library safety & DB repair (Phase 2.8 / 2.9)

### Added
- **DB preventive safety (B22)**: On closing any session that made edits, a generational backup is taken automatically into `Backups/` inside the bundle (SQLite Online Backup API; view-only/no-edit sessions are skipped). The number of generations to keep is per-library configurable from 1–20 (default 5).
- **Integrity check (B22)**: On opening a library, `PRAGMA quick_check` runs; if corruption is detected it offers "Restore from the latest healthy backup?". Settings gain manual integrity-check / back-up-now / reveal-backups-folder buttons.
- **In-app DB repair `.recover` (B23)**: When restoring from a backup isn't possible, "Try repair with .recover" runs the system `sqlite3 .recover` to salvage what it can. It reports how many books were recovered and, if healthy, swaps it in and opens (the corrupt originals are kept as `library.corrupt-*` / `library.prerecover-*`).
- **Relink missing files (A19)**: Re-link books whose underlying file/folder moved. Right-click "Reassign file…" (immediate) and the menu "Detect broken links…" (per-item list + folder-wide remap).
- **Recovery guide**: Added `docs/recovery-guide.md` (manual `sqlite3 .recover` steps and an explanation of the retained files).

### Fixed
- **NFC normalization**: Fixed a bug where series/titles derived from macOS filenames (NFD) were treated as different strings from typed/imported ones (NFC), splitting browse facets and missing filter matches. Text is now NFC-normalized on write, and existing data is backfilled by migration v16.

### Notes
- Ad-hoc-signed Universal (arm64 + x86_64, macOS 15+), prerelease.

## [0.8.0] - 2026-06-06 — Polish & performance (Phase 2.7)

### Added
- **Duplicate detection (A20 / B11)**: Detect same-content books in different directories by SHA-256 byte match (plus series+volume match). Resolution sheet (remove catalog entry only / also move file to Trash / ignore group).
- **Label customization (A22 / A23)**: Rename content fields and bookType display names per library, reflected consistently everywhere (column headers, sort, detail, filters, stamps, browse, smart shelves).
- **Viewer key-rebinding UI**: Freely reassign every viewer action key in the Settings "Keys" tab (conflicts rejected; help auto-generated).
- **Multiple naming-format presets (B6)**: Save several naming formats and pick one at rename time.
- **Distribution**: Started releasing ad-hoc-signed Universal builds via CI (GitHub Actions) — the first tagged release.

### Changed
- **Sort performance optimization (B9)**: DSU + ICU sort key (`ucol_getSortKey`) speeds up sorting for large libraries (notably improves perceived startup at a realistic 5,000-item scale).

---

For history before 0.8.0 (the 2.1–2.6 line), see the README "Roadmap" (compatible importer, grid/list, search, editing, multi-library, file CRUD, built-in viewer, first-run wizard, locks, etc.).

[0.9.0]: https://github.com/shelfsmith/stacknest/releases/tag/v0.9.0
[0.8.0]: https://github.com/shelfsmith/stacknest/releases/tag/v0.8.0
