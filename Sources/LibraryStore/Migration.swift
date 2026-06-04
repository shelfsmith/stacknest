// SPDX-License-Identifier: MIT
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
}
