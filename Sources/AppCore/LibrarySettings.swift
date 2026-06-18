// SPDX-License-Identifier: MIT
import Foundation
import OSLog
import Observation
import LibraryStore

public enum ViewMode: String, Codable {
    case grid, list
}

public struct WindowFrame: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct ColumnSort: Sendable, Codable, Equatable {
    public let column: BookColumn
    public let ascending: Bool

    public init(column: BookColumn, ascending: Bool) {
        self.column = column
        self.ascending = ascending
    }
}

/// Grid view / List view のソートモード。
/// 単一カラムソートは listViewSort (ColumnSort) で管理し、複合ソートはこの enum で管理する。
public enum SortMode: String, Codable, Sendable {
    /// 通常モード: listViewSort (ColumnSort) を使用する
    case column
    /// 複合ソート: シリーズ名（natural sort）→ 巻数（数値昇順）
    case seriesVolumeAsc
    /// 複合ソート: シリーズ名（natural sort 降順）→ 巻数（数値降順）
    case seriesVolumeDesc
}

@Observable
@MainActor
public final class LibrarySettings {
    private let database: Database
    public var listViewColumns: Set<BookColumn> {
        didSet { persistColumns() }
    }
    public var listViewSort: ColumnSort {
        didSet { persistSort() }
    }
    /// Column display order for the list view. Persisted for future use by
    /// TableColumnCustomization (Phase 2.4d). Currently has no effect on Table
    /// column order — that order is determined by declaration order in
    /// BookListView.primaryColumns / secondaryColumns. The persistence is in
    /// place so that when the reorder UI lands, existing user preferences (if
    /// any) are not lost.
    public var listColumnOrder: [BookColumn] {
        didSet { persistColumnOrder() }
    }
    public var filterState: FilterState {
        didSet { persistFilterState() }
    }
    public var browserPaneState: BrowserPaneState {
        didSet { persistBrowserPaneState() }
    }
    public var viewMode: ViewMode {
        didSet { persistViewMode() }
    }
    public var windowFrame: WindowFrame? {
        didSet { persistWindowFrame() }
    }
    public var filenameFormat: String {
        didSet { persistFilenameFormat() }
    }
    /// ライブラリの表示名（per-library）。空（空白のみ含む）ならファイル名にフォールバックする。
    /// 解決には `resolvedName(fallback:)` を使う。
    public var displayName: String {
        didSet { persistDisplayName() }
    }
    /// 命名フォーマットのプリセット集合（per-library）。`filenameFormat` は既定プリセットの format ミラー。
    public var filenameFormatPresets: [FilenameFormatPreset] {
        didSet { persistFilenameFormatPresets() }
    }
    public var defaultFilenameFormatPresetID: String {
        didSet { persistDefaultFilenameFormatPresetID() }
    }
    public var topPaneMode: String {
        didSet { persistTopPaneMode() }
    }
    /// User-defined stamp values per field column.
    /// key: StampField.dbColumn (e.g. "genre", "neta", "keyword_a")
    /// value: user-added values shown as chips in the stamp pane
    public var stampDefinitions: [String: [String]] {
        didSet { persistStampDefinitions() }
    }
    /// 重複検出で「無視」したグループのキー集合（per-library）。
    /// key: "exact:<hash>" または "possible:<series>\u{0}<volume>"。
    public var ignoredDuplicateKeys: Set<String> {
        didSet { persistIgnoredDuplicateKeys() }
    }
    /// 内容系フィールドのカスタムラベル。key = dbColumn（genre/neta/keyword_a/keyword_b/keyword_c）。
    /// 空文字値は永続化時に除外され、表示時は正準デフォルトにフォールバックする。
    public var customFieldLabels: [String: String] {
        didSet { persistCustomFieldLabels() }
    }
    /// bookType のカスタムラベル。key = "0".."5"。空文字は除外・フォールバック。
    public var customBookTypeLabels: [String: String] {
        didSet { persistCustomBookTypeLabels() }
    }
    public var lockPasswordHash: String? {
        didSet { persistLockHash() }
    }
    public var lockPasswordSalt: String? {
        didSet { persistLockSalt() }
    }
    public var useBiometric: Bool {
        didSet { persistUseBiometric() }
    }
    /// ライブラリの安定識別子。per-machine の生体認証アーム状態のキーに使う。
    /// 読み取り専用に公開し、生成は `ensureLibraryUUID()` 経由（遅延生成）。
    /// - Note: 他プロパティと異なり `didSet` を持たない。書き込みは `ensureLibraryUUID()`
    ///   内でのみ行われ、そこで直接永続化されるため（didSet 永続化との二重化を避ける）。
    public private(set) var libraryUUID: String?
    /// Per-column widths for the list view (key = BookColumn.rawValue, value = width in points).
    /// Persisted as JSON in library_settings. Restored when the bundle is opened.
    public var columnWidths: [String: Double] {
        didSet { persistColumnWidths() }
    }
    public var gridItemSize: Double {
        didSet { persistGridItemSize() }
    }
    /// "最近の項目" scope の対象期間（日数）。Stackroom 互換の Date-Added(within)。
    /// 既定 14 日。
    public var recentDays: Int {
        didSet { persistRecentDays() }
    }
    /// 現在適用中のソートモード。.column の場合は listViewSort を使用。
    /// .seriesVolumeAsc の場合は series→volume 複合ソートを適用。
    public var sortMode: SortMode {
        didSet { persistSortMode() }
    }
    /// 編集後にバックアップを保存するか（per-library）。既定 ON。
    public var backupEnabled: Bool {
        didSet { persistBackupEnabled() }
    }
    /// 保持する世代数（per-library）。既定 5、UI で 1–20。
    public var backupGenerations: Int {
        didSet { persistBackupGenerations() }
    }
    /// このライブラリをアプリ内蔵サーバ経由でリモート共有するか（per-library）。既定 OFF（明示オプトイン）。
    public var remoteSharingEnabled: Bool {
        didSet { persistRemoteSharingEnabled() }
    }

    private static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "LibrarySettings")
    private static let columnsKey = "listViewColumns"
    private static let sortKey = "listViewSort"
    private static let columnOrderKey = "listColumnOrder"
    private static let filterStateKey = "filterState"
    private static let browserPaneStateKey = "browserPaneState"
    private static let viewModeKey = "viewMode"
    private static let windowFrameKey = "windowFrame"
    private static let filenameFormatKey = "filename_format"
    private static let displayNameKey = "display_name"
    private static let filenameFormatPresetsKey = "filename_format_presets"
    private static let filenameFormatDefaultIDKey = "filename_format_default_id"
    private static let topPaneModeKey = "top_pane_mode"
    private static let lockHashKey = "lock_password_hash"
    private static let lockSaltKey = "lock_password_salt"
    private static let useBiometricKey = "lock_use_biometric"
    private static let libraryUUIDKey = "library_uuid"
    private static let columnWidthsKey = "columnWidths"
    private static let stampDefinitionsKey = "stamp_definitions"
    private static let ignoredDuplicateKeysKey = "ignored_duplicate_keys"
    private static let customFieldLabelsKey = "custom_field_labels"
    private static let customBookTypeLabelsKey = "custom_book_type_labels"
    private static let gridItemSizeKey = "grid_item_size"
    private static let recentDaysKey = "recent_days"
    private static let sortModeKey = "sort_mode"
    private static let backupEnabledKey = "backup_enabled"
    private static let backupGenerationsKey = "backup_generations"
    private static let remoteSharingEnabledKey = "remote_sharing_enabled"
    private static let defaultGridItemSize: Double = 160
    private static let defaultRecentDays: Int = 14
    private static let defaultSortMode: SortMode = .column
    private static let defaultBackupEnabled = true
    private static let defaultBackupGenerations = 5
    private static let defaultRemoteSharingEnabled = false
    private static let defaultFilenameFormat = "(@genre) [@keywordB] [@author] @title"
    private static let defaultTopPaneMode = "browse"
    private static let defaultColumns: Set<BookColumn> = Set(BookColumn.allCases.filter { $0.defaultEnabled })
    private static let defaultSort = ColumnSort(column: .dateAdded, ascending: false)

    public init(database: Database) throws {
        self.database = database
        // Load columns
        if let json = try database.getLibrarySetting(key: Self.columnsKey),
           let data = json.data(using: .utf8),
           let cols = try? JSONDecoder().decode(Set<BookColumn>.self, from: data) {
            self.listViewColumns = cols
        } else {
            self.listViewColumns = Self.defaultColumns
        }
        // Load sort
        if let json = try database.getLibrarySetting(key: Self.sortKey),
           let data = json.data(using: .utf8),
           let sort = try? JSONDecoder().decode(ColumnSort.self, from: data) {
            self.listViewSort = sort
        } else {
            self.listViewSort = Self.defaultSort
        }
        // Load column order. Append any BookColumn cases not present in the
        // persisted array so that newly-introduced columns become orderable
        // when the reorder UI lands. (Forward-compat trap mitigation.)
        if let json = try database.getLibrarySetting(key: Self.columnOrderKey),
           let data = json.data(using: .utf8),
           let order = try? JSONDecoder().decode([BookColumn].self, from: data) {
            let known = Set(order)
            let missing = BookColumn.allCases.filter { !known.contains($0) }
            self.listColumnOrder = order + missing
        } else {
            self.listColumnOrder = BookColumn.allCases
        }
        // Load filter state. Decode failure falls back to empty FilterState.
        if let json = try database.getLibrarySetting(key: Self.filterStateKey),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(FilterState.self, from: data) {
            self.filterState = decoded
        } else {
            self.filterState = FilterState()
        }
        // Load browser pane state. Decode failure falls back to default BrowserPaneState.
        if let json = try database.getLibrarySetting(key: Self.browserPaneStateKey),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(BrowserPaneState.self, from: data) {
            self.browserPaneState = decoded
        } else {
            self.browserPaneState = BrowserPaneState()
        }
        // Load viewMode. Decode failure falls back to grid.
        if let json = try database.getLibrarySetting(key: Self.viewModeKey),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(ViewMode.self, from: data) {
            self.viewMode = decoded
        } else {
            self.viewMode = .grid
        }
        // Load windowFrame. Decode failure falls back to nil (use default).
        if let json = try database.getLibrarySetting(key: Self.windowFrameKey),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(WindowFrame.self, from: data) {
            self.windowFrame = decoded
        } else {
            self.windowFrame = nil
        }
        // Load filenameFormat. Migration v9 seeds the default; if for any reason
        // the value is missing, fall back to the same hardcoded default.
        // Note: ローカル変数に先に受けて preset 移行ロジックでも使う（@Observable の init 内では
        // 全 stored property が代入される前に self メンバーを読めないため）。
        let loadedFilenameFormat: String
        if let value = try database.getLibrarySetting(key: Self.filenameFormatKey) {
            loadedFilenameFormat = value
        } else {
            loadedFilenameFormat = Self.defaultFilenameFormat
        }
        self.filenameFormat = loadedFilenameFormat
        // Load displayName. Default to empty string (falls back to filename via resolvedName).
        let loadedDisplayName: String
        if let value = try database.getLibrarySetting(key: Self.displayNameKey) {
            loadedDisplayName = value
        } else {
            loadedDisplayName = ""
        }
        self.displayName = loadedDisplayName
        // Load filename-format presets (Phase 2.7 B6). 無ければ単一 filenameFormat から移行。
        var didSeedPresets = false
        if let json = try database.getLibrarySetting(key: Self.filenameFormatPresetsKey),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([FilenameFormatPreset].self, from: data),
           !decoded.isEmpty {
            self.filenameFormatPresets = decoded
            let stored = try database.getLibrarySetting(key: Self.filenameFormatDefaultIDKey) ?? ""
            self.defaultFilenameFormatPresetID =
                FilenameFormatPresetLogic.validatedDefaultID(presets: decoded, requested: stored)
        } else {
            let m = FilenameFormatPresetLogic.migrate(existingFormat: loadedFilenameFormat, id: UUID().uuidString)
            self.filenameFormatPresets = m.presets
            self.defaultFilenameFormatPresetID = m.defaultID
            didSeedPresets = true
        }
        // Load topPaneMode. Default to "browse" if not set.
        if let value = try database.getLibrarySetting(key: Self.topPaneModeKey) {
            self.topPaneMode = value
        } else {
            self.topPaneMode = Self.defaultTopPaneMode
        }
        // Load lock fields. Defaults: no password, biometric off.
        self.lockPasswordHash = try database.getLibrarySetting(key: Self.lockHashKey)
        self.lockPasswordSalt = try database.getLibrarySetting(key: Self.lockSaltKey)
        self.useBiometric = (try database.getLibrarySetting(key: Self.useBiometricKey)) == "true"
        self.libraryUUID = try database.getLibrarySetting(key: Self.libraryUUIDKey)
        // Load columnWidths. Decode failure (first launch or corrupt data) starts with empty map.
        if let json = try database.getLibrarySetting(key: Self.columnWidthsKey),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: Double].self, from: data) {
            self.columnWidths = decoded
        } else {
            self.columnWidths = [:]
        }
        // Load stampDefinitions. Decode failure starts with empty map (no user-defined stamps).
        if let json = try database.getLibrarySetting(key: Self.stampDefinitionsKey),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            self.stampDefinitions = decoded
        } else {
            self.stampDefinitions = [:]
        }
        // Load ignoredDuplicateKeys. Decode failure starts with empty set.
        if let json = try database.getLibrarySetting(key: Self.ignoredDuplicateKeysKey),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(Set<String>.self, from: data) {
            self.ignoredDuplicateKeys = decoded
        } else {
            self.ignoredDuplicateKeys = []
        }
        // Load customFieldLabels. Decode failure starts with empty map.
        if let json = try database.getLibrarySetting(key: Self.customFieldLabelsKey),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            self.customFieldLabels = decoded
        } else {
            self.customFieldLabels = [:]
        }
        // Load customBookTypeLabels. Decode failure starts with empty map.
        if let json = try database.getLibrarySetting(key: Self.customBookTypeLabelsKey),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            self.customBookTypeLabels = decoded
        } else {
            self.customBookTypeLabels = [:]
        }
        // Load gridItemSize. Default 160pt.
        if let str = try database.getLibrarySetting(key: Self.gridItemSizeKey),
           let v = Double(str) {
            self.gridItemSize = v
        } else {
            self.gridItemSize = Self.defaultGridItemSize
        }
        // Load recentDays. Default 14 days.
        if let str = try database.getLibrarySetting(key: Self.recentDaysKey),
           let v = Int(str) {
            self.recentDays = v
        } else {
            self.recentDays = Self.defaultRecentDays
        }
        // Load sortMode. Default .column (use listViewSort).
        if let raw = try database.getLibrarySetting(key: Self.sortModeKey),
           let decoded = SortMode(rawValue: raw) {
            self.sortMode = decoded
        } else {
            self.sortMode = Self.defaultSortMode
        }
        // Load backup options. Defaults: enabled, 5 generations.
        if let str = try database.getLibrarySetting(key: Self.backupEnabledKey) {
            self.backupEnabled = (str == "true")
        } else {
            self.backupEnabled = Self.defaultBackupEnabled
        }
        if let str = try database.getLibrarySetting(key: Self.backupGenerationsKey),
           let v = Int(str) {
            self.backupGenerations = v
        } else {
            self.backupGenerations = Self.defaultBackupGenerations
        }
        // Load remote sharing opt-in. Default: off.
        if let str = try database.getLibrarySetting(key: Self.remoteSharingEnabledKey) {
            self.remoteSharingEnabled = (str == "true")
        } else {
            self.remoteSharingEnabled = Self.defaultRemoteSharingEnabled
        }
        // init 内の代入では didSet が発火しないため、移行で新規生成した場合は明示的に永続する。
        if didSeedPresets {
            persistFilenameFormatPresets()
            persistDefaultFilenameFormatPresetID()
        }
    }

    /// libraryUUID が無ければ生成して永続化し、返す。読み取り経路では呼ばないこと。
    public func ensureLibraryUUID() -> String {
        if let existing = libraryUUID { return existing }
        let new = UUID().uuidString
        do {
            try database.setLibrarySetting(key: Self.libraryUUIDKey, value: new)
            libraryUUID = new
        } catch {
            Self.logger.error("Failed to persist libraryUUID: \(error.localizedDescription, privacy: .public)")
            // 永続化に失敗しても呼び出し元には new を返す。libraryUUID は更新しないため
            // 次回呼び出しで再試行される（アーム失敗時はパスワード要求にフォールバック）。
        }
        return new
    }

    public func toggleColumn(_ col: BookColumn) {
        if col.alwaysVisible { return }
        if listViewColumns.contains(col) {
            listViewColumns.remove(col)
        } else {
            listViewColumns.insert(col)
        }
    }

    private func persistColumns() {
        do {
            let data = try JSONEncoder().encode(listViewColumns)
            let str = String(decoding: data, as: UTF8.self)
            try database.setLibrarySetting(key: Self.columnsKey, value: str)
        } catch {
            Self.logger.error("Failed to persist listViewColumns: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistSort() {
        do {
            let data = try JSONEncoder().encode(listViewSort)
            let str = String(decoding: data, as: UTF8.self)
            try database.setLibrarySetting(key: Self.sortKey, value: str)
        } catch {
            Self.logger.error("Failed to persist listViewSort: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistColumnOrder() {
        do {
            let data = try JSONEncoder().encode(listColumnOrder)
            let str = String(decoding: data, as: UTF8.self)
            try database.setLibrarySetting(key: Self.columnOrderKey, value: str)
        } catch {
            Self.logger.error("Failed to persist listColumnOrder: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistFilterState() {
        do {
            let data = try JSONEncoder().encode(filterState)
            let str = String(decoding: data, as: UTF8.self)
            try database.setLibrarySetting(key: Self.filterStateKey, value: str)
        } catch {
            Self.logger.error("Failed to persist filterState: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistBrowserPaneState() {
        do {
            let data = try JSONEncoder().encode(browserPaneState)
            let str = String(decoding: data, as: UTF8.self)
            try database.setLibrarySetting(key: Self.browserPaneStateKey, value: str)
        } catch {
            Self.logger.error("Failed to persist browserPaneState: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistViewMode() {
        do {
            let data = try JSONEncoder().encode(viewMode)
            let str = String(decoding: data, as: UTF8.self)
            try database.setLibrarySetting(key: Self.viewModeKey, value: str)
        } catch {
            Self.logger.error("Failed to persist viewMode: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistWindowFrame() {
        do {
            if let frame = windowFrame {
                let data = try JSONEncoder().encode(frame)
                let str = String(decoding: data, as: UTF8.self)
                try database.setLibrarySetting(key: Self.windowFrameKey, value: str)
            }
            // Note: We don't explicitly clear the database on nil assignment;
            // the last saved frame persists until overwritten.
        } catch {
            Self.logger.error("Failed to persist windowFrame: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistFilenameFormat() {
        do {
            try database.setLibrarySetting(key: Self.filenameFormatKey, value: filenameFormat)
        } catch {
            Self.logger.error("Failed to persist filenameFormat: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistDisplayName() {
        do {
            try database.setLibrarySetting(key: Self.displayNameKey, value: displayName)
        } catch {
            Self.logger.error("Failed to persist displayName: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 表示名。未設定（空白のみ含む）なら fallback（通常はファイル名）を返す。
    public func resolvedName(fallback: String) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func persistFilenameFormatPresets() {
        do {
            let data = try JSONEncoder().encode(filenameFormatPresets)
            let str = String(data: data, encoding: .utf8) ?? "[]"
            try database.setLibrarySetting(key: Self.filenameFormatPresetsKey, value: str)
        } catch {
            Self.logger.error("Failed to persist filenameFormatPresets: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistDefaultFilenameFormatPresetID() {
        do {
            try database.setLibrarySetting(key: Self.filenameFormatDefaultIDKey, value: defaultFilenameFormatPresetID)
        } catch {
            Self.logger.error("Failed to persist defaultFilenameFormatPresetID: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// プリセットを追加 or 同 id を更新し、既定 format ミラーを同期する。
    public func upsertPreset(_ preset: FilenameFormatPreset) {
        if let i = filenameFormatPresets.firstIndex(where: { $0.id == preset.id }) {
            filenameFormatPresets[i] = preset
        } else {
            filenameFormatPresets.append(preset)
        }
        syncDefaultFilenameFormat()
    }

    /// プリセット削除（最後の1件は no-op、既定削除時は先頭へ振替）。
    public func removePreset(id: String) {
        let r = FilenameFormatPresetLogic.removing(id: id, presets: filenameFormatPresets,
                                                   defaultID: defaultFilenameFormatPresetID)
        filenameFormatPresets = r.presets
        defaultFilenameFormatPresetID = r.defaultID
        syncDefaultFilenameFormat()
    }

    /// 既定プリセットを設定（無効 id は弾く）。
    public func setDefaultPreset(id: String) {
        defaultFilenameFormatPresetID =
            FilenameFormatPresetLogic.validatedDefaultID(presets: filenameFormatPresets, requested: id)
        syncDefaultFilenameFormat()
    }

    /// 既定プリセットの format を `filenameFormat`（消費側が読むミラー）へ反映。
    private func syncDefaultFilenameFormat() {
        let f = FilenameFormatPresetLogic.defaultFormat(in: filenameFormatPresets,
                                                        defaultID: defaultFilenameFormatPresetID)
        if filenameFormat != f { filenameFormat = f }  // didSet で永続
    }

    private func persistTopPaneMode() {
        do {
            try database.setLibrarySetting(key: Self.topPaneModeKey, value: topPaneMode)
        } catch {
            Self.logger.error("Failed to persist topPaneMode: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistLockHash() {
        do {
            if let h = lockPasswordHash {
                try database.setLibrarySetting(key: Self.lockHashKey, value: h)
            } else {
                try database.deleteLibrarySetting(key: Self.lockHashKey)
            }
        } catch {
            Self.logger.error("Failed to persist lockPasswordHash: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistLockSalt() {
        do {
            if let s = lockPasswordSalt {
                try database.setLibrarySetting(key: Self.lockSaltKey, value: s)
            } else {
                try database.deleteLibrarySetting(key: Self.lockSaltKey)
            }
        } catch {
            Self.logger.error("Failed to persist lockPasswordSalt: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistUseBiometric() {
        do {
            try database.setLibrarySetting(key: Self.useBiometricKey, value: useBiometric ? "true" : "false")
        } catch {
            Self.logger.error("Failed to persist useBiometric: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistColumnWidths() {
        do {
            let data = try JSONEncoder().encode(columnWidths)
            let str = String(decoding: data, as: UTF8.self)
            try database.setLibrarySetting(key: Self.columnWidthsKey, value: str)
        } catch {
            Self.logger.error("Failed to persist columnWidths: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistStampDefinitions() {
        do {
            let data = try JSONEncoder().encode(stampDefinitions)
            let str = String(data: data, encoding: .utf8) ?? "{}"
            try database.setLibrarySetting(key: Self.stampDefinitionsKey, value: str)
        } catch {
            Self.logger.error("Failed to persist stampDefinitions: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistIgnoredDuplicateKeys() {
        do {
            let data = try JSONEncoder().encode(ignoredDuplicateKeys)
            try database.setLibrarySetting(key: Self.ignoredDuplicateKeysKey, value: String(decoding: data, as: UTF8.self))
        } catch {
            Self.logger.error("Failed to persist ignoredDuplicateKeys: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistCustomFieldLabels() {
        do {
            let cleaned = customFieldLabels.filter { !$0.value.isEmpty }
            let data = try JSONEncoder().encode(cleaned)
            try database.setLibrarySetting(key: Self.customFieldLabelsKey, value: String(decoding: data, as: UTF8.self))
        } catch {
            Self.logger.error("Failed to persist customFieldLabels: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistCustomBookTypeLabels() {
        do {
            let cleaned = customBookTypeLabels.filter { !$0.value.isEmpty }
            let data = try JSONEncoder().encode(cleaned)
            try database.setLibrarySetting(key: Self.customBookTypeLabelsKey, value: String(decoding: data, as: UTF8.self))
        } catch {
            Self.logger.error("Failed to persist customBookTypeLabels: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistGridItemSize() {
        do {
            try database.setLibrarySetting(key: Self.gridItemSizeKey, value: String(gridItemSize))
        } catch {
            Self.logger.error("Failed to persist gridItemSize: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistRecentDays() {
        do {
            try database.setLibrarySetting(key: Self.recentDaysKey, value: String(recentDays))
        } catch {
            Self.logger.error("Failed to persist recentDays: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistSortMode() {
        do {
            try database.setLibrarySetting(key: Self.sortModeKey, value: sortMode.rawValue)
        } catch {
            Self.logger.error("Failed to persist sortMode: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistBackupEnabled() {
        do {
            try database.setLibrarySetting(key: Self.backupEnabledKey, value: backupEnabled ? "true" : "false")
        } catch {
            Self.logger.error("Failed to persist backupEnabled: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistBackupGenerations() {
        do {
            try database.setLibrarySetting(key: Self.backupGenerationsKey, value: String(backupGenerations))
        } catch {
            Self.logger.error("Failed to persist backupGenerations: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistRemoteSharingEnabled() {
        do {
            try database.setLibrarySetting(key: Self.remoteSharingEnabledKey, value: remoteSharingEnabled ? "true" : "false")
        } catch {
            Self.logger.error("Failed to persist remoteSharingEnabled: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Label resolvers (A22/A23)

public extension LibrarySettings {
    /// カスタマイズ対象フィールドの dbColumn 名。これ以外は常に正準ラベル。
    /// - BookColumn: genre / neta / keyword_a / keyword_b（keywordC は BookColumn 未定義）
    /// - StampField / BrowseField: 上記 + keyword_c も対象
    static let customizableFieldKeys: Set<String> =
        ["genre", "neta", "keyword_a", "keyword_b", "keyword_c"]

    /// 列ラベル。対象フィールドのみカスタム、それ以外は正準（localizedTitleString）。
    func label(for column: BookColumn) -> String {
        let key = column.rawValue   // BookColumn の rawValue は dbColumn と一致（genre/neta/keyword_a/keyword_b）
        guard Self.customizableFieldKeys.contains(key) else { return column.localizedTitleString }
        return effectiveLabel(default: column.localizedTitleString, override: customFieldLabels[key])
    }

    /// スタンプペインのフィールドラベル。
    func stampLabel(for field: StampField) -> String {
        effectiveLabel(default: field.localizedTitle, override: customFieldLabels[field.dbColumn])
    }

    /// ブラウズペインのフィールドラベル（String 版。SwiftUI では Text(_:) に渡す）。
    func browseLabel(for field: BrowserPaneState.BrowseField) -> String {
        let key = field.sqlColumn
        let canonical = Self.browseDefaultString(field)
        guard Self.customizableFieldKeys.contains(key) else { return canonical }
        return effectiveLabel(default: canonical, override: customFieldLabels[key])
    }

    /// bookType ラベル（0..5）。
    func bookTypeLabel(_ raw: Int) -> String {
        effectiveLabel(default: BookTypeLabel.canonicalLabel(for: raw), override: customBookTypeLabels[String(raw)])
    }

    /// ファイル名生成 `@type` 用の bookType カスタムラベル（Int キー・空値除外）。
    /// `FilenameFormatter.format(_:with:bookTypeLabels:)` に渡すことで WYSIWYG を実現する。
    var bookTypeLabelOverrides: [Int: String] {
        Dictionary(uniqueKeysWithValues: customBookTypeLabels.compactMap { key, value in
            guard let i = Int(key), !value.isEmpty else { return nil }
            return (i, value)
        })
    }
}

private extension LibrarySettings {
    /// BrowseField の正準ラベル（String）。LocalizedStringKey を文字列化するための対応表。
    static func browseDefaultString(_ field: BrowserPaneState.BrowseField) -> String {
        switch field {
        case .genre:    return String(localized: "ジャンル")
        case .series:   return String(localized: "シリーズ")
        case .author:   return String(localized: "作者")
        case .neta:     return String(localized: "関連")
        case .keywordA: return String(localized: "キーワード A")
        case .keywordB: return String(localized: "キーワード B")
        case .keywordC: return String(localized: "キーワード C")
        }
    }
}
