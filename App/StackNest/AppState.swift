// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import LibraryStore
import StackroomFormat
import ImageCache
import AppCore
import ArchiveAdapter
import LibraryServerAPI
import OSLog

@Observable
@MainActor
final class AppState {
    let bundleURL: URL
    let bundle: LibraryBundle

    var database: Database?
    var displayedBooks: [BookRow] = []
    var thumbnailLoader: ThumbnailLoader?
    /// G4c: 本ごとの表紙版数。外部要因（リモート編集）で表紙が変わった本だけ bump し、その本の
    /// ローカル表紙ビュー（BookCell/DetailPaneView）を再取得させる。グローバル bump は高頻度イベント
    /// （progress/rating 等）で可視グリッド全体をフリッカさせるため per-book にする。
    var coverVersionByBook: [Int: Int] = [:]
    var isImporting: Bool = false
    var importProgress: (processed: Int, total: Int)?
    var importSummary: ImportSummary?
    var error: AppError?
    let viewerSettings: ViewerSettings = .shared
    /// G10: 詳細ペインの表紙表示トグル（per-browser・このウィンドウ専用・既定 true）。
    /// ツールバーボタンで切り替え、DetailPaneView(showCover:) に注入する。
    var showDetailCover: Bool = true

    /// 監視フォルダ自動取込の要約（バナー表示用・一定時間で自動クリア）。
    var watchImportSummary: String?
    private var folderWatcher: FolderWatcher?
    private var watchSummaryClearTask: Task<Void, Never>?

    // v0.4a additions
    var selectedSidebarItem: SidebarItem? = .library
    var shelves: [PlaylistRow] = []  // kind != favorites のみ
    var favoritesShelfID: Int64?
    var favoritesBookIDs: Set<Int> = []
    var selectedBook: BookRow?

    // v0.4b additions
    var viewMode: ViewMode = .grid {
        didSet {
            guard oldValue != viewMode, let settings = librarySettings else { return }
            settings.viewMode = viewMode
        }
    }
    var searchQuery: String = "" {
        didSet {
            selectedBookIDs = []
            do { try refreshDisplayedBooks() } catch { self.error = .unexpected(error) }
        }
    }
    var selectedBookIDs: Set<Int> = [] {
        didSet { refreshDisplayedSelectedBooks() }
    }
    var librarySettings: LibrarySettings?

    /// このアプリ単位の UndoManager。SwiftUI `@Environment(\.undoManager)` が
    /// WindowGroup app では Edit menu の ⌘Z (responder chain 由来 undoManager) と
    /// 一致しないことが diagnostic ログで確認済 (2026-05-23): SwiftUI 環境変数で渡された
    /// undoManager に register しても Edit menu からの ⌘Z はそれを trigger しない。
    /// 構造的解決として AppState 自身が UndoManager を所有し、すべての register/undo を
    /// この instance に集約。Edit menu は SwiftUI `.commands` で AppState.undoManager に
    /// bind する (StackNestApp 側で実装)。
    let undoManager: UndoManager = {
        let um = UndoManager()
        um.levelsOfUndo = 0  // unlimited
        return um
    }()

    /// `undoManager.canUndo` / `canRedo` は AppKit の旧 KVO API で SwiftUI の
    /// `@Observable` dependency tracking では監視できない。register / undo / redo の
    /// たびにこの counter を bump することで SwiftUI に「stack state が変わった」と
    /// 通知し、Edit menu の disabled / actionName が再評価される。
    /// menu 側は `.disabled` closure 内で `undoStateVersion` を read することで
    /// dependency tracking を成立させる。
    var undoStateVersion: Int = 0

    // v0.5a additions
    /// Books whose IDs match selectedBookIDs, fetched fresh from displayedBooks.
    /// Used by detail pane for multi-select editing. Updated whenever
    /// selectedBookIDs or displayedBooks changes.
    var displayedSelectedBooks: [BookRow] = []

    /// Cached sorted view of displayedBooks. Updated when displayedBooks or
    /// listViewSort changes. Avoids re-sorting on every SwiftUI Table render
    /// (which traverses all 10K+ rows on each redraw).
    var sortedDisplayedBooks: [BookRow] = []

    /// Monotonically increasing counter bumped whenever sortedDisplayedBooks
    /// is rebuilt (via refreshSortedDisplayedBooks). NSTableView wrapper uses
    /// this to detect content-level data changes (e.g., metadata edits that
    /// don't change row count or id ordering) and trigger reloadData.
    var sortedDisplayedBooksVersion: Int = 0

    /// Monotonically increasing counter bumped whenever the underlying DB books
    /// data changes (i.e., on every refreshDisplayedBooks call). BrowserColumnView
    /// uses this in its refreshTrigger so that adding/deleting books causes the
    /// Browser pane distinct-value lists to re-fetch immediately.
    var booksDataVersion: Int = 0

    // MARK: - Phase 2.8 B22: DB preventive safety

    /// B22: 開いた時点の file change counter。閉じる時にこれと比較して編集有無を判定する。
    private var lastChangeCounter: UInt32?
    /// B22: 同一セッションで二重にバックアップしないためのガード。
    private var didBackupThisSession = false

    /// B22: 終了時バックアップ・4.1b 配信対象列挙のため、開いている AppState を
    /// 弱参照で追跡する @Observable レジストリ。メンバー増減で SwiftUI 再描画が走る
    /// （NSHashTable 直持ちでは @Observable 非対応のため再描画されなかった: 4.1b smoke F2）。
    @MainActor static let activeInstances = AppStateRegistry()

    // MARK: - Phase 2.6a FX2: live sidebar badges

    /// シェルフの内容（条件・所属本）が変わるたびに bump する counter。
    /// SidebarView.shelfRow がこれを read することで、PlaylistRow の field が変化しない
    /// 内容変更（スマートシェルフ条件編集・本の追加/除外）でも badge を再評価させる。
    var shelvesContentVersion: Int = 0

    /// "ライブラリ" バッジ件数（@Observable で live 更新）。reloadSidebarCounts で更新。
    var libraryBookCount: Int = 0

    /// "最近の項目" バッジ件数（@Observable で live 更新）。reloadSidebarCounts で更新。
    var recentBookCount: Int = 0

    private static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "AppState")
    private static let sortLogger = Logger(subsystem: "app.shelfsmith.stacknest", category: "Sort")
    private static let coverLogger = Logger(subsystem: "app.shelfsmith.stacknest", category: "CoverReflow")

    init(bundleURL: URL) {
        self.bundleURL = bundleURL
        self.bundle = LibraryBundle(url: bundleURL)
    }

    // MARK: - Phase 2.8 B22: backup helpers / corruption alerts

    enum CorruptionChoice { case restore, openAnyway, cancel }

    static func backupTimestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    static func presentCorruptionAlert() -> CorruptionChoice {
        let a = NSAlert()
        a.messageText = String(localized: "データベースに問題が見つかりました")
        a.informativeText = String(localized: "最新の正常なバックアップから復元しますか？")
        a.addButton(withTitle: String(localized: "復元する"))
        a.addButton(withTitle: String(localized: "そのまま開く"))
        a.addButton(withTitle: String(localized: "キャンセル"))
        switch a.runModal() {
        case .alertFirstButtonReturn: return .restore
        case .alertSecondButtonReturn: return .openAnyway
        default: return .cancel
        }
    }

    enum RestoreFailedChoice { case tryRecover, dismiss }

    static func presentRestoreFailedAlert(bundleURL: URL) -> RestoreFailedChoice {
        let a = NSAlert()
        a.messageText = String(localized: "バックアップから復元できませんでした")
        a.informativeText = String(localized: "利用可能なバックアップが無いか、復元後も問題が残っています。`.recover` で可能な範囲のデータ救出を試せます（完全性は保証されません）。")
        a.addButton(withTitle: String(localized: ".recover で修復を試す"))
        a.addButton(withTitle: String(localized: "バックアップフォルダを表示"))
        a.addButton(withTitle: String(localized: "閉じる"))
        switch a.runModal() {
        case .alertFirstButtonReturn:
            return .tryRecover
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(BackupManager.backupsDir(for: bundleURL))
            return .dismiss
        default:
            return .dismiss
        }
    }

    /// B22: 閉じる時のバックアップ。このセッションで編集があり（change counter 増加）、
    /// quick_check が正常なときだけ 1 世代取得して prune する。閲覧のみ・無編集はスキップ。
    /// 同一セッションで一度だけ実行（terminate と closeBundle の二重呼びをガード）。
    func backupOnCloseIfNeeded() {
        guard !didBackupThisSession else { return }
        guard let db = database, let settings = librarySettings else { return }
        guard settings.backupEnabled else { return }
        let current = BackupManager.changeCounter(of: bundle.databaseURL)
        // 編集なし（counter 不変）ならスキップ。counter 取得失敗時は安全側で取得する。
        if let before = lastChangeCounter, let now = current, before == now { return }
        guard (try? db.quickCheck()) == true else {
            Self.logger.error("B22: skip backup-on-close (quick_check not ok)")
            return
        }
        do {
            try BackupManager.makeBackup(from: db, bundleURL: bundle.url, timestamp: Self.backupTimestamp())
            try BackupManager.prune(in: BackupManager.backupsDir(for: bundle.url), keep: settings.backupGenerations)
            didBackupThisSession = true
        } catch {
            Self.logger.error("B22: backup-on-close failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Opens the bundle: validates structure, opens DB, runs migrations,
    /// loads initial state. Throws if bundle is corrupt.
    func openBundle() throws {
        try bundle.validate()
        // Finder-locked (user-immutable) / read-only libraries can't run migrations
        // (SQLite must write a journal/WAL); surface a clear localized error instead of
        // a cryptic SQLite "unable to open database file" message.
        let fm = FileManager.default
        let dirImmutable = (try? bundle.url.resourceValues(forKeys: [.isUserImmutableKey]).isUserImmutable) ?? false
        let dbImmutable = (try? bundle.databaseURL.resourceValues(forKeys: [.isUserImmutableKey]).isUserImmutable) ?? false
        if dirImmutable || dbImmutable
            || !fm.isWritableFile(atPath: bundle.url.path(percentEncoded: false))
            || !fm.isWritableFile(atPath: bundle.databaseURL.path(percentEncoded: false)) {
            throw LibraryOpenError.readOnly(bundle.url)
        }
        let db = try Database.openExisting(at: bundle.databaseURL)
        // Phase 2.8 B22: 開く時の整合性チェック。破損していたらバックアップ復元を提案する
        // （ここではバックアップは取らない。世代取得は閉じる時に編集ありのときのみ）。
        if try !db.quickCheck() {
            switch Self.presentCorruptionAlert() {
            case .restore:
                db.close()
                let ts = Self.backupTimestamp()
                let restored = (try? BackupManager.restoreLatest(
                    bundleURL: bundle.url,
                    databaseFileName: bundle.databaseURL.lastPathComponent,
                    timestamp: ts)) ?? false
                let reopened = try Database.openExisting(at: bundle.databaseURL)
                let reopenedOk = restored && ((try? reopened.quickCheck()) ?? false)
                if !reopenedOk {
                    reopened.close()
                    switch Self.presentRestoreFailedAlert(bundleURL: bundle.url) {
                    case .tryRecover:
                        try attemptRecover()   // 成功時は open まで進めて return、失敗時は throw
                        return
                    case .dismiss:
                        throw LibraryOpenError.cancelledByUser
                    }
                }
                self.lastChangeCounter = BackupManager.changeCounter(of: bundle.databaseURL)
                try reopened.migrate()
                try finishOpening(db: reopened)
                return
            case .openAnyway:
                break   // fall through to migrate (self-responsibility)
            case .cancel:
                db.close()
                throw LibraryOpenError.cancelledByUser
            }
        }
        self.lastChangeCounter = BackupManager.changeCounter(of: bundle.databaseURL)
        try db.migrate()  // ensures latest schema
        try finishOpening(db: db)
    }

    /// migrate 済みの DB を受け取り、state をロードして UI を初期化する。
    /// 通常オープンと B22 復元後オープンの両方から呼ぶ。
    private func finishOpening(db: Database) throws {
        self.favoritesShelfID = try db.ensureFavoritesShelf()
        self.database = db
        self.librarySettings = try LibrarySettings(database: db)
        self.viewMode = self.librarySettings?.viewMode ?? .grid
        self.thumbnailLoader = ThumbnailLoader(bundleURL: bundleURL)
        reloadFavoritesCache()
        self.shelves = try db.fetchAllShelves().filter { $0.kind != "favorites" }
        reloadSidebarCounts()
        // 起動直後に残留 state がないことを保証する (grid 初期クリック複数選択防止)
        self.selectedBookIDs = []
        self.selectedBook = nil
        try refreshDisplayedBooks()
        // B22: セッションガードをリセットし、終了時バックアップ用に自身を登録する。
        self.didBackupThisSession = false
        Self.activeInstances.add(self)
        // Phase 4.2d-1: 監視フォルダウォッチャーを起動する。
        reloadFolderWatcher()
        // Phase 4.2c-2: ローカル resume 意図を 1 回だけ消費する。本ライブラリの bundlePath と
        // 一致し、対象 bookID が存在すれば続き確認なしで内蔵ビューワを開く（resumeDirect）。
        if let p = LocalResumeIntent.shared.pending, bundleURL.path == p.bundlePath,
           let row = try? database?.fetchBook(id: p.bookID) {
            LocalResumeIntent.shared.pending = nil
            openBooks([row], resumeDirect: true)
        }
    }

    /// B23: `.recover` による最終手段の修復。入力＝最新の壊れた本体（library.corrupt-* 優先、
    /// 無ければ library.sqlite）→ 救出 DB を生成・検証 → 正常なら現本体を library.prerecover-* に
    /// 退避して差し替え → migrate → 開く。失敗時は live を変更せず案内のみ。
    func attemptRecover() throws {
        let fm = FileManager.default
        let ts = Self.backupTimestamp()
        let live = bundle.databaseURL
        let input = Self.latestCorruptFile(in: bundle.url) ?? live
        let out = bundle.url.appendingPathComponent("library.recovered-\(ts).sqlite")

        func failAndCleanup() {
            if fm.fileExists(atPath: out.path) { try? fm.removeItem(at: out) }
            Self.presentRecoverFailedAlert(bundleURL: bundle.url)
        }

        let recovered = (try? DatabaseRecovery.recover(from: input, to: out)) ?? false
        guard recovered else { failAndCleanup(); throw LibraryOpenError.cancelledByUser }

        // 救出結果を検証。本の件数も probe が開いている間に読む。
        let probe = try? Database.openExisting(at: out)
        let probeOk = (try? (probe?.quickCheck() ?? false)) ?? false
        let recoveredBooks = (try? (probe?.fetchBookCount() ?? 0)) ?? 0
        probe?.close()
        guard probeOk else { failAndCleanup(); throw LibraryOpenError.cancelledByUser }

        if recoveredBooks == 0 {
            // 救出はできたが本が 0 件。空で置き換えるかをユーザーに確認する。
            switch Self.presentRecoverEmptyAlert() {
            case .keep:
                try? fm.removeItem(at: out)   // 採用しない。live は不変。
                throw LibraryOpenError.cancelledByUser
            case .replace:
                break   // 空でも置き換えて続行
            }
        } else {
            // 件数を提示してから開く（差し替え前に出す。finishOpening 後だとウィンドウ遷移で
            // モーダルが surface しないため）。
            let a = NSAlert()
            a.messageText = String(localized: "修復が完了しました")
            a.informativeText = String(localized: "本 \(recoveredBooks) 件を復元しました。復元できなかったデータがある場合があります。元のファイルは library.prerecover-* に残っています。")
            a.runModal()
        }

        // 差し替え: 現本体を退避（削除しない）→ stale sidecar 除去 → 救出 DB を本体名へ。
        let pre = bundle.url.appendingPathComponent("library.prerecover-\(ts).sqlite")
        if fm.fileExists(atPath: live.path) { try fm.moveItem(at: live, to: pre) }
        for sc in ["\(live.lastPathComponent)-wal", "\(live.lastPathComponent)-shm", "\(live.lastPathComponent)-journal"] {
            let s = bundle.url.appendingPathComponent(sc)
            if fm.fileExists(atPath: s.path) { try fm.removeItem(at: s) }
        }
        try fm.moveItem(at: out, to: live)

        // 開く。
        let db = try Database.openExisting(at: live)
        self.lastChangeCounter = BackupManager.changeCounter(of: live)
        try db.migrate()
        try finishOpening(db: db)
    }

    /// バンドル内の最新 `library.corrupt-*.sqlite` を返す（無ければ nil）。
    static func latestCorruptFile(in bundleURL: URL) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: bundleURL, includingPropertiesForKeys: nil)) ?? []
        return items
            .filter { $0.lastPathComponent.hasPrefix("library.corrupt-") && $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .first
    }

    enum RecoverEmptyChoice { case replace, keep }

    static func presentRecoverEmptyAlert() -> RecoverEmptyChoice {
        let a = NSAlert()
        a.messageText = String(localized: "本のデータを復元できませんでした")
        a.informativeText = String(localized: "救出を試みましたが、本のデータは 0 件でした（破損箇所に本の情報が含まれていた可能性があります）。空のライブラリで置き換えますか？ 元の破損ファイルは library.prerecover-* / library.corrupt-* に残ります。")
        a.addButton(withTitle: String(localized: "やめる"))            // first = default
        a.addButton(withTitle: String(localized: "空で置き換える"))
        return a.runModal() == .alertFirstButtonReturn ? .keep : .replace
    }

    static func presentRecoverFailedAlert(bundleURL: URL) {
        let a = NSAlert()
        a.messageText = String(localized: "修復できませんでした")
        a.informativeText = String(localized: "`.recover` でも有効なデータベースを救出できませんでした。復旧手順書（recovery-guide）を参照してください。元のファイルは変更していません。")
        a.addButton(withTitle: String(localized: "バックアップフォルダを表示"))
        a.addButton(withTitle: String(localized: "閉じる"))
        if a.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(BackupManager.backupsDir(for: bundleURL))
        }
    }

    func closeBundle() {
        folderWatcher?.stop()
        folderWatcher = nil
        watchSummaryClearTask?.cancel()
        watchSummaryClearTask = nil
        backupOnCloseIfNeeded()
        database?.close()
        database = nil
        thumbnailLoader = nil
        displayedBooks = []
        sortedDisplayedBooks = []
        shelves = []
        favoritesShelfID = nil
        favoritesBookIDs = []
        selectedBook = nil
        selectedSidebarItem = .library
        librarySettings = nil
        Self.activeInstances.remove(self)
    }

    /// Re-fetches displayedBooks based on current selectedSidebarItem, routing through searchBooks.
    func refreshDisplayedBooks() throws {
        guard let db = database else { displayedBooks = []; return }
        guard let item = selectedSidebarItem else { displayedBooks = []; return }

        let scope: SidebarScope
        switch item {
        case .library:
            scope = .library
        case .favorites:
            guard let favID = favoritesShelfID else { displayedBooks = []; return }
            scope = .favorites(playlistID: favID)
        case .recent:
            scope = .recent(days: librarySettings?.recentDays ?? 14)
        case .shelf(let id, _, _):
            scope = .shelf(playlistID: id)
        case .smartShelf(let id, _):
            scope = .smartShelf(playlistID: id)
        }

        let filter = librarySettings?.filterState ?? FilterState()
        let browserState = librarySettings?.browserPaneState ?? BrowserPaneState()
        let browserConstraints: [(String, String)] = (librarySettings?.topPaneMode == "browse")
            ? zip(browserState.fields, browserState.selections).compactMap { (field, sel) in
                guard let f = field, let s = sel else { return nil }
                return (f.sqlColumn, s)
            }
            : []
        displayedBooks = try db.searchBooks(
            query: searchQuery,
            sidebarScope: scope,
            filter: filter,
            browserConstraints: browserConstraints
        )
        booksDataVersion += 1
        reloadSidebarCounts()
        refreshSortedDisplayedBooks()
        refreshDisplayedSelectedBooks()
    }

    /// "ライブラリ" / "最近の項目" の badge 件数を DB から再計算して stored property に格納する。
    /// @Observable のため SwiftUI sidebar の builtInRow は値変化で自動 re-render される。
    /// 失敗時は 0（意図的な握りつぶし — badge は補助情報のため）。
    func reloadSidebarCounts() {
        guard let db = database else {
            libraryBookCount = 0
            recentBookCount = 0
            return
        }
        libraryBookCount = (try? db.fetchBookCount()) ?? 0
        recentBookCount = (try? db.fetchRecentBookCount(days: librarySettings?.recentDays ?? 14)) ?? 0
    }

    /// Switches selected sidebar item, clears selectedBook, clears selection, refreshes displayedBooks.
    func switchTo(_ item: SidebarItem) {
        selectedSidebarItem = item
        selectedBook = nil
        selectedBookIDs = []
        do {
            try refreshDisplayedBooks()
        } catch {
            self.error = .unexpected(error)
        }
    }

    @discardableResult
    func createShelf(name: String) -> Int64? {
        guard let db = database else { return nil }
        do {
            let newID = try db.createUserShelf(title: name)
            self.shelves = try db.fetchAllShelves().filter { $0.kind != "favorites" }
            shelvesContentVersion += 1
            return newID
        } catch {
            self.error = .unexpected(error)
            return nil
        }
    }

    func renameShelf(id: Int64, name: String) {
        guard let db = database else { return }
        do {
            try db.renameShelf(id: id, title: name)
            self.shelves = try db.fetchAllShelves().filter { $0.kind != "favorites" }
            if case .shelf(let sid, _, let k) = selectedSidebarItem, sid == id {
                selectedSidebarItem = .shelf(id: id, name: name, kind: k)
            }
        } catch {
            self.error = .unexpected(error)
        }
    }

    func deleteShelf(id: Int64) {
        guard let db = database else { return }
        do {
            try db.deleteShelf(id: id)
            self.shelves = try db.fetchAllShelves().filter { $0.kind != "favorites" }
            shelvesContentVersion += 1
            if case .shelf(let sid, _, _) = selectedSidebarItem, sid == id {
                switchTo(.library)
            } else if case .smartShelf(let sid, _) = selectedSidebarItem, sid == id {
                switchTo(.library)
            }
        } catch {
            self.error = .unexpected(error)
        }
    }

    @discardableResult
    func createSmartShelf(name: String, conditions: SmartShelfConditions) -> Int64? {
        guard let db = database else { return nil }
        do {
            let newID = try db.createSmartShelf(title: name, conditions: conditions)
            self.shelves = try db.fetchAllShelves().filter { $0.kind != "favorites" }
            shelvesContentVersion += 1
            return newID
        } catch {
            self.error = .unexpected(error)
            return nil
        }
    }

    func updateSmartShelf(id: Int64, name: String, conditions: SmartShelfConditions) {
        guard let db = database else { return }
        do {
            try db.updateSmartShelfConditions(id: id, conditions: conditions)
            try db.renameShelf(id: id, title: name)
            self.shelves = try db.fetchAllShelves().filter { $0.kind != "favorites" }
            shelvesContentVersion += 1
            if case .smartShelf(let sid, _) = selectedSidebarItem, sid == id {
                selectedSidebarItem = .smartShelf(id: id, name: name)
                try refreshDisplayedBooks()
            }
        } catch {
            self.error = .unexpected(error)
        }
    }

    /// サイドバーのバッジ件数。エラー時は 0 を返す（意図的な握りつぶし）。
    func smartShelfBookCount(id: Int64) -> Int {
        guard let db = database else { return 0 }
        return (try? db.searchBooks(query: "", sidebarScope: .smartShelf(playlistID: id)).count) ?? 0
    }

    /// 編集用に条件を読む。失敗時 nil（= 条件無しと同義の安全側）。
    func fetchSmartShelfConditions(id: Int64) -> SmartShelfConditions? {
        guard let db = database else { return nil }
        return try? db.fetchSmartShelfConditions(id: id)
    }

    func addBooksToShelf(_ shelfID: Int64, books: [Int]) {
        guard let db = database else { return }
        do {
            try db.appendBooksToShelf(playlistID: shelfID, bookIDs: books)
            if shelfID == favoritesShelfID {
                reloadFavoritesCache()
            }
            // If currently viewing this shelf, refresh
            if case .shelf(let sid, _, _) = selectedSidebarItem, sid == shelfID {
                try refreshDisplayedBooks()
            }
            if case .favorites = selectedSidebarItem, shelfID == favoritesShelfID {
                try refreshDisplayedBooks()
            }
            // Update shelves cache for badge counts
            self.shelves = try db.fetchAllShelves().filter { $0.kind != "favorites" }
            shelvesContentVersion += 1
        } catch {
            self.error = .unexpected(error)
        }
    }

    /// シェルフから本を一括除外する（FX2 の removeBooksFromShelf wrapper）。
    /// 手動シェルフ専用。お気に入りの場合は favorites cache も更新する。
    func removeBooksFromShelf(_ shelfID: Int64, books: [Int]) {
        guard let db = database, !books.isEmpty else { return }
        do {
            try db.removeBooksFromShelf(playlistID: shelfID, bookIDs: books)
            if shelfID == favoritesShelfID {
                reloadFavoritesCache()
            }
            // If currently viewing this shelf, refresh
            if case .shelf(let sid, _, _) = selectedSidebarItem, sid == shelfID {
                try refreshDisplayedBooks()
            }
            if case .favorites = selectedSidebarItem, shelfID == favoritesShelfID {
                try refreshDisplayedBooks()
            }
            self.shelves = try db.fetchAllShelves().filter { $0.kind != "favorites" }
            shelvesContentVersion += 1
        } catch {
            self.error = .unexpected(error)
        }
    }

    /// 手動シェルフ（user/imported、スマートでない）一覧。「シェルフに追加」メニュー用。
    /// drop 先（ConditionalDrop enabled: !isSmart）と同じ集合に揃える。
    /// Favorites は shelves ロード時点で既に除外済み。
    var manualShelves: [PlaylistRow] { shelves.filter { !$0.isSmart } }

    /// 選択中の本を指定手動シェルフに追加。
    func addSelectedBooksToShelf(_ shelfID: Int64) {
        let ids = Array(selectedBookIDs)
        guard !ids.isEmpty else { return }
        addBooksToShelf(shelfID, books: ids)
    }

    /// 手動シェルフ表示中なら、選択中の本をそのシェルフから外す。
    /// FX7 cleanup: removeSelectedBooksFromRemovableShelf に委譲（スーパーセット）。
    /// FX3 のコンテキストメニュー呼び出し元はそのまま使用可能。
    func removeSelectedBooksFromCurrentShelf() {
        removeSelectedBooksFromRemovableShelf()
    }

    /// 現在表示中の scope が「本を手動で出し入れできるシェルフ」なら、その shelfID。
    /// 手動シェルフ → その id、お気に入り → favoritesShelfID、それ以外（スマートシェルフ/ライブラリ/最近）→ nil。
    /// FX7: Delete キーの 3択ダイアログ判定に使う。
    var removableShelfID: Int64? {
        switch selectedSidebarItem {
        case .shelf(let id, _, _): return id
        case .favorites: return favoritesShelfID
        default: return nil   // .smartShelf / .library / .recent / nil
        }
    }

    /// 選択中の本を、現在 scope のシェルフ（手動 or お気に入り）から外す。
    /// FX7: 3択ダイアログの非破壊ブランチから呼ぶ。removableShelfID == nil なら no-op。
    func removeSelectedBooksFromRemovableShelf() {
        guard let shelfID = removableShelfID else { return }
        let ids = Array(selectedBookIDs)
        guard !ids.isEmpty else { return }
        removeBooksFromShelf(shelfID, books: ids)
    }

    /// removableShelf の表示名（ダイアログ第1ボタン文言用）。
    /// お気に入り→「お気に入りから外す」、手動シェルフ→「シェルフから外す」。
    var removableShelfRemoveButtonTitle: String {
        if case .favorites = selectedSidebarItem { return "お気に入りから外す" }
        return "シェルフから外す"
    }

    /// "最近の項目" の対象日数を更新する（FX2 A9-UI）。
    /// LibrarySettings.recentDays の didSet が永続化を担う。badge と、現在 "最近の項目"
    /// を表示中なら本リストも更新する。
    func setRecentDays(_ days: Int) {
        librarySettings?.recentDays = days
        reloadSidebarCounts()
        if case .recent = selectedSidebarItem {
            do { try refreshDisplayedBooks() }
            catch { self.error = .unexpected(error) }
        }
    }

    /// 選択中の全 favorites 状態（全部お気に入りなら true）。メニューのラベル/方向決定に使う。
    var allSelectedAreFavorites: Bool {
        !selectedBookIDs.isEmpty && selectedBookIDs.isSubset(of: favoritesBookIDs)
    }

    /// 選択中の本をすべてお気に入りに追加。
    func addSelectedBooksToFavorites() {
        guard let favID = favoritesShelfID else { return }
        let ids = Array(selectedBookIDs)
        guard !ids.isEmpty else { return }
        addBooksToShelf(favID, books: ids)
    }

    /// 選択中の本をすべてお気に入りから外す。
    func removeSelectedBooksFromFavorites() {
        guard let favID = favoritesShelfID else { return }
        let ids = Array(selectedBookIDs)
        guard !ids.isEmpty else { return }
        removeBooksFromShelf(favID, books: ids)
    }

    // MARK: - Bulk metadata operations

    func setRatingForSelected(_ rating: Int, undoManager: UndoManager? = nil) {
        let ids = Array(selectedBookIDs)
        guard !ids.isEmpty else { return }
        var patch = BookPatch()
        patch.rating = rating
        do {
            try applyPatch(bookIDs: ids, patch: patch, undoManager: undoManager)
            refreshSelectedBook()
        } catch {
            self.error = .unexpected(error)
        }
    }

    func setBookTypeForSelected(_ type: Int, undoManager: UndoManager? = nil) {
        let ids = Array(selectedBookIDs)
        guard !ids.isEmpty else { return }
        var patch = BookPatch()
        patch.bookType = type
        do {
            try applyPatch(bookIDs: ids, patch: patch, undoManager: undoManager)
            refreshSelectedBook()
        } catch {
            self.error = .unexpected(error)
        }
    }

    func toggleUnreadForSelected(undoManager: UndoManager? = nil) {
        let ids = Array(selectedBookIDs)
        guard !ids.isEmpty else { return }
        // Determine toggle direction from first selected book's current state
        let first = displayedBooks.first(where: { ids.contains($0.id) })
        let newValue = first.map { !$0.unseen } ?? true
        var patch = BookPatch()
        patch.unseen = newValue
        do {
            try applyPatch(bookIDs: ids, patch: patch, undoManager: undoManager)
            refreshSelectedBook()
        } catch {
            self.error = .unexpected(error)
        }
    }

    /// Marks a single book as read (sets unseen=false). Called automatically when
    /// the user opens a book via viewer (matches Stackroom behavior).
    func markAsRead(book: BookRow) {
        guard let db = database else { return }
        do {
            try db.markAsRead(bookID: book.id, at: Date())
            try refreshDisplayedBooks()
            refreshSelectedBook()
        } catch {
            self.error = .unexpected(error)
        }
    }

    /// 統一された「本を開く」入口。grid/list の double-click・Enter・コンテキストメニューから呼ぶ。
    /// useBuiltInViewer が true かつ先頭 book が内蔵表示可能なら内蔵ビューワを開く。
    /// それ以外（外部設定 / 動画 / 非対応 / 失敗）は従来の外部ビューワ起動にフォールバック。
    /// 複数選択時、内蔵ビューワは先頭 1 冊のみ開く（外部は各冊起動）。
    func openBooks(_ books: [BookRow], resumeDirect: Bool = false) {
        guard !books.isEmpty else { return }
        if viewerSettings.useBuiltInViewer, let first = books.first {
            openInBuiltInViewer(first, resumeDirect: resumeDirect)
            return
        }
        openInExternalViewer(books)
    }

    /// 単一 book を内蔵ビューワで開く。BookContent 化に失敗したら外部にフォールバック。
    private func openInBuiltInViewer(_ book: BookRow, resumeDirect: Bool = false) {
        // Phase 4.2c-2: 「最後に開いた本」を記録する（ローカル）。
        LastReadTracker.shared.record(.local(bundlePath: bundleURL.path, bookID: book.id, title: book.title))
        // D2/D3: TCC 保護フォルダ(~/Downloads 等)は libarchive の低レベル open で黙って拒否され、内蔵で
        // 開けないように見える。非サンドボックスでは narrow プロンプトが出ないため、読めない時は
        // NSOpenPanel で親フォルダを選ばせて powerbox 経由の narrow 許可を得てリトライする（FDA 不要）。
        if let probePath = book.path {
            let probeURL = URL(fileURLWithPath: probePath)
            switch Self.probeReadable(probeURL) {
            case .readable:
                break
            case .noPermission:
                // 存在するが TCC 等で読めない → 親フォルダの narrow 許可を求めてリトライ。
                guard Self.requestFolderAccessAndRecheck(for: probeURL, logger: Self.logger) else { return }
            case .notFound:
                // 移動/削除で不在 → 許可導線ではなく「見つかりません」を明示して中断（V5）。
                Self.presentFileNotFound(probeURL, logger: Self.logger)
                return
            }
        }
        // G15 V1: dedup 登録。既存窓があれば前面化して抜け、開き中なら無視して抜ける。
        let identity = ViewerIdentity.local(bundlePath: bundleURL.path, bookID: book.id)
        guard ViewerWindowRegistry.shared.beginOpen(identity) else { return }

        let content: BookContent
        do {
            content = try BookContentFactory.make(for: book)
        } catch {
            // Phase 2.6b-2 T-A: make 失敗時にログを残して外部にフォールバックする。
            let bookPath = book.path ?? "(nil)"
            Self.logger.warning("openInBuiltInViewer: BookContentFactory.make failed for bookID=\(book.id, privacy: .public) path=\(bookPath, privacy: .public): \(String(describing: error), privacy: .public) → falling back to external viewer")
            ViewerWindowRegistry.shared.cancelOpen(identity)
            openInExternalViewer([book])
            return
        }
        // Phase 2.6b-2 D3 / 4.1c: per-book page direction を解決。
        // Web リーダー（POST /direction）等で DB の page_direction が更新されている場合があるため、
        // インメモリの book ではなく DB から最新値を読む。失敗時はインメモリ値にフォールバック。
        let resolvedDir: PageDirection
        if let db = database {
            let fresh = try? db.fetchBook(id: book.id)
            resolvedDir = (fresh ?? book).pageDirection ?? viewerSettings.pageDirection
        } else {
            resolvedDir = book.pageDirection ?? viewerSettings.pageDirection
        }
        let options = ViewerOptions(pageDirection: resolvedDir, endOfBookBehavior: viewerSettings.endOfBookBehavior)
        Task { @MainActor in
            let pageCount: Int
            do {
                pageCount = try await content.pageCount
            } catch {
                // Phase 2.6b-2 T-A: pageCount throw 時にログを残して外部にフォールバックする。
                let bookPath = book.path ?? "(nil)"
                Self.logger.warning("openInBuiltInViewer: pageCount threw for bookID=\(book.id, privacy: .public) path=\(bookPath, privacy: .public): \(String(describing: error), privacy: .public) → falling back to external viewer")
                ViewerWindowRegistry.shared.cancelOpen(identity)
                openInExternalViewer([book])
                return
            }
            guard pageCount > 0 else {
                // Phase 2.6b-2 T-A: pageCount==0 時にログを残して外部にフォールバックする。
                let bookPath = book.path ?? "(nil)"
                Self.logger.warning("openInBuiltInViewer: pageCount==0 for bookID=\(book.id, privacy: .public) path=\(bookPath, privacy: .public) → falling back to external viewer")
                ViewerWindowRegistry.shared.cancelOpen(identity)
                openInExternalViewer([book])
                return
            }

            // 本ごと保存状態をロードして App 層の Resolved 型に変換
            let initialState = Self.resolvedState(for: book, database: self.database)

            let controller = ViewerWindowController(
                content: content,
                book: book,
                pageCount: pageCount,
                options: options,
                initialState: initialState,
                loadNextVolume: { [weak self] cur in
                    self?.resolveVolume(cur, direction: .next)
                },
                loadPrevVolume: { [weak self] cur in
                    self?.resolveVolume(cur, direction: .prev)
                },
                persistState: { [weak self] (b, lastPage, spread, cover) in
                    guard let self else { return }
                    LastReadTracker.shared.record(.local(bundlePath: self.bundleURL.path, bookID: b.id, title: b.title))
                    try? self.database?.saveViewerState(
                        bookID: b.id, spreadEnabled: spread, coverOffset: cover, lastPage: lastPage)
                },
                persistPageOverride: { [weak self] (b, page, mode) in
                    try? self?.database?.setPageOverride(bookID: b.id, page: page, mode: mode)
                },
                suppressResumeDialog: resumeDirect
            )
            // G16 C1 fix: onClose は controller 生成後に [weak controller] で設定する
            // （init 引数の時点では自身の identity をまだ束縛できないため controller を渡せない）。
            // unregister(controller:) は現在のキー（reidentify 後でも常に最新）を逆引きして
            // 除去するので、巻スワップ後に閉じても registry entry が residual リークしない。
            controller.onClose = { [weak controller] in
                guard let controller else { return }
                ViewerWindowRegistry.shared.unregister(controller: controller)
            }
            // Phase 2.6b-2 D3: per-book page direction の永続化コールバックを設定する。
            // DB 書き込み後に displayedBooks を更新する。これにより "r" トグル後にページ遷移なしで
            // ウィンドウを閉じた場合でも、次回オープン時に新しい方向が反映される（T1 バグ修正）。
            controller.onSetBookPageDirection = { [weak self] id, dir in
                try? self?.database?.updateBook(id: id, patch: BookPatch(pageDirection: dir))
                try? self?.refreshDisplayedBooks()
                self?.refreshSelectedBook()
            }
            // G16 C1: 巻送りでローカルの bookID が変わったら、registry の identity を追従させる
            // （bundle は不変なので bundlePath はそのまま・bookID のみ張り替え）。
            controller.onBookSwapped = { [weak self, weak controller] newBook in
                guard let self, let controller else { return }
                let newIdentity = ViewerIdentity.local(bundlePath: self.bundleURL.path, bookID: newBook.id)
                ViewerWindowRegistry.shared.reidentify(to: newIdentity, controller: controller)
            }
            ViewerWindowRegistry.shared.finishOpen(identity, controller: controller)
            controller.present()
            self.markAsRead(book: book)
        }
    }

    private enum VolumeDirection { case next, prev }

    /// 次/前の巻を解決して NextVolume を返す。content 化に失敗したら nil。
    private func resolveVolume(_ cur: BookRow, direction: VolumeDirection) -> NextVolume? {
        guard let db = database else { return nil }
        let sibling: BookRow?
        switch direction {
        case .next: sibling = try? db.nextVolumeInSeries(after: cur)
        case .prev: sibling = try? db.prevVolumeInSeries(before: cur)
        }
        guard let next = sibling,
              let content = try? BookContentFactory.make(for: next) else { return nil }
        // 巻送りで開く本も Stackroom 同様「閲覧開始」とみなし unseen=0 + play_date=now を更新する（D9）。
        // DB レベル更新に留め、背景ライブラリ window の displayedBooks/選択を巻送りごとに揺らさない。
        try? db.markAsRead(bookID: next.id, at: Date())
        let state = Self.resolvedState(for: next, database: db)
        return NextVolume(content: content, book: next, state: state)
    }

    /// 本ごとの保存状態を読み、raw mode int → PageLayoutOverride に変換した ResolvedViewerState を返す。
    /// Phase 2.6b-2 T5: 本ごとの見開き設定が未保存（book_viewer_state 行なし）の場合は
    /// ViewerSettings.shared.spreadByDefault をデフォルト値として使用する。
    /// 保存済み行がある場合はその spreadEnabled をそのまま使う（ユーザーの明示設定を尊重）。
    private static func resolvedState(for book: BookRow, database: Database?) -> ResolvedViewerState {
        guard let db = database, let stored = try? db.loadViewerState(bookID: book.id) else {
            // database が nil または throws: spreadByDefault をグローバルデフォルトとして使用。
            let defaultSpread = ViewerSettings.shared.spreadByDefault
            return ResolvedViewerState(spreadEnabled: defaultSpread, coverOffset: true, lastPage: 0, overrides: [:])
        }
        var overrides: [Int: PageLayoutOverride] = [:]
        for (page, mode) in stored.overrides {
            if let ov = PageLayoutOverride(rawValue: mode) { overrides[page] = ov }
        }
        // Phase 2.6b-2 T5: 行が存在しない（hasPersistedState == false）場合は
        // spreadByDefault をグローバルデフォルトとして使用する。
        // 行が存在する場合は保存済み spreadEnabled を使う（'d' キーで設定した per-book 値を尊重）。
        let spreadEnabled = stored.hasPersistedState ? stored.spreadEnabled : ViewerSettings.shared.spreadByDefault
        return ResolvedViewerState(
            spreadEnabled: spreadEnabled,
            coverOffset: stored.coverOffset,
            lastPage: stored.lastPage,
            overrides: overrides
        )
    }

    /// ファイルアクセスの3状態判定結果。
    /// - readable: 実アクセスできる（TCC 含む）
    /// - notFound: 不在（移動/削除・ENOENT）
    /// - noPermission: 存在するが読めない（TCC/権限拒否・EPERM/EACCES 等）
    enum ReadProbe: Equatable { case readable, notFound, noPermission }

    /// ファイルの実アクセスを試み、可読/不在/権限不足を判別する。1 バイト読んで close。
    /// 不在(ENOENT)と権限拒否(EPERM/EACCES)を errno で区別し、移動・削除された
    /// ファイルに対して誤って「フォルダ許可」導線を出さないためのもの（V5 修正）。
    static func probeReadable(_ url: URL) -> ReadProbe {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            // フォルダ型の本は path がディレクトリ。read() は EISDIR で失敗するので、
            // ディレクトリは「列挙できるか」で可読判定する（TCC で塞がれたディレクトリは
            // contentsOfDirectory が throw→権限不足として許可導線に乗る）。
            do { _ = try FileManager.default.contentsOfDirectory(atPath: url.path); return .readable }
            catch { return Self.isNoSuchFileError(error) ? .notFound : .noPermission }
        }
        do {
            let fh = try FileHandle(forReadingFrom: url)
            defer { try? fh.close() }
            _ = try fh.read(upToCount: 1)
            return .readable
        } catch {
            return Self.isNoSuchFileError(error) ? .notFound : .noPermission
        }
    }

    /// error が「ファイル不在(ENOENT / NSFileReadNoSuchFileError)」を表すか。
    /// TCC/権限拒否は EPERM/EACCES→NSFileReadNoPermissionError となり、ここでは false。
    private static func isNoSuchFileError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoSuchFileError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOENT) { return true }
        if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           u.domain == NSPOSIXErrorDomain, u.code == Int(ENOENT) { return true }
        return false
    }

    /// ファイルが読めるか（TCC 含む実アクセスで判定）。既存呼び出し互換のラッパ。
    static func fileIsReadable(_ url: URL) -> Bool { probeReadable(url) == .readable }

    /// 読めない時: 親フォルダを NSOpenPanel で選ばせて narrow 許可を得る→再チェック。
    /// 許可が取れて読めるようになったら true、キャンセル/失敗なら false（呼び出し側は開かず return）。
    @MainActor
    static func requestFolderAccessAndRecheck(for fileURL: URL, logger: Logger) -> Bool {
        logger.warning("openInBuiltInViewer: not readable, prompting for folder access: \(fileURL.path, privacy: .public)")
        let alert = NSAlert()
        alert.messageText = "本を開けませんでした"
        alert.informativeText = "このフォルダへのアクセス許可が必要です。「アクセスを許可…」を押して、この本があるフォルダを選択してください。"
        alert.addButton(withTitle: "アクセスを許可…")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = fileURL.deletingLastPathComponent()
        panel.message = "この本があるフォルダを選んでアクセスを許可してください。"
        panel.prompt = "許可"
        guard panel.runModal() == .OK else { return false }
        if fileIsReadable(fileURL) { return true }
        let e2 = NSAlert()
        e2.messageText = "本を開けませんでした"
        e2.informativeText = "選択したフォルダではこのファイルにアクセスできませんでした。ファイルのある親フォルダを選び直してください。"
        e2.runModal()
        return false
    }

    /// ファイル不在（移動/削除）を明示するアラート。許可導線は出さない（V5）。
    @MainActor
    static func presentFileNotFound(_ fileURL: URL, logger: Logger) {
        logger.warning("openInBuiltInViewer: file not found (moved/deleted): \(fileURL.path, privacy: .public)")
        let alert = NSAlert()
        alert.messageText = "ファイルが見つかりません"
        alert.informativeText = "この本のファイルが移動または削除された可能性があります。ファイルを元の場所に戻すか、「再リンク」してください。"
        alert.runModal()
    }

    /// 選択 books を外部ビューワで起動（従来挙動）。
    private func openInExternalViewer(_ books: [BookRow]) {
        // Phase 4.2c-2: 「最後に開いた本」を記録する（外部ビューワ経路は先頭の本を採用）。
        if let book = books.first {
            LastReadTracker.shared.record(.local(bundlePath: bundleURL.path, bookID: book.id, title: book.title))
        }
        for book in books {
            if let err = HelperLauncher.open(book: book, settings: viewerSettings) {
                self.error = err
                break
            }
            markAsRead(book: book)
        }
    }

    func selectAllInCurrentView() {
        selectedBookIDs = Set(displayedBooks.map(\.id))
    }

    /// Refresh selectedBook + displayedSelectedBooks to point at fresh BookRow
    /// values from displayedBooks. Used after bulk metadata mutations so the
    /// detail pane shows current values without requiring re-selection.
    private func refreshSelectedBook() {
        if let oldID = selectedBook?.id,
           let fresh = displayedBooks.first(where: { $0.id == oldID }) {
            selectedBook = fresh
        }
        refreshDisplayedSelectedBooks()
    }

    /// Re-derive displayedSelectedBooks from displayedBooks ∩ selectedBookIDs.
    /// Call after displayedBooks updates so the detail pane sees fresh values.
    private func refreshDisplayedSelectedBooks() {
        displayedSelectedBooks = displayedBooks.filter { selectedBookIDs.contains($0.id) }
    }

    /// Re-sort displayedBooks into sortedDisplayedBooks. Call after
    /// displayedBooks, listViewSort, or sortMode changes.
    func refreshSortedDisplayedBooks() {
        let start = ContinuousClock().now
        let n = displayedBooks.count
        Self.sortLogger.info("[sort] start n=\(n)")
        let mode = librarySettings?.sortMode ?? .column
        switch mode {
        case .seriesVolumeAsc:
            sortedDisplayedBooks = displayedBooks.sortedBySeriesAndVolume()
        case .seriesVolumeDesc:
            sortedDisplayedBooks = displayedBooks.sortedBySeriesAndVolume().reversed()
        case .column:
            let sort = librarySettings?.listViewSort ?? ColumnSort(column: .dateAdded, ascending: false)
            sortedDisplayedBooks = displayedBooks.sortedByColumn(sort)
        }
        sortedDisplayedBooksVersion &+= 1
        let elapsed = start.duration(to: .now)
        Self.sortLogger.info("[sort] done n=\(n) elapsed=\(elapsed.description)")
    }

    /// Reloads the favorites cache from DB. Call after favorites table mutations.
    func reloadFavoritesCache() {
        guard let db = database, let favID = favoritesShelfID else {
            favoritesBookIDs = []
            return
        }
        do {
            favoritesBookIDs = Set(try db.fetchBooksInPlaylist(playlistID: favID).map { $0.id })
        } catch {
            self.error = .unexpected(error)
        }
    }

    // MARK: - v0.5a — Detail pane editing

    /// Returns the common value of a field across `displayedSelectedBooks`.
    /// `.unanimous(value)` if all match, `.mixed` if values differ or selection is empty.
    func mixedValue<T: Equatable & Sendable>(_ keyPath: KeyPath<BookRow, T>) -> MixedValueState<T> {
        MixedValueState.from(displayedSelectedBooks.map { $0[keyPath: keyPath] })
    }

    /// Apply patch to a single book via UndoableCommand (Undo supported).
    /// Title empty validation is enforced by Database.updateBook inside the command.
    func applyPatch(bookID: Int, patch: BookPatch, undoManager: UndoManager? = nil) {
        guard let db = database else { return }
        do {
            let cmd = try PatchBooksCommand.prepare(patches: [(bookID: bookID, patch: patch)], database: db)
            try perform(cmd, undoManager: undoManager)
            refreshSelectedBook()
            if let uuid = librarySettings?.libraryUUID {
                ServerController.shared.publishLiveEvent(.bookChanged(library: uuid, bookID: bookID))
            }
        } catch BookPatchError.emptyTitle {
            self.error = .titleRequired
        } catch {
            self.error = .unexpected(error)
        }
    }

    /// Apply patch to all selected books via UndoableCommand (Undo supported).
    /// Title in patch is ignored (multi-select doesn't edit title).
    func applyPatchToSelected(_ patch: BookPatch, undoManager: UndoManager? = nil) {
        var p = patch
        p.title = nil  // safety: never multi-edit title
        guard !p.isEmpty else { return }
        let ids = Array(selectedBookIDs)
        guard !ids.isEmpty else { return }
        do {
            try applyPatch(bookIDs: ids, patch: p, undoManager: undoManager)
            refreshSelectedBook()
        } catch {
            self.error = .unexpected(error)
        }
    }

    // MARK: - Phase 2.5c Task 15: Undo-aware edit / delete helpers

    /// Apply a patch to one or more books via PatchBooksCommand (Undo supported).
    /// Single-select: bookIDs = [id]. Multi-select: bookIDs = many ids.
    /// Title in patch is silently ignored when bookIDs.count > 1 (safety).
    @discardableResult
    func applyPatch(
        bookIDs: [Int],
        patch: BookPatch,
        undoManager: UndoManager?
    ) throws -> Int {
        guard !bookIDs.isEmpty else { return 0 }
        var p = patch
        if bookIDs.count > 1 { p.title = nil }
        guard !p.isEmpty, let db = database else { return 0 }
        let patches: [(bookID: Int, patch: BookPatch)] = bookIDs.map { ($0, p) }
        let cmd = try PatchBooksCommand.prepare(patches: patches, database: db)
        try perform(cmd, undoManager: undoManager)
        if let uuid = librarySettings?.libraryUUID {
            for id in bookIDs {
                ServerController.shared.publishLiveEvent(.bookChanged(library: uuid, bookID: id))
            }
        }
        return bookIDs.count
    }

    /// Delete books from library (DB-only) via DeleteBooksCommand (Undo supported).
    /// Thumbnail cleanup is handled by callers after this returns.
    @discardableResult
    func deleteBooksFromLibrary(
        bookIDs: [Int],
        undoManager: UndoManager?
    ) throws -> Int {
        guard !bookIDs.isEmpty, let db = database else { return 0 }
        let cmd = try DeleteBooksCommand.prepare(bookIDs: bookIDs, database: db)
        try perform(cmd, undoManager: undoManager)
        if let uuid = librarySettings?.libraryUUID {
            ServerController.shared.publishLiveEvent(.structureChanged(library: uuid))
        }
        return bookIDs.count
    }

    /// スタンプ pane の「値 chip クリック」を Undo 可能に処理する。
    /// 各 book の現在値を読み取り、MultiValueParser.append した結果を BookPatch で適用する。
    /// これにより ⌘Z でスタンプ適用前の状態に戻せる。
    func applyStampValue(
        _ value: String,
        patchKeyPath: WritableKeyPath<BookPatch, String?>,
        bookIDs: [Int],
        database: Database,
        currentValues: [Int: String?],
        undoManager: UndoManager?
    ) throws {
        guard !bookIDs.isEmpty else { return }
        var perBookPatches: [(bookID: Int, patch: BookPatch)] = []
        for id in bookIDs {
            let current: String? = currentValues[id] ?? nil
            let (appended, _) = MultiValueParser.append(to: current, value: value)
            var patch = BookPatch()
            patch[keyPath: patchKeyPath] = appended
            perBookPatches.append((bookID: id, patch: patch))
        }
        guard !perBookPatches.isEmpty else { return }
        let cmd = try PatchBooksCommand.prepare(patches: perBookPatches, database: database)
        try perform(cmd, undoManager: undoManager)
        if let uuid = librarySettings?.libraryUUID {
            for id in bookIDs {
                ServerController.shared.publishLiveEvent(.bookChanged(library: uuid, bookID: id))
            }
        }
    }

    /// スタンプ pane の「消去 chip クリック」を Undo 可能に処理する。
    /// BookPatch で当該フィールドを空文字列に設定 (COALESCE pattern で NULL 相当)。
    func clearStampValue(
        patchKeyPath: WritableKeyPath<BookPatch, String?>,
        bookIDs: [Int],
        undoManager: UndoManager?
    ) throws {
        guard !bookIDs.isEmpty else { return }
        var patch = BookPatch()
        patch[keyPath: patchKeyPath] = ""
        try applyPatch(bookIDs: bookIDs, patch: patch, undoManager: undoManager)
    }

    // MARK: - 4.2c-6a: StampColumnView 汎用化に伴う高レベル スタンプ操作

    /// StampField → BookPatch の対応する String? WritableKeyPath。
    private func stampPatchKeyPath(_ field: StampField) -> WritableKeyPath<BookPatch, String?> {
        switch field {
        case .genre:    return \BookPatch.genre
        case .neta:     return \BookPatch.neta
        case .keywordA: return \BookPatch.keywordA
        case .keywordB: return \BookPatch.keywordB
        case .keywordC: return \BookPatch.keywordC
        }
    }

    /// 選択本へスタンプ値を append 適用（undo スナップショット込み）。
    func applyStamp(field: StampField, value: String) {
        guard let db = database else { return }
        let ids = Array(selectedBookIDs)
        guard !ids.isEmpty else { return }
        var currentValues: [Int: String?] = [:]
        for id in ids {
            if let row = displayedBooks.first(where: { $0.id == id }) {
                switch field {
                case .genre:    currentValues[id] = row.genre
                case .neta:     currentValues[id] = row.neta
                case .keywordA: currentValues[id] = row.keywordA
                case .keywordB: currentValues[id] = row.keywordB
                case .keywordC: currentValues[id] = row.keywordC
                }
            }
        }
        do {
            try applyStampValue(value, patchKeyPath: stampPatchKeyPath(field), bookIDs: ids,
                                database: db, currentValues: currentValues, undoManager: nil)
        } catch {
            self.error = .unexpected(error)
        }
    }

    /// 選択本の当該スタンプフィールドを消去。
    func clearStamp(field: StampField) {
        let ids = Array(selectedBookIDs)
        guard !ids.isEmpty else { return }
        do {
            try clearStampValue(patchKeyPath: stampPatchKeyPath(field), bookIDs: ids, undoManager: nil)
        } catch {
            self.error = .unexpected(error)
        }
    }

    /// スタンプ定義（チップ候補値）を追加（重複 skip）。選択があれば併せて適用（既存挙動）。
    func addStampDefinition(field: StampField, value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let settings = librarySettings {
            var defs = settings.stampDefinitions
            var fieldDefs = defs[field.dbColumn] ?? []
            if !fieldDefs.contains(trimmed) {
                fieldDefs.append(trimmed)
                defs[field.dbColumn] = fieldDefs
                settings.stampDefinitions = defs
                if let uuid = settings.libraryUUID {
                    ServerController.shared.publishLiveEvent(.settingsChanged(library: uuid))
                }
            }
        }
        if !selectedBookIDs.isEmpty { applyStamp(field: field, value: trimmed) }
    }

    /// 4.2c-6a: スタンプ定義を削除する。ショートカット定義のみ除去し、既に本に付与済みの値は変更しない。
    func deleteStampDefinition(field: StampField, value: String) {
        guard let settings = librarySettings else { return }
        var defs = settings.stampDefinitions
        if var fieldDefs = defs[field.dbColumn], let i = fieldDefs.firstIndex(of: value) {
            fieldDefs.remove(at: i)
            defs[field.dbColumn] = fieldDefs
            settings.stampDefinitions = defs
            if let uuid = settings.libraryUUID {
                ServerController.shared.publishLiveEvent(.settingsChanged(library: uuid))
            }
        }
    }

    // MARK: - Phase 2.5c spec a: UndoableCommand integration

    /// Executes an UndoableCommand and registers undo/redo handlers with the given UndoManager.
    /// If undoManager is nil, the command is executed without undo support.
    ///
    /// Forward 経路: caller (例: setCoverImageName) は呼び出し前に file regenerate + cache
    /// purge を await 済なので、ここでは DB を進めて view を refresh するだけで良い。
    /// Undo / Redo 経路は NSUndoManager の closure 内から `undoPerformAsync` / `redoPerformAsync`
    /// を Task wrap で起動する。これにより DB 更新前に file regenerate + cache purge を await
    /// できるので、view re-render 時に cache miss が保証され、Detail Pane / grid とも 1 回の
    /// re-render で正しい thumbnail が表示される (SwiftUI view tree への追加 trigger 不要)。
    func perform(_ command: UndoableCommand, undoManager: UndoManager?) throws {
        guard let db = database else { return }
        try command.perform(database: db)
        try refreshDisplayedBooks()
        refreshSelectedBook()
        // 引数の undoManager (= SwiftUI @Environment 由来) は無視。常に AppState 所有の
        // self.undoManager に register する。Edit menu の ⌘Z はこの instance に bind 済。
        // 互換のため引数自体は残す (caller を一括変更しないで済むように)。
        registerUndoableHandler(for: command)
        undoStateVersion += 1  // SwiftUI に stack state 変化を通知
        _ = undoManager  // 引数受け取りつつ未使用 (互換シグネチャ維持)
    }

    /// NSUndoManager の `isUndoing` / `isRedoing` flag は closure 実行中だけ true で、
    /// その間に同 undoManager に対して `registerUndo` を呼ぶと「逆方向 (redo / undo) 用 handler」
    /// として正しく stack に積まれる。Task wrap で flag が消えてから register すると
    /// 「新規 forward 操作」として undo stack に push されてしまい、結果として ⌘Z が
    /// 「undo → 新規 undo (実は redo) → undo …」を繰り返す cycle に陥る (2026-05-24 観測)。
    ///
    /// 構造的対策: registerUndo の closure 内で **sync に同じ helper を再帰 register**
    /// (= flag が true な間に register が完了する)。actual な DB undo/redo + file regenerate
    /// は別 Task で async に流す。direction は closure 内 sync で capture して Task に渡す。
    private func registerUndoableHandler(for command: UndoableCommand) {
        let um = self.undoManager
        um.registerUndo(withTarget: self) { [weak self] _ in
            guard let self else { return }
            // direction を sync capture (Task 実行時には flag は既に消えている)
            let direction: UndoDirection = um.isUndoing ? .undo : (um.isRedoing ? .redo : .undo)
            Self.coverLogger.info("registerUndoable closure FIRED, direction=\(direction.rawValue, privacy: .public), action=\(command.actionName, privacy: .public)")
            // 逆方向の handler を sync re-register。NSUndoManager の flag を尊重した stack 操作。
            self.registerUndoableHandler(for: command)
            // actual work を Task で async (DB I/O + file regenerate を await できる)
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    switch direction {
                    case .undo:
                        try await self.applyUndoSide(command)
                    case .redo:
                        try await self.applyRedoSide(command)
                    }
                    self.undoStateVersion += 1
                } catch {
                    Self.coverLogger.error("apply\(direction.rawValue, privacy: .public)Side threw \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        um.setActionName(command.actionName)
    }

    private enum UndoDirection: String { case undo, redo }

    /// Undo path: cover 変更を含む PatchBooksCommand なら、DB undo の **前** に
    /// 元の cover に対応する file regenerate + cache purge を await する。
    /// その後 DB undo → refresh で view re-render → BookCell / CoverImageView の
    /// `.task(id:)` が cache miss (purge 済) → disk から元 file 読込 → 元 image 表示。
    /// register は呼び出し元 (registerUndoableHandler) が closure 内 sync で実施済。
    private func applyUndoSide(_ command: UndoableCommand) async throws {
        guard let db = database else { return }

        if let patchCmd = command as? PatchBooksCommand {
            await prepareCoverFiles(forPatches: patchCmd.previousValues.map { ($0.key, $0.value) },
                                    direction: "undo")
        }

        try command.undo(database: db)
        Self.coverLogger.info("applyUndoSide: command.undo done, action=\(command.actionName, privacy: .public)")
        try refreshDisplayedBooks()
        refreshSelectedBook()

        // DeleteBooksCommand の Undo 時: 削除されたサムネイルを再生成する。
        // Thumbnail cleanup は Undo 対象外のため、restoreBook 後にファイルが存在しない。
        if let deleteCmd = command as? DeleteBooksCommand {
            let restoredIDs = Set(deleteCmd.bookIDs)
            let booksToRegenerate = displayedBooks.filter { restoredIDs.contains($0.id) }
            for book in booksToRegenerate {
                Task { await self.regenerateThumbnail(for: book) }
            }
        }
    }

    /// Redo path: cover 変更を含む PatchBooksCommand なら、DB redo の **前** に
    /// forward 後の cover に対応する file regenerate + cache purge を await する。
    /// register は呼び出し元 (registerUndoableHandler) が closure 内 sync で実施済。
    private func applyRedoSide(_ command: UndoableCommand) async throws {
        guard let db = database else { return }

        if let patchCmd = command as? PatchBooksCommand {
            let entries: [(Int, BookPatch)] = patchCmd.patches.map { ($0.bookID, $0.patch) }
            await prepareCoverFiles(forPatches: entries, direction: "redo")
        }

        try command.perform(database: db)
        Self.coverLogger.info("applyRedoSide: command.perform done, action=\(command.actionName, privacy: .public)")
        try refreshDisplayedBooks()
        refreshSelectedBook()
    }

    /// undo / redo の DB 更新前に呼ばれる helper。各 patch が cover を変更するなら、
    /// 該当方向の cover 値で thumbnail.jpg を書き直し、cache を purge する。
    /// patch.coverImageName が nil かつ clearCoverImageName == false なら no-op。
    private func prepareCoverFiles(
        forPatches entries: [(Int, BookPatch)],
        direction: String
    ) async {
        let thumbDir = bundleURL.appending(path: "Thumbnails")
        for (id, patch) in entries {
            guard patch.coverImageName != nil || patch.clearCoverImageName else { continue }
            let preferredName: String? = patch.clearCoverImageName ? nil : patch.coverImageName
            if patch.coverImageName == CoverSource.externalSentinel { continue }   // 外部表紙は自前で thumbnail を書く
            guard let book = displayedBooks.first(where: { $0.id == id }),
                  let path = book.path else { continue }
            let sourceURL = URL(fileURLWithPath: path)
            guard let extractor = ArchiveAdapter.coverExtractor(for: sourceURL) else { continue }
            do {
                try await CoverRefresher.regenerate(
                    bookID: id,
                    sourceURL: sourceURL,
                    preferredName: preferredName,
                    thumbnailsDirURL: thumbDir,
                    extractor: extractor
                )
                Self.coverLogger.info("prepareCoverFiles: \(direction, privacy: .public) file written, bookID=\(id, privacy: .public)")
            } catch {
                Self.coverLogger.error("prepareCoverFiles: \(direction, privacy: .public) file write failed bookID=\(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            await thumbnailLoader?.purge(bookID: id)
            Self.coverLogger.info("prepareCoverFiles: \(direction, privacy: .public) cache purged, bookID=\(id, privacy: .public)")
        }
    }

    // MARK: - Phase 2.5c spec b Task 8: cover_image_name setter

    /// 単一 book の cover_image_name を設定 (Undo 対応 + 即時反映)。
    /// **重要な順序**: file write → cache purge → DB 更新の順で、
    /// view 再 render trigger 時に disk + cache 共に新 state を保証する。
    /// name == nil → clearCoverImageName: true (自動に戻す)
    /// name != nil → coverImageName: name (手動指定)
    @MainActor
    func setCoverImageName(
        _ name: String?,
        for bookID: Int,
        undoManager: UndoManager?
    ) async throws {
        guard let book = displayedBooks.first(where: { $0.id == bookID }) else { return }
        guard let path = book.path else { return }

        let umStatus: String = (undoManager == nil) ? "nil" : "set"
        Self.coverLogger.info("setCoverImageName: bookID=\(bookID, privacy: .public), name=\(name ?? "nil", privacy: .public), undoManager=\(umStatus, privacy: .public)")

        // === Step 1: file write を await (DB 更新 / view 再 render の前) ===
        let sourceURL = URL(fileURLWithPath: path)
        if let extractor = ArchiveAdapter.coverExtractor(for: sourceURL) {
            let thumbDir = bundleURL.appending(path: "Thumbnails")
            do {
                try await CoverRefresher.regenerate(
                    bookID: bookID,
                    sourceURL: sourceURL,
                    preferredName: name,
                    thumbnailsDirURL: thumbDir,
                    extractor: extractor
                )
                Self.coverLogger.info("setCoverImageName: file written (pre-DB), bookID=\(bookID, privacy: .public)")
            } catch {
                Self.coverLogger.error("setCoverImageName: file write failed: \(error.localizedDescription)")
                // file write 失敗しても DB 更新は続行 (UI が古い image のままで残る、許容)
            }
        }

        // === Step 2: cache purge (DB 更新の前) ===
        await thumbnailLoader?.purge(bookID: bookID)
        Self.coverLogger.info("setCoverImageName: cache purged (pre-DB), bookID=\(bookID, privacy: .public)")

        // === Step 3: DB 更新 + Undo 登録 (view 再 render trigger) ===
        let patch: BookPatch = (name == nil)
            ? BookPatch(clearCoverImageName: true)
            : BookPatch(coverImageName: name)
        try applyPatch(bookIDs: [bookID], patch: patch, undoManager: undoManager)
        Self.coverLogger.info("setCoverImageName: applyPatch done, bookID=\(bookID, privacy: .public)")
    }

    // MARK: - Phase G4a: 外部画像を表紙に

    /// 外部画像を表紙に設定する（thumbnail.jpg を外部画像へ置換＋coverImageName="@external"＋crop・Undo 対応）。
    /// **重要な順序**: file write → cache purge → DB 更新(Undo) → crop 書込 の順。
    /// prepareCoverFiles は @external を skip するので、initial apply / redo で外部 thumbnail は保持される。
    /// crop は BookPatch に持たないため、既存 crop 経路（updateBookCoverCropRect・JSON or NULL）で別途書く。
    @MainActor
    func setExternalCover(bookID: Int, imageData: Data, cropRect: CGRect?, undoManager: UndoManager?) async throws {
        guard displayedBooks.contains(where: { $0.id == bookID }) else { return }
        let umStatus: String = (undoManager == nil) ? "nil" : "set"
        Self.coverLogger.info("setExternalCover: bookID=\(bookID, privacy: .public), crop=\(cropRect == nil ? "nil" : "set", privacy: .public), undoManager=\(umStatus, privacy: .public)")
        let thumbDir = bundleURL.appending(path: "Thumbnails")
        // Step 1: file write（DB 更新前）
        do {
            try CoverRefresher.regenerateFromImageData(bookID: bookID, imageData: imageData, thumbnailsDirURL: thumbDir)
            Self.coverLogger.info("setExternalCover: thumbnail written (pre-DB), bookID=\(bookID, privacy: .public)")
        } catch {
            Self.coverLogger.error("setExternalCover: thumbnail write failed bookID=\(bookID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
        // Step 2: cache purge（DB 更新前）
        await thumbnailLoader?.purge(bookID: bookID)
        // Step 3: DB 更新＋Undo（coverImageName=@external）。prepareCoverFiles は @external を skip。
        let patch = BookPatch(coverImageName: CoverSource.externalSentinel)
        _ = try applyPatch(bookIDs: [bookID], patch: patch, undoManager: undoManager)
        // Step 4: crop 書込（既存 crop 経路。nil=クロップ解除で NULL）。失敗はログ（表紙自体は確定済み）。
        let cropJSON = cropRect.map(BookRow.encodeCoverCropRect)
        do {
            try database?.updateBookCoverCropRect(id: bookID, json: cropJSON)
        } catch {
            Self.coverLogger.error("setExternalCover: crop write failed bookID=\(bookID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        try? refreshDisplayedBooks()
        Self.coverLogger.info("setExternalCover: applyPatch+crop done, bookID=\(bookID, privacy: .public)")
    }

    // MARK: - Phase 2.5c spec b Task 6: Thumbnail 再生成 helper

    /// 指定 book の thumbnail を cover_image_name に基づいて再生成。
    /// thumbnail loader cache を purge して UI に再表示を促す。
    /// エラーは log only — UI へのアラートは出さない (Task 8 で background refresh として利用)。
    func regenerateThumbnail(for book: BookRow) async {
        Self.coverLogger.info("regenerateThumbnail: bookID=\(book.id), coverImageName=\(book.coverImageName ?? "nil")")
        let thumbDir = bundleURL.appending(path: "Thumbnails")
        // 外部表紙（@external）: 既存の外部サムネが**存在するとき**だけ保護スキップ。
        // 不在（delete→Undo でサムネごと消える等・外部バイトは復旧不能）なら自動表紙へフォールバックさせ、
        // 恒久的な空白表紙を防ぐ。フォールバック時は preferredName=nil（先頭ページ）で archive 経路へ。
        var preferredName = book.coverImageName
        if CoverSource.isExternal(book.coverImageName) {
            let extThumb = thumbDir.appendingPathComponent("\(book.id)/thumbnail.jpg")
            if FileManager.default.fileExists(atPath: extThumb.path) {
                Self.coverLogger.info("regenerateThumbnail: skip external (thumbnail present) bookID=\(book.id, privacy: .public)")
                return
            }
            Self.coverLogger.warning("regenerateThumbnail: external thumbnail missing → fallback to auto, bookID=\(book.id, privacy: .public)")
            preferredName = nil
        }
        guard let path = book.path else { return }
        let sourceURL = URL(fileURLWithPath: path)
        guard let extractor = ArchiveAdapter.coverExtractor(for: sourceURL) else {
            Self.logger.warning("regenerateThumbnail: unsupported format for book \(book.id) path=\(path)")
            return
        }
        do {
            try await CoverRefresher.regenerate(
                bookID: book.id,
                sourceURL: sourceURL,
                preferredName: preferredName,
                thumbnailsDirURL: thumbDir,
                extractor: extractor
            )
            Self.coverLogger.info("regenerateThumbnail: file written, bookID=\(book.id)")
            // 🔧 Fix A: per-book purge instead of full-cache purge (cheaper + avoids CGImageSource URL cache).
            await thumbnailLoader?.purge(bookID: book.id)
            Self.coverLogger.info("regenerateThumbnail: cache purged (per-book), bookID=\(book.id)")
            try? refreshDisplayedBooks()
            Self.coverLogger.info("regenerateThumbnail: refresh done, bookID=\(book.id)")
        } catch {
            Self.logger.error("regenerateThumbnail failed for book \(book.id): \(error.localizedDescription)")
        }
    }

    // MARK: - Phase 2.5c Task 14: 遡及 parser 適用

    /// 全 books に対し FilenameParser を実行し、series/volume の空欄を埋める。
    /// 1 PatchBooksCommand にまとめて Undo 可能にする。
    /// 戻り値: 更新された book 件数 (0 なら何もしなかった)
    @discardableResult
    func recomputeMetadataFromFilenames(undoManager: UndoManager?) throws -> Int {
        guard let db = database else { return 0 }
        let patches = try MetadataCompletion.missingSeriesVolumePatches(in: db)
        guard !patches.isEmpty else { return 0 }
        let cmd = try PatchBooksCommand.prepare(patches: patches, database: db)
        try perform(cmd, undoManager: undoManager)
        return patches.count
    }

    // MARK: - Phase 4.2d-1: 監視フォルダ自動取込

    /// 監視フォルダウォッチャーを（再）構成する。設定変更時にも呼ぶ。
    func reloadFolderWatcher() {
        guard let db = database, let settings = librarySettings else {
            folderWatcher?.stop()
            folderWatcher = nil
            return
        }
        if folderWatcher == nil {
            folderWatcher = FolderWatcher(database: db, bundleURL: bundleURL, settings: settings) { [weak self] result in
                self?.presentWatchSummary(result)
            }
        }
        folderWatcher?.reload()
    }

    func scanWatchedFoldersNow() { folderWatcher?.scanNow() }

    /// 初回プレビューで「取り込む」を押した既存候補を即時取り込む。
    /// FolderWatcher のサイズ安定化デバウンス（2 スキャン必要）を待たず、ユーザー確定済みの
    /// 完結ファイルを直ちに登録する（クリック→即反映の UX）。
    func importWatchedCandidatesNow(_ urls: [URL], presetID: String?) {
        guard !urls.isEmpty, let db = database, let settings = librarySettings else { return }
        let raw = settings.resolvedFilenameFormatRaw(forPresetID: presetID)
        let format = (try? FilenameFormat(raw: raw)) ?? (try! FilenameFormat(raw: "@title"))
        Task { @MainActor in
            let importer = BookImporter(database: db, bundleURL: bundleURL, format: format)
            let result = await importer.add(
                urls: urls,
                autoClassifyEnabled: ImportDefaults.effectiveAutoClassify(db: db),
                thickThreshold: ImportDefaults.effectiveThickThreshold(db: db))
            presentWatchSummary(result)
        }
    }

    private func presentWatchSummary(_ result: BookImporter.ImportResult) {
        try? refreshDisplayedBooks()
        if !result.addedIDs.isEmpty, let uuid = librarySettings?.libraryUUID {
            ServerController.shared.publishLiveEvent(.structureChanged(library: uuid))
        }
        var parts: [String] = []
        if !result.addedIDs.isEmpty { parts.append("\(result.addedIDs.count) 件を自動追加") }
        if !result.failed.isEmpty { parts.append("\(result.failed.count) 件失敗") }
        if !result.coverFailures.isEmpty { parts.append("表紙なし \(result.coverFailures.count) 件") }
        guard !parts.isEmpty else { return }
        watchImportSummary = parts.joined(separator: " / ")
        watchSummaryClearTask?.cancel()
        watchSummaryClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.watchImportSummary = nil
        }
    }

    // MARK: - Phase 4.1c: external book change handler

    /// サーバ（Web リーダー/将来のクライアント）からの本変更通知を受け、DB から最新を再取得して
    /// 詳細ペイン・grid/list へ即時反映する。並び順に影響しない変更（例: title ソート中の読書）では
    /// 全再ソートを避け、該当行のみ in-place 更新する（4.2a・高頻度 progress 対策）。
    func handleExternalBookChange(bookID: Int) {
        guard let db = database else { return }
        guard let fresh = try? db.fetchBook(id: bookID) else { return }
        let idx = displayedBooks.firstIndex(where: { $0.id == bookID })
        let oldBook = idx.map { displayedBooks[$0] }
        if let idx { displayedBooks[idx] = fresh }
        if selectedBook?.id == bookID { selectedBook = fresh }
        refreshDisplayedSelectedBooks()   // 詳細ペイン（displayedSelectedBooks）は常に即時更新

        let mode = librarySettings?.sortMode ?? .column
        let colSort = librarySettings?.listViewSort ?? ColumnSort(column: .dateAdded, ascending: false)
        let needsResort = oldBook.map {
            sortOrderAffected(old: $0, new: fresh, sortMode: mode, columnSort: colSort)
        } ?? false
        if needsResort {
            refreshSortedDisplayedBooks()
        } else if let sidx = sortedDisplayedBooks.firstIndex(where: { $0.id == bookID }) {
            // 並び順は不変。該当行の内容（未読●・最終閲覧日列等）だけ差し替えて version を bump。
            sortedDisplayedBooks[sidx] = fresh
            sortedDisplayedBooksVersion &+= 1
        }

        // G4c: リモート由来の変更で表紙が差し替わっている可能性があるため、当該本のサムネイル
        // メモリキャッシュを捨てた後に当該本の coverVersionByBook を bump してローカル表紙ビューを
        // 再取得させる（per-book: 高頻度イベントで可視グリッド全体をフリッカさせないため）。
        // onBookChanged は変更種別を持たないため一律実行（cover 再取得は thumbnail.jpg から安価）。
        // purge 完了 → bump の順にして、再取得が新しい thumbnail を読むようにする。
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.thumbnailLoader?.purge(bookID: bookID)
            self.coverVersionByBook[bookID, default: 0] &+= 1
        }
    }
}

// MARK: - Phase 2.5c spec b Task 10: chip jump helper

extension AppState {
    /// Detail Pane chip の右矢印クリック時のジャンプ処理。
    /// BrowseField に対応する DetailField なら Browser pane filter で当該フィールドの
    /// selected set を {value} に上書き（他フィールドの filter は維持）。
    /// 対応しない DetailField (title / volume / memo) なら searchQuery に value をセット。
    @MainActor
    func jumpToFilterOrSearch(field: DetailField, value: String) {
        if let browseField = BrowserPaneState.BrowseField(from: field) {
            // FilterState は struct (値型) なので一度コピーして mutate → 書き戻す
            var fs = librarySettings?.filterState ?? FilterState()
            fs.replaceSelection(for: browseField.rawValue, with: [value])
            librarySettings?.filterState = fs
            try? refreshDisplayedBooks()
        } else {
            // 検索欄 fallback (searchQuery の didSet が refreshDisplayedBooks を呼ぶ)
            searchQuery = value
        }
    }
}

private final class AppStateProgressReporter: ProgressReporter, @unchecked Sendable {
    let onProgress: (Int, Int) -> Void
    init(onProgress: @escaping (Int, Int) -> Void) { self.onProgress = onProgress }
    func reportProgress(processed: Int, total: Int) { onProgress(processed, total) }
}
