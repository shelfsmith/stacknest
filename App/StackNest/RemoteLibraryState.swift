// SPDX-License-Identifier: MIT
import AppCore
import AppKit
import Foundation
import LibraryServerAPI
import LibraryStore
import Observation
import RemoteClient
import os

/// Phase 4.2b-1: リモートライブラリ 1 個分の閲覧状態。
/// ローカルの AppState に相当する軽量モデル（書き込みはせず読み取り+進捗 POST のみ）。
@Observable
@MainActor
final class RemoteLibraryState {
    private static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "RemoteLibrary")

    let client: RemoteLibraryClient
    let serverID: UUID
    let libraryUUID: String
    var libraryName: String
    var locked: Bool
    var libraryToken: String?

    /// Phase 4.2b-2 Task 4: オフライン保存ストア（既定の Application Support ベース）。
    private let offlineStore = OfflineStore()

    /// オフライン DL/削除のたびに &+=1 する観測カウンタ。
    /// OfflineStore はディスクから読むため SwiftUI が直接観測できない。
    /// ビュー body で参照させ、ダウンロード済みバッジを再評価させるためのトリガ。
    var downloadedVersion = 0

    /// Phase 4.2b-1b-1 Task 3: 表示モード + per のグローバル設定（UserDefaults 永続）。
    private let prefs = RemoteBrowsePreferences()

    /// books が更新されるたびに増えるカウンタ。表コーディネータが reloadData の要否判定に使う
    /// （ソートのみの並べ替えで件数・先頭が一致しても確実に再描画）。
    private(set) var booksVersion = 0
    var books: [BookListItemDTO] = [] { didSet { booksVersion += 1 } }

    /// 表示中の列から算出した、サーバへ要求する追加フィールド。RemoteBookTable のコーディネータが
    /// settings 変更時に更新する。
    var requestedFields: Set<String> = []
    var total = 0
    var page = 1
    var per: Int
    var query = ""
    var sortKey = "title"
    var ascending = true
    var isGrid = false
    var selection: Int? = nil
    var errorText: String? = nil
    /// Phase 4.2b-3 Task 4: /me で取得したトークンロール（write なら編集可）。
    var canEditServer = false
    /// /me によるロール確認が成功したか（一度だけ確認・reload 毎の再取得を避ける）。
    private var roleResolved = false

    /// Phase 4.2b-1b-2b Task 5: 共有 browse ビュー（sidebar / facet pane / detail）駆動状態。
    enum RemoteSidebarSelection: Equatable, Hashable {
        case library, favorites(Int64), recent, shelf(Int64), smartShelf(Int64)
    }
    var sidebarSelection: RemoteSidebarSelection = .library
    var filterState = FilterState()
    var browserPaneState = BrowserPaneState()
    var shelves: [ShelfDTO] = []
    var detail: BookDetailDTO? = nil

    /// 表示モード（paged / infinite）。setMode 経由で変更・永続化する。
    var scrollMode: RemoteScrollMode

    /// infinite スクロールの多重 loadMore を防ぐガード。
    private var isLoadingMore = false

    /// reload()/load() のたびにインクリメントし、in-flight な loadMore を無効化するカウンタ。
    private var loadGeneration = 0

    /// infinite モードの 1 チャンク件数（paged の per とは独立した固定値）。
    private let infiniteChunkSize = 100

    let coverCache = RemoteCoverCache()

    /// ビューワを 1 ウィンドウだけ保持する（ローカル AppState.viewerController と同じ方針）。
    private var viewerController: ViewerWindowController?

    init(client: RemoteLibraryClient, serverID: UUID, libraryUUID: String, libraryName: String, locked: Bool, libraryToken: String? = nil) {
        self.client = client
        self.serverID = serverID
        self.libraryUUID = libraryUUID
        self.libraryName = libraryName
        self.locked = locked
        self.libraryToken = libraryToken
        self.per = prefs.perPageSize
        self.scrollMode = prefs.scrollMode
    }

    var pageCountTotalPages: Int { remoteTotalPages(total: total, per: per) }

    // MARK: - Mode / per control

    /// 表示モードを切り替えて永続化し、先頭から読み直す。
    func setMode(_ m: RemoteScrollMode) {
        scrollMode = m
        prefs.scrollMode = m
        Task { await reload() }
    }

    /// paged の per を 20...500 にクランプして永続化し、先頭から読み直す。
    func setPer(_ n: Int) {
        per = clampRemotePerPage(n)
        prefs.perPageSize = per
        Task { await reload() }
    }

    // MARK: - Loading

    /// 現在の取得サイズ（infinite は固定チャンク、paged は per）。
    private var fetchSize: Int { scrollMode == .infinite ? infiniteChunkSize : per }

    /// 指定ページ・サイズで 1 チャンク取得する（load/reload/loadMore 共通）。
    /// scope（sidebar）/ filter / browse（facet pane）を自動付与する。
    private func fetchChunk(page: Int, size: Int) async throws -> BookPageDTO {
        let (scope, scopeId, recentDays) = scopeParams()
        return try await client.fetchBooks(
            libraryUUID: libraryUUID,
            query: query.isEmpty ? nil : query,
            sort: sortKey,
            ascending: ascending,
            page: page,
            per: size,
            libraryToken: libraryToken,
            scope: scope, scopeId: scopeId, recentDays: recentDays,
            filter: filterState, browse: browseConstraints(),
            fields: requestedFields
        )
    }

    // MARK: - Scope / browse params

    private func scopeParams() -> (String?, Int64?, Int?) {
        switch sidebarSelection {
        case .library: return (nil, nil, nil)
        case .favorites(let id): return ("favorites", id, nil)
        case .recent: return ("recent", nil, 7)
        case .shelf(let id): return ("shelf", id, nil)
        case .smartShelf(let id): return ("smartShelf", id, nil)
        }
    }

    private func browseConstraints() -> [BrowseConstraint] {
        zip(browserPaneState.fields, browserPaneState.selections).compactMap { (f, s) in
            guard let f, let s else { return nil }
            return BrowseConstraint(column: f.sqlColumn, value: s)
        }
    }

    /// paged のページ送り。現在の page を per サイズで取得し books を置換する。
    func load() async {
        loadGeneration += 1
        do {
            let result = try await fetchChunk(page: page, size: per)
            books = result.items
            total = result.total
            errorText = nil
        } catch let e as RemoteClientError {
            errorText = Self.message(for: e)
        } catch {
            errorText = "読み込みに失敗しました"
        }
    }

    /// 先頭から読み直す（query/sort/ascending/mode/per 変更時）。books を置換する。
    func reload() async {
        loadGeneration += 1
        page = 1
        books = []
        do {
            let result = try await fetchChunk(page: 1, size: fetchSize)
            books = result.items
            total = result.total
            errorText = nil
            // Phase 4.2b-3: トークンロール（編集可否）は一度だけ確認する。reload は
            // filter/sort/page 変更の度に走るため毎回 /me を叩かない。失敗時は roleResolved を
            // 立てず次回 reload で再試行（fail-closed: 解決するまで canEditServer=false）。
            if !roleResolved, let role = try? await client.me(libraryToken: libraryToken) {
                canEditServer = (role == .write)
                roleResolved = true
            }
        } catch let e as RemoteClientError {
            errorText = Self.message(for: e)
        } catch {
            errorText = "読み込みに失敗しました"
        }
    }

    /// infinite モードで末尾到達時に次チャンクを追記する。
    func loadMore() async {
        guard !isLoadingMore,
              scrollMode == .infinite,
              remoteNeedsNextChunk(loadedCount: books.count, total: total)
        else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let gen = loadGeneration
        do {
            let nextPage = page + 1
            let result = try await fetchChunk(page: nextPage, size: infiniteChunkSize)
            guard gen == loadGeneration else { return }
            page = nextPage
            books.append(contentsOf: result.items)
            total = result.total
            errorText = nil
        } catch let e as RemoteClientError {
            errorText = Self.message(for: e)
        } catch {
            errorText = "読み込みに失敗しました"
        }
    }

    /// 表ヘッダのクリックでソートを適用する。同じ列の再クリックで昇降反転。
    /// 列→サーバキーは AppCore の serverSortKey 写像を使う。
    func applyHeaderSort(column: BookColumn) async {
        let key = column.serverSortKey
        if sortKey == key { ascending.toggle() } else { sortKey = key; ascending = true }
        await reload()
    }

    func unlock(password: String) async {
        do {
            let token = try await client.unlock(libraryUUID: libraryUUID, password: password)
            libraryToken = token
            errorText = nil
            await reload()
        } catch RemoteClientError.forbidden {
            errorText = "パスワードが違います"
        } catch let e as RemoteClientError {
            errorText = Self.message(for: e)
        } catch {
            errorText = "解錠に失敗しました"
        }
    }

    // MARK: - Offline download (Phase 4.2b-2 Task 4)

    /// 指定本がオフライン保存済みか。
    func isDownloaded(_ bookID: Int) -> Bool {
        offlineStore.isDownloaded(serverID: serverID, libraryUUID: libraryUUID, bookID: bookID)
    }

    /// 本の detail + ファイル本体 + 表紙を取得し OfflineStore に保存する。
    func downloadBook(_ item: BookListItemDTO) async {
        do {
            let detail = try await client.bookDetail(libraryUUID: libraryUUID, bookID: item.id, libraryToken: libraryToken)
            let fileData = try await client.bookFile(libraryUUID: libraryUUID, bookID: item.id, libraryToken: libraryToken)
            let coverData = try? await client.coverData(libraryUUID: libraryUUID, bookID: item.id, maxw: 600, libraryToken: libraryToken)
            let ext = offlineFileExtension(for: fileData)
            try offlineStore.save(detail, serverID: serverID, libraryUUID: libraryUUID, libraryName: libraryName,
                                  fileExtension: ext, fileData: fileData, coverData: coverData)
            downloadedVersion &+= 1   // UI バッジ再評価のトリガ
            errorText = nil
        } catch {
            switch error as? RemoteClientError {
            case .offline: errorText = "ダウンロードできません（サーバに接続できません）"
            case .timeout: errorText = "ダウンロードがタイムアウトしました"
            case .notFound, .server: errorText = "この本はオフラインに保存できません（フォルダ型など非対応の可能性）"
            default: errorText = "ダウンロードに失敗しました"
            }
        }
    }

    // MARK: - Multi-select (4.2b-5)
    var selectionMode = false
    var multiSelection: Set<Int> = []
    /// 一括 DL の進捗（done, total）。実行中のみ非 nil。
    var batchProgress: (done: Int, total: Int)? = nil
    /// 一括 DL の完了要約（「○件ダウンロード」等）。4 秒後に自動で消える（A4 修正：
    /// errorText に出すと赤バナーが残り続けるため専用の自動消滅フィールドにする）。
    var batchSummary: String? = nil
    private var batchSummaryToken = 0

    /// 要約をセットし、4 秒後に自動でクリアする（最新の要約のみ残す）。
    private func showBatchSummary(_ text: String) {
        batchSummary = text
        batchSummaryToken &+= 1
        let token = batchSummaryToken
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, self.batchSummaryToken == token else { return }
            self.batchSummary = nil
        }
    }

    func toggleSelectionMode() {
        selectionMode.toggle()
        if !selectionMode { multiSelection.removeAll() }
    }
    func toggleSelected(_ id: Int) {
        if multiSelection.contains(id) { multiSelection.remove(id) } else { multiSelection.insert(id) }
    }
    func selectAllVisible() { multiSelection = Set(books.map { $0.id }) }
    func clearSelection() { multiSelection.removeAll() }

    /// 選択集合を順に DL。既 DL はスキップ、失敗しても続行、完了時に自動消滅する要約を出す。
    func downloadSelected() async {
        // isDownloaded(_:) は self.serverID / self.libraryUUID を内部で参照するため
        // BatchDownloadPlan.pending の isDownloaded クロージャはラベルなし bookID のみ渡す。
        let pending = BatchDownloadPlan.pending(selected: multiSelection) { id in
            isDownloaded(id)
        }
        let skipped = multiSelection.count - pending.count
        guard !pending.isEmpty else {
            showBatchSummary(skipped > 0 ? "選択はすべてダウンロード済みです" : "本が選択されていません")
            return
        }
        errorText = nil   // 直前のエラーバナーをクリア（バッチ中の per-book 失敗は要約に集約）
        var ok = 0, fail = 0
        batchProgress = (0, pending.count)
        for (i, id) in pending.enumerated() {
            guard let item = books.first(where: { $0.id == id }) else { fail += 1; continue }
            let before = downloadedVersion
            await downloadBook(item)
            if downloadedVersion != before { ok += 1 } else { fail += 1 }
            batchProgress = (i + 1, pending.count)
        }
        batchProgress = nil
        var parts = ["\(ok) 件ダウンロード"]
        if skipped > 0 { parts.append("\(skipped) 件スキップ") }
        if fail > 0 { parts.append("\(fail) 件失敗") }
        // per-book 失敗で downloadBook が errorText を立てている場合があるためクリアし、要約に一本化。
        errorText = nil
        showBatchSummary(parts.joined(separator: " / "))
        downloadedVersion &+= 1
    }

    /// オフライン保存を削除する。
    func removeDownload(_ bookID: Int) {
        offlineStore.remove(serverID: serverID, libraryUUID: libraryUUID, bookID: bookID)
        downloadedVersion &+= 1
    }

    /// 表紙バイト列を取得する（LRU キャッシュ経由）。失敗時は nil。
    func cover(bookID: Int) async -> Data? {
        // actor 境界を越える fetch クロージャが MainActor 隔離の self を捕捉しないよう、
        // 必要な値（Sendable）をローカルにコピーしてから渡す。
        let client = self.client
        let uuid = self.libraryUUID
        let token = self.libraryToken
        do {
            return try await coverCache.data(
                for: .init(libraryUUID: uuid, bookID: bookID, maxWidth: 300)
            ) {
                try await client.coverData(
                    libraryUUID: uuid, bookID: bookID, maxw: 300, libraryToken: token)
            }
        } catch {
            return nil
        }
    }

    // MARK: - Shelves / sidebar / detail (Phase 4.2b-1b-2b Task 5)

    func loadShelves() async {
        shelves = (try? await client.listShelves(libraryUUID: libraryUUID, libraryToken: libraryToken)) ?? []
    }

    func setSidebar(_ s: RemoteSidebarSelection) {
        guard s != sidebarSelection else { return }
        sidebarSelection = s
        Task { await reload() }
    }

    /// 詳細ペインの絞り込みジャンプ（作者等の「→」）。ローカル同様、DetailField を BrowseField に
    /// 写像できれば filterState に反映、できなければ検索にフォールバックして reload する（自由記載バグ修正）。
    func jumpToFilter(field: DetailField, value: String) async {
        if let bf = BrowserPaneState.BrowseField(from: field) {
            filterState.replaceSelection(for: bf.rawValue, with: [value])
        } else {
            query = value
        }
        await reload()
    }

    func selectBook(_ id: Int?) async {
        selection = id
        guard let id else { detail = nil; return }
        detail = try? await client.bookDetail(libraryUUID: libraryUUID, bookID: id, libraryToken: libraryToken)
    }

    /// Phase 4.2b-3 Task 4: BookPatch をサーバへ PATCH し、詳細・一覧を更新する。
    func applyRemotePatch(bookID: Int, patch: BookPatch) async {
        let dirStr: (PageDirection) -> String = { dir in
            switch dir {
            case .rightToLeft: return "rtl"
            case .leftToRight: return "ltr"
            }
        }
        let dto = BookPatchDTO(
            title: patch.title, author: patch.author, genre: patch.genre,
            neta: patch.neta, memo: patch.memo,
            keywordA: patch.keywordA, keywordB: patch.keywordB, keywordC: patch.keywordC,
            rating: patch.rating, unseen: patch.unseen,
            series: patch.series, volume: patch.volume, bookType: patch.bookType,
            pageDirection: patch.pageDirection.map { dirStr($0) },
            clearSeries: patch.clearSeries, clearVolume: patch.clearVolume,
            clearPageDirection: patch.clearPageDirection)
        do {
            _ = try await client.updateBook(libraryUUID: libraryUUID, bookID: bookID, patch: dto, libraryToken: libraryToken)
            await selectBook(bookID)   // 詳細ペインを最新内容で再描画
            await reload()             // 一覧行も更新
        } catch {
            if case RemoteClientError.forbidden = error { errorText = "編集権限がありません" }
            else { errorText = "編集に失敗しました" }
        }
    }

    /// 共有ファセット pane の facetValues クロージャ用。
    func facetValues(_ columnSQL: String, _ upper: [(String, String)]) async -> [String] {
        let (scope, scopeId, recentDays) = scopeParams()
        return (try? await client.facetValues(
            libraryUUID: libraryUUID, field: columnSQL, scope: scope, scopeId: scopeId, recentDays: recentDays,
            filter: filterState, browse: upper.map { BrowseConstraint(column: $0.0, value: $0.1) },
            q: query.isEmpty ? nil : query, libraryToken: libraryToken)) ?? []
    }

    /// 共有ファセット pane の refreshKey。
    var facetRefreshKey: String {
        let s = browserPaneState
        let f = (try? JSONEncoder().encode(filterState)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return "\(s.fields.map { $0?.sqlColumn ?? "" }.joined(separator: ","))|\(s.selections.map { $0 ?? "" }.joined(separator: ","))|\(query)|\(f)|\(String(describing: sidebarSelection))"
    }

    /// 共有 DetailPaneView の books（選択本の詳細 → BookRow 単一要素 or 空）。
    func detailBookRows() -> [BookRow] {
        guard let d = detail else { return [] }
        return [Self.mapDetail(d)]
    }

    private static func mapDetail(_ d: BookDetailDTO) -> BookRow {
        let dir: PageDirection? = d.pageDirection == "rtl" ? .rightToLeft : (d.pageDirection == "ltr" ? .leftToRight : nil)
        return BookRow(
            id: d.id, title: d.title, author: d.author, genre: d.genre, path: d.path,
            dateAdded: d.dateAdded, playDate: d.playDate, bookType: d.bookType, fileType: d.fileType,
            pages: d.pages, rating: d.rating, unseen: d.unseen, keywordA: d.keywordA, keywordB: d.keywordB,
            keywordC: d.keywordC, neta: d.neta, memo: d.memo, series: d.series, volume: d.volume,
            coverImageName: d.coverImageName,
            coverCropRect: BookRow.decodeCoverCropRect(json: d.coverCropRectJSON),
            pageDirection: dir, contentHash: nil, fileSize: nil, fileMtime: nil)
    }

    /// 共有 DetailPaneView の coverImage 注入用。
    func coverImage(_ bookID: Int) async -> NSImage? {
        // actor 境界を越える fetch クロージャが MainActor 隔離の self を捕捉しないよう、
        // 必要な値（Sendable）をローカルにコピーしてから渡す（cover(bookID:) と同じ方針）。
        let client = self.client
        let uuid = self.libraryUUID
        let token = self.libraryToken
        let key = RemoteCoverCache.Key(libraryUUID: uuid, bookID: bookID, maxWidth: 600)
        let data = try? await coverCache.data(for: key) {
            try await client.coverData(libraryUUID: uuid, bookID: bookID, maxw: 600, libraryToken: token)
        }
        return data.flatMap { NSImage(data: $0) }
    }

    // MARK: - Viewer

    /// リモート本を内蔵ビューワで開く。BookContent は RemoteBookContent。
    func openViewer(book: BookListItemDTO) {
        // 直前の失敗バナー（「本を開けませんでした」等）をクリアする。これが無いと、紐付けの
        // 切れた本で失敗した後に別の本を正常に開いても警告が残り続ける（smoke 4.2b-4 指摘）。
        errorText = nil
        let content = RemoteBookContent(
            client: client,
            libraryUUID: libraryUUID,
            bookID: book.id,
            libraryToken: libraryToken,
            maxWidth: 1600
        )
        let row = Self.makeBookRow(from: book)
        Task { @MainActor in
            let pageCount: Int
            do {
                pageCount = try await content.pageCount
            } catch {
                self.errorText = "本を開けませんでした"
                return
            }
            guard pageCount > 0 else {
                self.errorText = "本を開けませんでした（0ページ）"
                return
            }
            // リモートでは per-book の永続見開き状態を持たないため、
            // グローバル既定（spreadByDefault）で開く。lastPage はサーバの値を尊重。
            let initialState = ResolvedViewerState(
                spreadEnabled: ViewerSettings.shared.spreadByDefault,
                coverOffset: true,
                lastPage: max(0, book.lastPage ?? 0),
                overrides: [:]
            )
            let options = ViewerOptions(
                pageDirection: row.pageDirection ?? ViewerSettings.shared.pageDirection,
                endOfBookBehavior: ViewerSettings.shared.endOfBookBehavior
            )
            let controller = ViewerWindowController(
                content: content,
                book: row,
                pageCount: pageCount,
                options: options,
                initialState: initialState,
                loadNextVolume: { [weak self] cur in
                    await self?.resolveRemoteVolume(after: cur.id, direction: "next")
                },
                loadPrevVolume: { [weak self] cur in
                    await self?.resolveRemoteVolume(after: cur.id, direction: "prev")
                },
                // 進捗をリモートサーバへ POST する（ローカル DB 書き込みの代替）。
                persistState: { [weak self] (b, lastPage, _, _) in
                    guard let self else { return }
                    Task {
                        try? await self.client.postProgress(
                            libraryUUID: self.libraryUUID, bookID: b.id,
                            page: lastPage, libraryToken: self.libraryToken)
                    }
                    // v4 修正: メモリ上の一覧 DTO の lastPage も更新する。これをしないと
                    // 一覧を再取得するまで stale な lastPage で開いてしまい、リモートで
                    // 開き直すと毎回元のページに戻る（サーバには POST 済でも一覧側が古い）。
                    if let i = self.books.firstIndex(where: { $0.id == b.id }) {
                        self.books[i] = self.books[i].withLastPage(lastPage)
                    }
                },
                // ページレイアウト override はリモートでは永続化しない（no-op）。
                persistPageOverride: { _, _, _ in },
                onClose: { [weak self] in self?.viewerController = nil }
            )
            self.viewerController = controller
            controller.onSetBookPageDirection = { [weak self] id, dir in
                Task { await self?.setRemoteDirection(bookID: id, direction: dir) }
            }
            controller.present()
        }
    }

    /// 読む方向をサーバへ同期する（R トークンでも /direction 経由で可）。
    func setRemoteDirection(bookID: Int, direction: PageDirection?) async {
        let s: String? = direction.map { $0 == .rightToLeft ? "rtl" : "ltr" }
        do {
            try await client.updatePageDirection(libraryUUID: libraryUUID, bookID: bookID, direction: s, libraryToken: libraryToken)
        } catch {
            errorText = "読む方向の同期に失敗しました"
        }
    }

    /// BookListItemDTO から ViewerWindowController が必要とする最小限の BookRow を合成する。
    /// path は nil（リモートなので実ファイル参照は無い）だが、ViewerWindowController は
    /// content（RemoteBookContent）経由で読むため path には依存しない。
    private static func makeBookRow(from dto: BookListItemDTO) -> BookRow {
        BookRow(
            id: dto.id,
            title: dto.title,
            author: dto.author,
            genre: nil,
            path: nil,
            dateAdded: dto.dateAdded,
            playDate: dto.lastReadAt,
            bookType: dto.bookType,
            fileType: 0,
            pages: dto.pages,
            rating: dto.rating,
            unseen: dto.unseen,
            keywordA: nil,
            keywordB: nil,
            keywordC: nil,
            neta: nil,
            series: dto.series,
            volume: dto.volume
        )
    }

    /// 隣接巻をサーバから解決し NextVolume を組む。該当なし/失敗は nil。
    /// content は RemoteBookContent（ストリーミング）なので未 DL の巻でも再生できる。
    private func resolveRemoteVolume(after bookID: Int, direction: String) async -> NextVolume? {
        let dto: BookListItemDTO?
        do {
            dto = try await client.adjacentVolume(
                libraryUUID: libraryUUID, bookID: bookID,
                direction: direction, libraryToken: libraryToken)
        } catch {
            return nil
        }
        guard let dto else { return nil }
        let content = RemoteBookContent(
            client: client, libraryUUID: libraryUUID,
            bookID: dto.id, libraryToken: libraryToken, maxWidth: 1600)
        let row = Self.makeBookRow(from: dto)
        let state = ResolvedViewerState(
            spreadEnabled: ViewerSettings.shared.spreadByDefault,
            coverOffset: true,
            lastPage: max(0, dto.lastPage ?? 0),
            overrides: [:]
        )
        return NextVolume(content: content, book: row, state: state)
    }

    // MARK: - Error messages

    static func message(for error: RemoteClientError) -> String {
        switch error {
        case .offline: return "サーバに接続できません（ネットワーク/アドレスを確認）"
        case .timeout: return "接続がタイムアウトしました"
        case .unauthorized: return "トークンが無効です"
        case .forbidden: return "アクセスが拒否されました"
        case .notFound: return "見つかりませんでした"
        case .server(let code): return "サーバエラー（\(code)）"
        case .decoding: return "応答の解析に失敗しました"
        case .badResponse: return "不正な応答を受信しました"
        }
    }
}
