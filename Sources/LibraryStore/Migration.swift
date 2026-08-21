// SPDX-License-Identifier: MIT
import Foundation
import GRDB

enum Migration {
    static func apply(to db: GRDB.Database) throws {
        // v1 — base schema
        try db.execute(sql: Tables.createBookTable)
        try db.execute(sql: Tables.createPlaylistTable)
        try db.execute(sql: Tables.createPlaylistItemTable)
        try db.execute(sql: Tables.createImportMetaTable)

        // v2 — idempotent ALTER
        try migrateAddThumbnailsDirIfNeeded(db: db)

        // v3 — add playlist.kind column, idempotent
        try migrateAddPlaylistKindIfNeeded(db: db)

        // v4 — FTS5 + library_settings, idempotent
        try migrateAddFTS5IfNeeded(db: db)
        try migrateAddLibrarySettingsIfNeeded(db: db)

        // v5 — add memo column, idempotent
        try migrateAddBookMemoIfNeeded(db: db)

        // v6 — rebuild FTS5 with memo column + add filter indexes, idempotent
        try migrateRebuildFTSAndAddIndexesIfNeeded(db: db)

        // v7 — switch FTS5 tokenizer to trigram for substring search, idempotent
        try migrateRebuildFTSToTrigramIfNeeded(db: db)

        // v8 — drop cover_path / cover_name from book + thumbnails_directory_path from import_meta, idempotent
        try migrateDropCoverColumnsIfNeeded(db: db)
        try migrateDropThumbnailsDirIfNeeded(db: db)

        // v9 — seed filename_format default in library_settings, idempotent (INSERT OR IGNORE)
        try migrateV9SeedFilenameFormatIfNeeded(db: db)

        // v10 — add series TEXT NULL and volume REAL NULL to book, idempotent
        try migrateV10AddSeriesAndVolumeIfNeeded(db: db)

        // v11 — add cover_image_name TEXT NULL to book, idempotent
        try migrateV11AddCoverImageNameIfNeeded(db: db)

        // v12 — add cover_crop_rect TEXT NULL to book, idempotent.
        // JSON {"x":0.0-1.0,"y":...,"w":...,"h":...}; NULL = no crop.
        try migrateV12AddCoverCropRectIfNeeded(db: db)

        // v13 — per-book viewer state tables + series index (Phase 2.6b-2), idempotent.
        try migrateV13AddViewerStateTablesIfNeeded(db: db)

        // v14 — per-book page direction TEXT NULL (Phase 2.6b-2 D1), idempotent.
        try migrateV14AddPageDirectionIfNeeded(db: db)

        // v15 — duplicate detection columns (Phase 2.7 A20/B11), idempotent.
        try migrateV15AddDuplicateColumnsIfNeeded(db: db)

        // v16 — normalize existing book text columns to NFC (one-time, flag-gated).
        try migrateV16NormalizeTextToNFCIfNeeded(db: db)

        // v17 — add spread_explicit to book_viewer_state (G17 T6a), idempotent.
        try migrateV17AddSpreadExplicitIfNeeded(db: db)

        // v18 — 整合性検査の結果テーブル（Phase G27a）、冪等。
        try migrateV18AddIntegrityTableIfNeeded(db: db)

        // v19 — Finder タグ同期の前回同期値（Phase G39）、冪等。
        try migrateV19AddFinderTagsSyncedIfNeeded(db: db)
    }

    /// Adds `thumbnails_directory_path TEXT` to import_meta if it's not already present.
    private static func migrateAddThumbnailsDirIfNeeded(db: GRDB.Database) throws {
        let info = try Row.fetchAll(db, sql: "PRAGMA table_info(import_meta)")
        let hasColumn = info.contains { ($0["name"] as? String) == "thumbnails_directory_path" }
        if !hasColumn {
            try db.execute(sql: Tables.migrateV2AddThumbnailsDir)
        }
    }

    /// Adds `kind TEXT NOT NULL DEFAULT 'imported'` to playlist if missing.
    private static func migrateAddPlaylistKindIfNeeded(db: GRDB.Database) throws {
        let info = try Row.fetchAll(db, sql: "PRAGMA table_info(playlist)")
        let hasColumn = info.contains { ($0["name"] as? String) == "kind" }
        if !hasColumn {
            try db.execute(sql: Tables.migrateV3AddPlaylistKind)
        }
    }

    private static func migrateAddFTS5IfNeeded(db: GRDB.Database) throws {
        let exists = try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='book_fts')"
        ) ?? false
        if exists { return }

        try db.execute(sql: Tables.createBookFTS5)
        try db.execute(sql: Tables.createBookFTSInsertTrigger)
        try db.execute(sql: Tables.createBookFTSDeleteTrigger)
        try db.execute(sql: Tables.createBookFTSUpdateTrigger)
        try db.execute(sql: Tables.backfillBookFTS)
    }

    private static func migrateAddLibrarySettingsIfNeeded(db: GRDB.Database) throws {
        let exists = try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='library_settings')"
        ) ?? false
        if !exists {
            try db.execute(sql: Tables.createLibrarySettingsTable)
        }
    }

    private static func migrateAddBookMemoIfNeeded(db: GRDB.Database) throws {
        let info = try Row.fetchAll(db, sql: "PRAGMA table_info(book)")
        let hasColumn = info.contains { ($0["name"] as? String) == "memo" }
        if !hasColumn {
            try db.execute(sql: Tables.migrateV5AddBookMemo)
        }
    }

    /// v6: book_fts を memo 列込みで再構築し、フィルタ高速化用 5 個の index を追加。
    /// FTS が既に memo を含んでいて index が全部揃っていれば no-op (idempotent)。
    private static func migrateRebuildFTSAndAddIndexesIfNeeded(db: GRDB.Database) throws {
        let ftsCols = try Row.fetchAll(db, sql: "PRAGMA table_info(book_fts)")
        let ftsHasMemo = ftsCols.contains { ($0["name"] as? String) == "memo" }

        if !ftsHasMemo {
            try db.execute(sql: "DROP TRIGGER IF EXISTS book_ai")
            try db.execute(sql: "DROP TRIGGER IF EXISTS book_ad")
            try db.execute(sql: "DROP TRIGGER IF EXISTS book_au")
            try db.execute(sql: Tables.dropBookFTSTableV4)

            try db.execute(sql: Tables.createBookFTS5V6)
            try db.execute(sql: Tables.createBookFTSInsertTriggerV6)
            try db.execute(sql: Tables.createBookFTSDeleteTriggerV6)
            try db.execute(sql: Tables.createBookFTSUpdateTriggerV6)
            try db.execute(sql: Tables.backfillBookFTSV6)
        }

        try db.execute(sql: Tables.createIndexBookType)
        try db.execute(sql: Tables.createIndexBookUnseen)
        try db.execute(sql: Tables.createIndexBookRating)
        try db.execute(sql: Tables.createIndexBookDateAdded)
        try db.execute(sql: Tables.createIndexBookPlayDate)
    }

    /// v7: book_fts を trigram tokenizer で再構築。
    /// sqlite_master の CREATE 文に 'trigram' が含まれていなければ drop & recreate。
    /// Phase 2.4e (commit `cf8e49b` 系列以降)。
    private static func migrateRebuildFTSToTrigramIfNeeded(db: GRDB.Database) throws {
        let createSQL = try String.fetchOne(
            db,
            sql: "SELECT sql FROM sqlite_master WHERE type='table' AND name='book_fts'"
        ) ?? ""
        if createSQL.contains("'trigram'") || createSQL.contains("\"trigram\"") {
            return
        }

        try db.execute(sql: "DROP TRIGGER IF EXISTS book_ai")
        try db.execute(sql: "DROP TRIGGER IF EXISTS book_ad")
        try db.execute(sql: "DROP TRIGGER IF EXISTS book_au")
        try db.execute(sql: Tables.dropBookFTSTableV4)

        try db.execute(sql: Tables.createBookFTS5V7)
        try db.execute(sql: Tables.createBookFTSInsertTriggerV7)
        try db.execute(sql: Tables.createBookFTSDeleteTriggerV7)
        try db.execute(sql: Tables.createBookFTSUpdateTriggerV7)
        try db.execute(sql: Tables.backfillBookFTSV7)
    }

    /// Drops `cover_path` and `cover_name` from `book` if present (v8).
    /// Uses introspection to remain idempotent across repeated runs.
    private static func migrateDropCoverColumnsIfNeeded(db: GRDB.Database) throws {
        let info = try Row.fetchAll(db, sql: "PRAGMA table_info(book)")
        let names = info.compactMap { $0["name"] as? String }
        if names.contains("cover_path") {
            try db.execute(sql: Tables.migrateV8DropCoverPath)
        }
        if names.contains("cover_name") {
            try db.execute(sql: Tables.migrateV8DropCoverName)
        }
    }

    /// Drops `thumbnails_directory_path` from `import_meta` if present (v8).
    private static func migrateDropThumbnailsDirIfNeeded(db: GRDB.Database) throws {
        let info = try Row.fetchAll(db, sql: "PRAGMA table_info(import_meta)")
        let hasColumn = info.contains { ($0["name"] as? String) == "thumbnails_directory_path" }
        if hasColumn {
            try db.execute(sql: Tables.migrateV8DropThumbnailsDir)
        }
    }

    /// Inserts the default filename_format value if absent. Idempotent via INSERT OR IGNORE
    /// so that a user-defined override survives re-migration.
    private static func migrateV9SeedFilenameFormatIfNeeded(db: GRDB.Database) throws {
        try db.execute(sql: Tables.migrateV9SeedFilenameFormat)
    }

    /// Adds `series TEXT` and `volume REAL` columns to `book` if not already present (v10).
    private static func migrateV10AddSeriesAndVolumeIfNeeded(db: GRDB.Database) throws {
        let info = try Row.fetchAll(db, sql: "PRAGMA table_info(book)")
        let hasSeries = info.contains { ($0["name"] as? String) == "series" }
        let hasVolume = info.contains { ($0["name"] as? String) == "volume" }
        if !hasSeries { try db.execute(sql: Tables.migrateV10AddSeries) }
        if !hasVolume { try db.execute(sql: Tables.migrateV10AddVolume) }
    }

    /// Adds `cover_image_name TEXT` column to book if not already present (v11).
    /// Stores the in-archive page name for manual cover selection (Stackroom XML compatible).
    private static func migrateV11AddCoverImageNameIfNeeded(db: GRDB.Database) throws {
        let info = try Row.fetchAll(db, sql: "PRAGMA table_info(book)")
        let hasColumn = info.contains { ($0["name"] as? String) == "cover_image_name" }
        if !hasColumn {
            try db.execute(sql: Tables.migrateV11AddCoverImageName)
        }
    }

    /// Adds `cover_crop_rect TEXT` column to book if not already present (v12).
    /// Stores the normalized crop rect (JSON `{"x":0.0-1.0,"y":...,"w":...,"h":...}`) for
    /// horizontally-extended cover artwork (front+spine+back compositions, Stackroom compat).
    private static func migrateV12AddCoverCropRectIfNeeded(db: GRDB.Database) throws {
        let info = try Row.fetchAll(db, sql: "PRAGMA table_info(book)")
        let hasColumn = info.contains { ($0["name"] as? String) == "cover_crop_rect" }
        if !hasColumn {
            try db.execute(sql: Tables.migrateV12AddCoverCropRect)
        }
    }

    /// Creates the per-book viewer-state tables and the series index (v13).
    /// All statements use IF NOT EXISTS, so this is idempotent without PRAGMA introspection.
    private static func migrateV13AddViewerStateTablesIfNeeded(db: GRDB.Database) throws {
        try db.execute(sql: Tables.createBookViewerStateTable)
        try db.execute(sql: Tables.createBookPageLayoutTable)
        try db.execute(sql: Tables.createIndexBookSeries)
    }

    /// Adds `page_direction TEXT` column to book if not already present (v14).
    /// NULL means "inherit global setting". Values: "rightToLeft" / "leftToRight".
    private static func migrateV14AddPageDirectionIfNeeded(db: GRDB.Database) throws {
        let info = try Row.fetchAll(db, sql: "PRAGMA table_info(book)")
        let hasColumn = info.contains { ($0["name"] as? String) == "page_direction" }
        if !hasColumn {
            try db.execute(sql: Tables.migrateV14AddPageDirection)
        }
    }

    /// Adds content_hash/file_size/file_mtime columns to book if absent (v15).
    /// Used by duplicate detection (A20/B11). NULL = not yet computed / not eligible.
    private static func migrateV15AddDuplicateColumnsIfNeeded(db: GRDB.Database) throws {
        let info = try Row.fetchAll(db, sql: "PRAGMA table_info(book)")
        let names = Set(info.compactMap { $0["name"] as? String })
        if !names.contains("content_hash") { try db.execute(sql: Tables.migrateV15AddContentHash) }
        if !names.contains("file_size")    { try db.execute(sql: Tables.migrateV15AddFileSize) }
        if !names.contains("file_mtime")   { try db.execute(sql: Tables.migrateV15AddFileMtime) }
    }

    // MARK: - v16: NFC normalization backfill

    private static let nfcNormalizedFlagKey = "nfc_normalized_v1"

    /// Normalizes all book text columns to NFC — flag-gated so it runs only once per library.
    /// FTS is kept in sync automatically by the AFTER UPDATE ON book trigger (book_au, v7).
    private static func migrateV16NormalizeTextToNFCIfNeeded(db: GRDB.Database) throws {
        // 既に適用済みならスキップ（library_settings のフラグで一度だけ）。
        let done = try String.fetchOne(db, sql: "SELECT value FROM library_settings WHERE key = ?", arguments: [nfcNormalizedFlagKey])
        if done == "1" { return }
        try normalizeAllBookTextToNFC(db: db)
        try db.execute(sql: "INSERT OR REPLACE INTO library_settings (key, value) VALUES (?, '1')", arguments: [nfcNormalizedFlagKey])
    }

    /// 既存 book 行のテキスト列を NFC へ正規化（変化した行のみ UPDATE）。テスト可能な純 DB 操作。
    /// NOTE: Swift の String == は正準等価で比較するため NFD == NFC が true になる。
    /// 変更が必要かどうかは UTF-8 バイト列で判定する。
    static func normalizeAllBookTextToNFC(db: GRDB.Database) throws {
        let cols = ["title", "author", "genre", "neta", "keyword_a", "keyword_b", "keyword_c", "memo", "series"]
        let rows = try Row.fetchAll(db, sql: "SELECT id, \(cols.joined(separator: ", ")) FROM book")
        for row in rows {
            let id: Int = row["id"]
            var sets: [String] = []
            var args: [DatabaseValueConvertible?] = []
            for c in cols {
                let v: String? = row[c]
                if let v {
                    let normalized = v.precomposedStringWithCanonicalMapping
                    // Use UTF-8 byte comparison because Swift String == treats NFD == NFC.
                    if Array(v.utf8) != Array(normalized.utf8) {
                        sets.append("\(c) = ?")
                        args.append(normalized)
                    }
                }
            }
            if !sets.isEmpty {
                args.append(id)
                try db.execute(sql: "UPDATE book SET \(sets.joined(separator: ", ")) WHERE id = ?", arguments: StatementArguments(args))
            }
        }
    }

    // MARK: - v17: distinguish explicit spread saves from progress-only rows (G17 T6a)

    /// Adds `spread_explicit` column to `book_viewer_state` if not already present (v17).
    /// See doc comment on `Tables.migrateV17AddSpreadExplicit` for the semantics.
    private static func migrateV17AddSpreadExplicitIfNeeded(db: GRDB.Database) throws {
        let info = try Row.fetchAll(db, sql: "PRAGMA table_info(book_viewer_state)")
        let hasColumn = info.contains { ($0["name"] as? String) == "spread_explicit" }
        if !hasColumn {
            try db.execute(sql: Tables.migrateV17AddSpreadExplicit)
            // Backfill: `updateLastPage`(progress) の素の INSERT は列 DEFAULT の
            // `spread_enabled=0 AND cover_offset=1` しか作れない。よって `spread_enabled=1` か
            // `cover_offset=0` の既存行は必ず `saveViewerState`(明示保存)由来 → explicit として復元。
            // これで「ユーザーが明示的に見開き OFF(＋cover_offset 変更)/ON にした本」の設定が
            // 昇格で失われない（progress-only 行＝DEFAULT 一致 のみ 0 のまま＝漏れ修正を維持）。
            try db.execute(sql: Tables.migrateV17BackfillSpreadExplicit)
        }
    }

    // MARK: - v18: book integrity scan results (Phase G27a)

    /// `book_integrity` テーブルと status インデックスを作る（無ければ）。
    private static func migrateV18AddIntegrityTableIfNeeded(db: GRDB.Database) throws {
        try db.execute(sql: Tables.createBookIntegrityTable)
        try db.execute(sql: Tables.createBookIntegrityStatusIndex)
    }

    // MARK: - v19: Finder tag sync baseline (Phase G39)

    /// Adds `finder_tags_synced TEXT` column to `book` if not already present (v19).
    private static func migrateV19AddFinderTagsSyncedIfNeeded(db: GRDB.Database) throws {
        let info = try Row.fetchAll(db, sql: "PRAGMA table_info(book)")
        let hasColumn = info.contains { ($0["name"] as? String) == "finder_tags_synced" }
        if !hasColumn {
            try db.execute(sql: Tables.migrateV19AddFinderTagsSynced)
        }
    }
}
