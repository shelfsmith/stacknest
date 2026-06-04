// SPDX-License-Identifier: MIT
import GRDB
import Foundation

enum Tables {
    static let createBookTable = """
        CREATE TABLE IF NOT EXISTS book (
            id          INTEGER PRIMARY KEY,
            title       TEXT NOT NULL,
            author      TEXT,
            genre       TEXT,
            path        TEXT,
            cover_path  TEXT NOT NULL DEFAULT '',
            cover_name  TEXT,
            date_added  REAL NOT NULL,
            play_date   REAL,
            book_type   INTEGER NOT NULL DEFAULT 0,
            file_type   INTEGER NOT NULL DEFAULT 0,
            pages       INTEGER,
            rating      INTEGER NOT NULL DEFAULT 0,
            unseen      INTEGER NOT NULL DEFAULT 1,
            keyword_a   TEXT,
            keyword_b   TEXT,
            keyword_c   TEXT,
            neta        TEXT,
            memo        TEXT
        )
        """

    static let insertBookSQL = """
        INSERT OR REPLACE INTO book (id, title, author, genre, path, date_added, play_date, book_type, file_type, pages, rating, unseen, keyword_a, keyword_b, keyword_c, neta, memo, series, volume, cover_image_name)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """

    static let createPlaylistTable = """
        CREATE TABLE IF NOT EXISTS playlist (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            title       TEXT NOT NULL,
            type        INTEGER NOT NULL,
            icon        INTEGER,
            item_view   INTEGER NOT NULL DEFAULT 0,
            tool_tab    INTEGER NOT NULL DEFAULT 0,
            conditions  BLOB,
            kind        TEXT NOT NULL DEFAULT 'imported'
        )
        """

    static let createPlaylistItemTable = """
        CREATE TABLE IF NOT EXISTS playlist_item (
            playlist_id INTEGER NOT NULL REFERENCES playlist(id) ON DELETE CASCADE,
            book_id     INTEGER NOT NULL REFERENCES book(id) ON DELETE CASCADE,
            position    INTEGER NOT NULL,
            PRIMARY KEY (playlist_id, position)
        )
        """

    static let insertPlaylistSQL = """
        INSERT INTO playlist (title, type, icon, item_view, tool_tab, conditions)
        VALUES (?, ?, ?, ?, ?, ?)
        """

    static let insertPlaylistItemSQL = """
        INSERT INTO playlist_item (playlist_id, book_id, position) VALUES (?, ?, ?)
        """

    static let createImportMetaTable = """
        CREATE TABLE IF NOT EXISTS import_meta (
            schema_version    INTEGER NOT NULL,
            imported_at       REAL NOT NULL,
            source_xml_path   TEXT NOT NULL,
            source_xml_mtime  REAL NOT NULL,
            importer_version  TEXT NOT NULL,
            book_count        INTEGER NOT NULL,
            skipped_count     INTEGER NOT NULL,
            notes             TEXT
        )
        """

    static let insertImportMetaSQL = """
        INSERT INTO import_meta (schema_version, imported_at, source_xml_path,
                                  source_xml_mtime, importer_version, book_count,
                                  skipped_count, notes)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """

    /// v2 migration — add a column to import_meta. Idempotent: only runs if column missing.
    static let migrateV2AddThumbnailsDir = """
        ALTER TABLE import_meta ADD COLUMN thumbnails_directory_path TEXT
        """

    /// v3 migration — add `kind` column to playlist table. Idempotent.
    static let migrateV3AddPlaylistKind = """
        ALTER TABLE playlist ADD COLUMN kind TEXT NOT NULL DEFAULT 'imported'
        """

    // MARK: - v4 migrations

    static let createBookFTS5 = """
        CREATE VIRTUAL TABLE IF NOT EXISTS book_fts USING fts5(
            title, author, genre, keyword_a, keyword_b, neta, cover_name,
            content='book', content_rowid='id', tokenize='unicode61'
        )
        """

    static let createBookFTSInsertTrigger = """
        CREATE TRIGGER IF NOT EXISTS book_ai AFTER INSERT ON book BEGIN
            INSERT INTO book_fts(rowid, title, author, genre, keyword_a, keyword_b, neta, cover_name)
            VALUES (new.id, new.title, new.author, new.genre, new.keyword_a, new.keyword_b, new.neta, new.cover_name);
        END
        """

    static let createBookFTSDeleteTrigger = """
        CREATE TRIGGER IF NOT EXISTS book_ad AFTER DELETE ON book BEGIN
            INSERT INTO book_fts(book_fts, rowid, title, author, genre, keyword_a, keyword_b, neta, cover_name)
            VALUES ('delete', old.id, old.title, old.author, old.genre, old.keyword_a, old.keyword_b, old.neta, old.cover_name);
        END
        """

    static let createBookFTSUpdateTrigger = """
        CREATE TRIGGER IF NOT EXISTS book_au AFTER UPDATE ON book BEGIN
            INSERT INTO book_fts(book_fts, rowid, title, author, genre, keyword_a, keyword_b, neta, cover_name)
            VALUES ('delete', old.id, old.title, old.author, old.genre, old.keyword_a, old.keyword_b, old.neta, old.cover_name);
            INSERT INTO book_fts(rowid, title, author, genre, keyword_a, keyword_b, neta, cover_name)
            VALUES (new.id, new.title, new.author, new.genre, new.keyword_a, new.keyword_b, new.neta, new.cover_name);
        END
        """

    static let backfillBookFTS = """
        INSERT INTO book_fts(rowid, title, author, genre, keyword_a, keyword_b, neta, cover_name)
        SELECT id, title, author, genre, keyword_a, keyword_b, neta, cover_name FROM book
        """

    static let createLibrarySettingsTable = """
        CREATE TABLE IF NOT EXISTS library_settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )
        """

    // MARK: - v5 migrations

    /// v5 migration — add memo column to book table. Idempotent.
    static let migrateV5AddBookMemo = """
        ALTER TABLE book ADD COLUMN memo TEXT
        """

    /// COALESCE(?, col) — passing nil leaves existing value unchanged.
    /// Title's nil-protection is enforced separately in BookPatch validation.
    ///
    /// series and volume use CASE WHEN to support explicit NULL clearing via
    /// BookPatch.clearSeries / BookPatch.clearVolume flags (Fix 2.5c-a).
    /// cover_image_name uses the same CASE WHEN pattern (Task 3 spec 2.5c-b).
    /// page_direction uses the same CASE WHEN pattern (Phase 2.6b-2 D1).
    /// The parameter binding order for series/volume/cover_image_name/page_direction is:
    ///   (clearSeries_bool, series_value, clearVolume_bool, volume_value,
    ///    clearCoverImageName_bool, cover_image_name_value,
    ///    clearPageDirection_bool, page_direction_value)
    static let updateBookSQL = """
        UPDATE book SET
            title            = COALESCE(?, title),
            author           = COALESCE(?, author),
            keyword_a        = COALESCE(?, keyword_a),
            keyword_b        = COALESCE(?, keyword_b),
            keyword_c        = COALESCE(?, keyword_c),
            genre            = COALESCE(?, genre),
            neta             = COALESCE(?, neta),
            memo             = COALESCE(?, memo),
            rating           = COALESCE(?, rating),
            unseen           = COALESCE(?, unseen),
            book_type        = COALESCE(?, book_type),
            series           = CASE WHEN ? THEN NULL ELSE COALESCE(?, series) END,
            volume           = CASE WHEN ? THEN NULL ELSE COALESCE(?, volume) END,
            cover_image_name = CASE WHEN ? THEN NULL ELSE COALESCE(?, cover_image_name) END,
            page_direction   = CASE WHEN ? THEN NULL ELSE COALESCE(?, page_direction) END
        WHERE id = ?
        """

    // MARK: - v14 migrations (Phase 2.6b-2 D1: per-book page direction)

    static let migrateV14AddPageDirection = """
        ALTER TABLE book ADD COLUMN page_direction TEXT
        """

    // MARK: - v6 migrations (FTS5 rebuild with memo + filter indexes)

    static let dropBookFTSTableV4 = "DROP TABLE IF EXISTS book_fts"

    static let createBookFTS5V6 = """
        CREATE VIRTUAL TABLE IF NOT EXISTS book_fts USING fts5(
            title, author, genre, keyword_a, keyword_b, neta, memo,
            content='book', content_rowid='id', tokenize='unicode61'
        )
        """

    static let createBookFTSInsertTriggerV6 = """
        CREATE TRIGGER IF NOT EXISTS book_ai AFTER INSERT ON book BEGIN
            INSERT INTO book_fts(rowid, title, author, genre, keyword_a, keyword_b, neta, memo)
            VALUES (new.id, new.title, new.author, new.genre, new.keyword_a, new.keyword_b, new.neta, new.memo);
        END
        """

    static let createBookFTSDeleteTriggerV6 = """
        CREATE TRIGGER IF NOT EXISTS book_ad AFTER DELETE ON book BEGIN
            INSERT INTO book_fts(book_fts, rowid, title, author, genre, keyword_a, keyword_b, neta, memo)
            VALUES ('delete', old.id, old.title, old.author, old.genre, old.keyword_a, old.keyword_b, old.neta, old.memo);
        END
        """

    static let createBookFTSUpdateTriggerV6 = """
        CREATE TRIGGER IF NOT EXISTS book_au AFTER UPDATE ON book BEGIN
            INSERT INTO book_fts(book_fts, rowid, title, author, genre, keyword_a, keyword_b, neta, memo)
            VALUES ('delete', old.id, old.title, old.author, old.genre, old.keyword_a, old.keyword_b, old.neta, old.memo);
            INSERT INTO book_fts(rowid, title, author, genre, keyword_a, keyword_b, neta, memo)
            VALUES (new.id, new.title, new.author, new.genre, new.keyword_a, new.keyword_b, new.neta, new.memo);
        END
        """

    static let backfillBookFTSV6 = """
        INSERT INTO book_fts(rowid, title, author, genre, keyword_a, keyword_b, neta, memo)
        SELECT id, title, author, genre, keyword_a, keyword_b, neta, memo FROM book
        """

    static let createIndexBookType = "CREATE INDEX IF NOT EXISTS idx_book_book_type ON book(book_type)"
    static let createIndexBookUnseen = "CREATE INDEX IF NOT EXISTS idx_book_unseen ON book(unseen)"
    static let createIndexBookRating = "CREATE INDEX IF NOT EXISTS idx_book_rating ON book(rating)"
    static let createIndexBookDateAdded = "CREATE INDEX IF NOT EXISTS idx_book_date_added ON book(date_added)"
    static let createIndexBookPlayDate = "CREATE INDEX IF NOT EXISTS idx_book_play_date ON book(play_date)"

    // MARK: - v7 migrations (FTS5 rebuild with trigram tokenizer)

    static let createBookFTS5V7 = """
        CREATE VIRTUAL TABLE IF NOT EXISTS book_fts USING fts5(
            title, author, genre, keyword_a, keyword_b, neta, memo,
            content='book', content_rowid='id', tokenize='trigram'
        )
        """

    static let createBookFTSInsertTriggerV7 = """
        CREATE TRIGGER IF NOT EXISTS book_ai AFTER INSERT ON book BEGIN
            INSERT INTO book_fts(rowid, title, author, genre, keyword_a, keyword_b, neta, memo)
            VALUES (new.id, new.title, new.author, new.genre, new.keyword_a, new.keyword_b, new.neta, new.memo);
        END
        """

    static let createBookFTSDeleteTriggerV7 = """
        CREATE TRIGGER IF NOT EXISTS book_ad AFTER DELETE ON book BEGIN
            INSERT INTO book_fts(book_fts, rowid, title, author, genre, keyword_a, keyword_b, neta, memo)
            VALUES ('delete', old.id, old.title, old.author, old.genre, old.keyword_a, old.keyword_b, old.neta, old.memo);
        END
        """

    static let createBookFTSUpdateTriggerV7 = """
        CREATE TRIGGER IF NOT EXISTS book_au AFTER UPDATE ON book BEGIN
            INSERT INTO book_fts(book_fts, rowid, title, author, genre, keyword_a, keyword_b, neta, memo)
            VALUES ('delete', old.id, old.title, old.author, old.genre, old.keyword_a, old.keyword_b, old.neta, old.memo);
            INSERT INTO book_fts(rowid, title, author, genre, keyword_a, keyword_b, neta, memo)
            VALUES (new.id, new.title, new.author, new.genre, new.keyword_a, new.keyword_b, new.neta, new.memo);
        END
        """

    static let backfillBookFTSV7 = """
        INSERT INTO book_fts(rowid, title, author, genre, keyword_a, keyword_b, neta, memo)
        SELECT id, title, author, genre, keyword_a, keyword_b, neta, memo FROM book
        """

    // MARK: - v8 (drop cover columns + thumbnails_directory_path)
    static let migrateV8DropCoverPath = "ALTER TABLE book DROP COLUMN cover_path"
    static let migrateV8DropCoverName = "ALTER TABLE book DROP COLUMN cover_name"
    static let migrateV8DropThumbnailsDir = "ALTER TABLE import_meta DROP COLUMN thumbnails_directory_path"

    // MARK: - v9 migrations

    /// v9 migration — seed filename_format default in library_settings (Stackroom Custom Format)
    static let migrateV9SeedFilenameFormat = """
        INSERT OR IGNORE INTO library_settings(key, value)
        VALUES ('filename_format', '(@genre) [@keywordB] [@author] @title')
        """

    // MARK: - v10 migrations

    static let migrateV10AddSeries = """
        ALTER TABLE book ADD COLUMN series TEXT
        """

    static let migrateV10AddVolume = """
        ALTER TABLE book ADD COLUMN volume REAL
        """

    // MARK: - v11 migrations

    static let migrateV11AddCoverImageName = """
        ALTER TABLE book ADD COLUMN cover_image_name TEXT
        """

    // MARK: - v12 migrations

    public static let migrateV12AddCoverCropRect = """
        ALTER TABLE book ADD COLUMN cover_crop_rect TEXT
        """

    // MARK: - v13 migrations (Phase 2.6b-2: per-book viewer state)

    static let createBookViewerStateTable = """
        CREATE TABLE IF NOT EXISTS book_viewer_state (
            book_id        INTEGER PRIMARY KEY REFERENCES book(id) ON DELETE CASCADE,
            spread_enabled INTEGER NOT NULL DEFAULT 0,
            cover_offset   INTEGER NOT NULL DEFAULT 1,
            last_page      INTEGER NOT NULL DEFAULT 0,
            updated_at     TEXT
        )
        """

    static let createBookPageLayoutTable = """
        CREATE TABLE IF NOT EXISTS book_page_layout (
            book_id    INTEGER NOT NULL REFERENCES book(id) ON DELETE CASCADE,
            page_index INTEGER NOT NULL,
            mode       INTEGER NOT NULL,
            PRIMARY KEY (book_id, page_index)
        )
        """

    static let createIndexBookSeries = "CREATE INDEX IF NOT EXISTS idx_book_series ON book(series)"
}
