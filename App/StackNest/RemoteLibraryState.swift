// SPDX-License-Identifier: MIT
import AppCore
import AppKit
import Foundation
import LibraryServerAPI
import LibraryStore
import Observation
import RemoteClient
import os

/// G12b-3b: メンテナンスジョブ（メタデータ補完・表紙圧縮）の進捗表示用 UI 状態。
struct MaintenanceUIState: Equatable {
    let job: String
    var done: Int
    var total: Int
}

/// Phase 4.2b-1: リモートライブラリ 1 個分の閲覧状態。
/// ローカルの AppState に相当する軽量モデル（書き込みはせず読み取り+進捗 POST のみ）。
@Observable
@MainActor
final class RemoteLibraryState {
    private static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "RemoteLibrary")
    /// G12b-3b Task 1: reload() 失敗時の切り分け用ログ（activeBatchCount の文脈を残す）。
    private static let reloadLog = Logger(subsystem: "app.shelfsmith.stacknest", category: "RemoteReload")

    let client: RemoteLibraryClient
    let serverID: UUID
    let libraryUUID: String
    var libraryName: String
    var locked: Bool
    var libraryToken: String?

    /// Phase 4.2c-2: ウィンドウ生成時に注入される resume 意図。最初の本一覧ロード成功後に
    /// 1 回だけ消費し、該当本を（resume なら続き確認なしで）開く。
    var pendingOpenBookID: (id: Int, resume: Bool)?

    /// Phase 4.2b-2 Task 4: オフライン保存ストア（既定の Application Support ベース）。
    private let offlineStore = OfflineStore()

    /// オフライン DL/削除のたびに &+=1 する観測カウンタ。
    /// OfflineStore はディスクから読むため SwiftUI が直接観測できない。
    /// ビュー body で参照させ、ダウンロード済みバッジを再評価させるためのトリガ。
    var downloadedVersion = 0

    /// G4b: 表紙書き込み（setRemoteCover / setRemoteExternalCover）ごとに増える版数。
    /// 詳細ペイン表紙ビューの identity に注入し、外部画像の差し替え等でメタ（coverImageName）が
    /// 不変でも再描画/再取得させる。downloadedVersion はダウンロード等でも増えるため、
    /// 表紙のちらつきを避けて専用カウンタとする。
    var coverVersion = 0

    /// G10: 詳細ペインの表紙表示トグル（per-browser・このウィンドウ専用・既定 true）。
    /// ツールバーボタンで切り替え、DetailPaneView(showCover:) に注入する。
    var showDetailCover = true

    /// Phase 4.2b-1b-1 Task 3: 表示モード + per のグローバル設定（UserDefaults 永続）。
    private let prefs = RemoteBrowsePreferences()

    /// books が更新されるたびに増えるカウンタ。表コーディネータが reloadData の要否判定に使う
    /// （ソートのみの並べ替えで件数・先頭が一致しても確実に再描画）。
    private(set) var booksVersion = 0
    var books: [BookListItemDTO] = [] {
        didSet {
            booksVersion += 1
            // G4c: サーバ coverVersion を bookID→version へ派生（表紙キャッシュの版鍵に使う）。
            coverVersionByID = Dictionary(books.compactMap { d in d.coverVersion.map { (d.id, $0) } },
                                          uniquingKeysWith: { first, _ in first })
        }
    }
    /// G4c: 各本の表紙版トークン（サーバ coverVersion）。表紙キャッシュ鍵に注入し、サーバ表紙変更へ追従。
    private var coverVersionByID: [Int: String] = [:]

    /// 表示中の列から算出した、サーバへ要求する追加フィールド。RemoteBookTable のコーディネータが
    /// settings 変更時に更新する。
    var requestedFields: Set<String> = []
    var total = 0
    /// G14: サイドバー用の安定なライブラリ総数（現在 scope の total とは別）。
    var libraryTotal: Int = 0
    /// G14: サイドバー用の最近件数。
    var recentCount: Int = 0
    /// G14: サーバ側 recent_days 設定値（バッジと .recent scope の一覧取得の両方に使う。既定 14）。
    var recentDaysSetting: Int = 14
    var page = 1
    var per: Int
    var query = ""
    var sortKey = "title"
    var ascending = true
    var isGrid = false
    var selection: Int? = nil
    var errorText: String? = nil
    /// G12b-3b: 実行中メンテナンスジョブの進捗（nil = 実行中なし）。SSE `.maintenanceProgress` で更新。
    var maintenanceJob: MaintenanceUIState? = nil
    /// G12b-3b: メンテナンス完了メッセージ（アラート表示 → OK で nil に戻す想定）。
    var maintenanceResult: String? = nil
    /// Phase C-②: /me で取得した接続トークンの tier（read<edit<admin）。fail-closed で既定 .read。
    var tier: AccessTier = .read
    /// 編集可（tier≥edit）。従来の編集可フラグ相当。
    var canEdit: Bool { tier >= .edit }
    /// 削除可（tier≥admin・実ファイル/DB 削除）。
    var canDelete: Bool { tier >= .admin }
    /// /me による tier 確認が成功したか（一度だけ確認・reload 毎の再取得を避ける）。
    private var roleResolved = false

    /// Phase 4.2b-1b-2b Task 5: 共有 browse ビュー（sidebar / facet pane / detail）駆動状態。
    /// 4.2c-7: 永続化のため AppCore.RemoteSidebarSelection を参照（typealias で呼び出し側無改修）。
    typealias RemoteSidebarSelection = AppCore.RemoteSidebarSelection
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

    /// Phase 4.2c-3: 検索欄のライブフィルタ用デバウンス Task。連続入力中は最後の 1 回のみ reload。
    private var searchDebounce: Task<Void, Never>?
    /// 検索欄入力時に呼ぶ。300ms デバウンスして reload（連続入力中は最後の1回のみ）。
    func scheduleSearchReload() {
        searchDebounce?.cancel()
        searchDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            await self?.reload()
        }
    }

    /// infinite モードの 1 チャンク件数（paged の per とは独立した固定値）。
    private let infiniteChunkSize = 100

    let coverCache: RemoteCoverCache

    /// ビューワを 1 ウィンドウだけ保持する（ローカル AppState.viewerController と同じ方針）。
    private var viewerController: ViewerWindowController?

    init(client: RemoteLibraryClient, serverID: UUID, libraryUUID: String, libraryName: String, locked: Bool, libraryToken: String? = nil) {
        self.client = client
        self.serverID = serverID
        self.libraryUUID = libraryUUID
        self.libraryName = libraryName
        self.locked = locked
        self.libraryToken = libraryToken
        self.coverCache = RemoteCoverCache(serverID: serverID, libraryUUID: libraryUUID)
        self.per = prefs.perPageSize
        self.scrollMode = prefs.scrollMode
        // 4.2c-7: 保存済みブラウズ状態（ファセット/ソート/grid/フィルタ/サイドバー）を復元する。
        if let s = prefs.browseState(serverID: serverID, libraryUUID: libraryUUID) {
            self.browserPaneState = s.browserPaneState
            self.sortKey = s.sortKey
            self.ascending = s.ascending
            self.isGrid = s.isGrid
            self.filterState = s.filterState
            self.sidebarSelection = s.sidebar
            self.lastPersistedBrowseState = s   // 初回 reload での無駄書きを防ぐ
        }
        RemoteLibraryRegistry.shared.add(self)
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
        case .recent: return ("recent", nil, recentDaysSetting)
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
    func reload(clearFirst: Bool = true) async {
        loadGeneration += 1
        page = 1
        // clearFirst=false: 一括編集後の再取得などで、旧リストを保持したまま差し替える
        // （books=[] による一瞬の空表示＝smoke A1 インラインを防ぐ）。
        if clearFirst { books = [] }
        do {
            let result = try await fetchChunk(page: 1, size: fetchSize)
            books = result.items
            total = result.total
            errorText = nil
            // Phase C-②: 接続トークンの tier（編集/削除可否）は一度だけ確認する。reload は
            // filter/sort/page 変更の度に走るため毎回 /me を叩かない。失敗時は roleResolved を
            // 立てず次回 reload で再試行（fail-closed: 解決するまで tier=.read）。
            if !roleResolved, let me = try? await client.me(libraryToken: libraryToken) {
                tier = me.tier
                roleResolved = true
                // Minor #4: loadShelves が tier 解決前（.read）にお気に入り取得をスキップしている
                // 可能性があるため、edit 判明時に一度取得しておく（favoriteBookIDs 内で canEdit gate 済み）。
                await refreshFavoriteIDs()
            }
            // Phase 4.2c-2: 最初の本一覧ロード成功後に resume 意図を 1 回だけ消費する。
            // self-clear するため再 reload では再発火しない。
            if let pend = pendingOpenBookID {
                pendingOpenBookID = nil
                await openBookByID(pend.id, resumeDirect: pend.resume)
            }
        } catch let e as RemoteClientError {
            // G12b-3b Task 1: 赤バナー切り分け用（一括編集中の自エコー reload 競合を activeBatchCount で判別）。
            Self.reloadLog.warning("reload failed during activeBatchCount=\(self.activeBatchCount, privacy: .public): \(String(describing: e), privacy: .public)")
            errorText = Self.message(for: e)
        } catch {
            errorText = "読み込みに失敗しました"
        }
        // 4.2c-7: filter/sort/facet/sidebar/mode 変更はいずれも reload を伴うため、
        // ここで現在のブラウズ状態を (serverID, libraryUUID) 単位で永続化する。
        persistBrowseState()
    }

    /// SSE ライブ同期由来の再取得（reconnect の .connected / ストリーム終了の取りこぼし回収 /
    /// .structureChanged・.bookChanged の反映）で使う、**ページ/スクロール位置を保持する** reload。
    /// reload() は page=1 にリセットするため、~5s HB で維持される SSE が周期的に再確立されるたび
    /// 一覧が先頭へ戻る（無限スクロールは先頭 100 に truncate・ページ表示は 1 ページ目）重大 UX バグを
    /// 起こしていた。ユーザー操作（filter/sort/sidebar/mode 変更）は従来どおり reload()（先頭リセット）。
    func liveReload() async {
        loadGeneration += 1
        do {
            if scrollMode == .infinite {
                // 無限スクロール: 現在ロード済み件数を 1 リクエストで再取得し、表示窓を維持する。
                let keep = max(infiniteChunkSize, books.count)
                let result = try await fetchChunk(page: 1, size: keep)
                books = result.items
                total = result.total
                // loadMore の次ページ計算（page+1）が破綻しないよう、現在の窓に page を整合させる。
                page = max(1, Int(ceil(Double(books.count) / Double(infiniteChunkSize))))
            } else {
                // ページ表示: 現在ページをそのまま再取得（page を変えない）。
                let result = try await fetchChunk(page: page, size: per)
                books = result.items
                total = result.total
            }
            errorText = nil
        } catch let e as RemoteClientError {
            errorText = Self.message(for: e)
        } catch {
            errorText = "読み込みに失敗しました"
        }
        persistBrowseState()
    }

    /// 直近に永続化したブラウズ状態。reload は検索デバウンス等で高頻度に走るため、
    /// 差分があるときだけ UserDefaults へ書いて無駄な JSON 書込みを避ける。
    @ObservationIgnored private var lastPersistedBrowseState: RemoteBrowseState?

    /// 4.2c-7: 現在のブラウズ状態を (serverID, libraryUUID) 単位で UserDefaults に保存する。
    /// query（検索文字列）は一時的なものとして保存しない。直近保存値と同一なら何もしない。
    func persistBrowseState() {
        let s = RemoteBrowseState(
            browserPaneState: browserPaneState, sortKey: sortKey, ascending: ascending,
            isGrid: isGrid, filterState: filterState, sidebar: sidebarSelection)
        guard s != lastPersistedBrowseState else { return }
        lastPersistedBrowseState = s
        prefs.setBrowseState(s, serverID: serverID, libraryUUID: libraryUUID)
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

    /// 現在ダウンロード中の本と進捗（0...1）。DL 列リング/バッチが参照。完了で nil。
    var downloadProgress: (bookID: Int, fraction: Double)? = nil

    /// 本の detail + ファイル本体 + 表紙を取得し OfflineStore に保存する。
    /// cancelToken: 一括 DL の即時キャンセル用（×ボタン）。受信中に立つと CancellationError で中断。
    func downloadBook(_ item: BookListItemDTO, cancelToken: CancelFlag? = nil) async {
        downloadProgress = (item.id, 0)
        defer { downloadProgress = nil }
        do {
            let detail = try await client.bookDetail(libraryUUID: libraryUUID, bookID: item.id, libraryToken: libraryToken)
            let fileData = try await client.bookFile(
                libraryUUID: libraryUUID, bookID: item.id, libraryToken: libraryToken,
                onProgress: { [weak self] f in
                    Task { @MainActor in self?.downloadProgress = (item.id, f) }
                },
                shouldCancel: { cancelToken?.isCancelled ?? false })
            let coverData = try? await client.coverData(libraryUUID: libraryUUID, bookID: item.id, maxw: 600, libraryToken: libraryToken)
            let ext = offlineFileExtension(for: fileData)
            try offlineStore.save(detail, serverID: serverID, libraryUUID: libraryUUID, libraryName: libraryName,
                                  fileExtension: ext, fileData: fileData, coverData: coverData)
            downloadedVersion &+= 1   // UI バッジ再評価のトリガ
            errorText = nil
        } catch {
            // 4.2c-3 (D2a): ×ボタンによる中断はエラー扱いしない（要約に「中断」を出す）。
            if (cancelToken?.isCancelled ?? false) || error is CancellationError || Task.isCancelled { return }
            switch error as? RemoteClientError {
            case .offline: errorText = "ダウンロードできません（サーバに接続できません）"
            case .timeout: errorText = "ダウンロードがタイムアウトしました"
            case .notFound, .server: errorText = "この本はオフラインに保存できません（フォルダ型など非対応の可能性）"
            default: errorText = "ダウンロードに失敗しました"
            }
        }
    }

    // MARK: - Multi-select (4.2b-5 → 4.2c-3: native ⌘/Shift multi-select)
    var multiSelection: Set<Int> = []
    /// 一括 DL の進捗（done, total）。実行中のみ非 nil。
    var batchProgress: (done: Int, total: Int)? = nil
    /// 一括 DL の完了要約（「○件ダウンロード」等）。4 秒後に自動で消える（A4 修正：
    /// errorText に出すと赤バナーが残り続けるため専用の自動消滅フィールドにする）。
    var batchSummary: String? = nil
    /// 4.2c-3: 要約の種別（アイコン/色の出し分け）。成功のみ=✓ / 失敗あり=⚠ / 中断=✕ / 情報=ⓘ。
    enum BatchSummaryKind { case success, warning, cancelled, info }
    var batchSummaryKind: BatchSummaryKind = .success
    private var batchSummaryToken = 0
    /// 4.2c-3 (D2a v3): スレッド安全なキャンセルトークン。bookFile のバイトループは MainActor 外で
    /// 回るため、Task.isCancelled には依存せず（v4 で不伝播のデグレ）、ロック付きフラグで
    /// ループ制御と in-flight 受信打ち切りの両方を確実に行う。
    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func cancel() { lock.lock(); value = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
    /// 実行中の一括 DL のキャンセルトークン（×ボタンが立てる）。
    private var batchCancel: CancelFlag?
    /// 一括 DL の Task ハンドル（ボタンから async を起動するため保持。cancel は補助）。
    private var batchTask: Task<Void, Never>?

    /// 要約をセットし、4 秒後に自動でクリアする（最新の要約のみ残す）。
    private func showBatchSummary(_ text: String, kind: BatchSummaryKind = .success) {
        batchSummary = text
        batchSummaryKind = kind
        batchSummaryToken &+= 1
        let token = batchSummaryToken
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, self.batchSummaryToken == token else { return }
            self.batchSummary = nil
        }
    }

    /// 選択集合を順に DL。既 DL はスキップ、失敗しても続行、完了時に自動消滅する要約を出す。
    func downloadSelected() async { await downloadBooks(ids: multiSelection) }

    /// 指定 ID 群を順に DL する中核（単一/複数で共有）。進捗バー・×中断・要約を出す。
    private func downloadBooks(ids: Set<Int>) async {
        // isDownloaded(_:) は self.serverID / self.libraryUUID を内部で参照するため
        // BatchDownloadPlan.pending の isDownloaded クロージャはラベルなし bookID のみ渡す。
        let pending = BatchDownloadPlan.pending(selected: ids) { id in
            isDownloaded(id)
        }
        let skipped = ids.count - pending.count
        guard !pending.isEmpty else {
            showBatchSummary(skipped > 0 ? "選択はすべてダウンロード済みです" : "書籍が選択されていません",
                             kind: .info)
            return
        }
        errorText = nil   // 直前のエラーバナーをクリア（バッチ中の per-book 失敗は要約に集約）
        // 保険: 通常は startBatchDownload() が事前に作成するが、万一未作成なら×が効くよう自己生成する。
        if batchCancel == nil { batchCancel = CancelFlag() }
        let token = batchCancel
        var ok = 0, fail = 0, cancelled = false
        batchProgress = (0, pending.count)
        for (i, id) in pending.enumerated() {
            if token?.isCancelled == true { cancelled = true; break }   // D2a: ×ボタン（反復前の中断）
            guard let item = books.first(where: { $0.id == id }) else { fail += 1; continue }
            let before = downloadedVersion
            await downloadBook(item, cancelToken: token)
            if token?.isCancelled == true { cancelled = true; break }   // D2a: in-flight をキャンセルした場合
            if downloadedVersion != before { ok += 1 } else { fail += 1 }
            batchProgress = (i + 1, pending.count)
        }
        batchProgress = nil
        var parts = ["\(ok) 件ダウンロード"]
        if skipped > 0 { parts.append("\(skipped) 件スキップ") }
        if fail > 0 { parts.append("\(fail) 件失敗") }
        if cancelled {
            // 中断で未完了になった件数（= 未DL対象 − 成功 − 失敗。in-flight 中断＋未着手を含む）。
            let cancelledCount = max(0, pending.count - ok - fail)
            parts.append(cancelledCount > 0 ? "\(cancelledCount) 件中断" : "中断")
        }
        // per-book 失敗で downloadBook が errorText を立てている場合があるためクリアし、要約に一本化。
        errorText = nil
        // アイコン/色の出し分け: 中断 > 失敗あり > 成功のみ の優先で種別を決める。
        let kind: BatchSummaryKind = cancelled ? .cancelled : (fail > 0 ? .warning : .success)
        showBatchSummary(parts.joined(separator: " / "), kind: kind)
        downloadedVersion &+= 1
    }

    /// 4.2c-3 (D2a v3): 一括 DL を開始する。新しいキャンセルトークンを作り Task で走らせる。
    func startBatchDownload() {
        batchCancel?.cancel()
        batchTask?.cancel()
        batchCancel = CancelFlag()
        batchTask = Task { [weak self] in await self?.downloadSelected() }
    }

    /// 4.2c-4: 単一 DL も一括と同じ進捗バー/×中断 UI を出す（右クリック「ダウンロード」用）。
    func startSingleDownload(_ book: BookListItemDTO) {
        batchCancel?.cancel()
        batchTask?.cancel()
        batchCancel = CancelFlag()
        let id = book.id
        batchTask = Task { [weak self] in await self?.downloadBooks(ids: [id]) }
    }

    /// 4.2c-3 (D2a v3): 実行中の一括 DL を即時中断する。トークンを同期で立て、bookFile の
    /// バイト受信ループが次の確認点（~64KB ごと）で打ち切る。Task.cancel は補助。
    func cancelBatchDownload() {
        batchCancel?.cancel()
        batchTask?.cancel()
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
        let version = coverVersionByID[bookID]   // G4c: 版鍵
        do {
            return try await coverCache.data(
                for: .init(libraryUUID: uuid, bookID: bookID, maxWidth: 300, version: version)
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
        // 4.2c-7: 復元した sidebar が現存しないシェルフを指す場合は library に戻す。
        // loadShelves と reload は NavigationSplitView の兄弟 task で順序保証が無く、reload が
        // 削除済みシェルフ scope で空一覧を取得した後に loadShelves が走ると「library 選択なのに
        // 0 件」が残る。値を戻したときは reload し直して正しい一覧を表示する。
        switch sidebarSelection {
        case .shelf(let id), .smartShelf(let id):
            if !shelves.contains(where: { $0.id == id }) {
                sidebarSelection = .library
                await reload()
            }
        default:
            break
        }
        await refreshCounts()
        await refreshFavoriteIDs()
    }

    /// G14: サイドバー用の安定件数（scope 非依存のライブラリ総数＋最近件数）を取得する。
    func refreshCounts() async {
        guard let c = try? await client.fetchCounts(libraryUUID: libraryUUID, libraryToken: libraryToken) else { return }
        libraryTotal = c.libraryTotal
        recentCount = c.recentCount
        recentDaysSetting = c.recentDays
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
    /// BookPatch → BookPatchDTO 変換（単一/一括編集で共有）。
    static func patchToDTO(_ patch: BookPatch) -> BookPatchDTO {
        let dirStr: (PageDirection) -> String = { dir in
            switch dir {
            case .rightToLeft: return "rtl"
            case .leftToRight: return "ltr"
            }
        }
        return BookPatchDTO(
            title: patch.title, author: patch.author, genre: patch.genre,
            neta: patch.neta, memo: patch.memo,
            keywordA: patch.keywordA, keywordB: patch.keywordB, keywordC: patch.keywordC,
            rating: patch.rating, unseen: patch.unseen,
            series: patch.series, volume: patch.volume, bookType: patch.bookType,
            pageDirection: patch.pageDirection.map { dirStr($0) },
            clearSeries: patch.clearSeries, clearVolume: patch.clearVolume,
            clearPageDirection: patch.clearPageDirection)
    }

    func applyRemotePatch(bookID: Int, patch: BookPatch) async {
        let dto = Self.patchToDTO(patch)
        // G12b-3c S5: 適用前の一覧値から逆 patch を作っておき、PATCH 成功時のみ undo に積む
        // （失敗した編集は undo 対象にしない）。
        let inverse = books.first(where: { $0.id == bookID })
            .map { (bookID: bookID, patch: Self.inversePatch(applied: dto, old: $0)) }
        do {
            _ = try await client.updateBook(libraryUUID: libraryUUID, bookID: bookID, patch: dto, libraryToken: libraryToken)
            if let inverse { pushUndo(.rePatch([inverse])) }
            await selectBook(bookID)   // 詳細ペインを最新内容で再描画
            await reload()             // 一覧行も更新
        } catch {
            if case RemoteClientError.forbidden = error { errorText = "編集権限がありません" }
            else { errorText = "編集に失敗しました" }
        }
    }

    // MARK: - G12b-3c S5: リモート undo/redo（メタ編集の逆 patch・削除の restore）

    /// メタ編集(rePatch)・削除(restore)の undo 単位。
    enum RemoteUndoOp {
        case rePatch([(bookID: Int, patch: BookPatchDTO)])   // メタ編集の逆
        case restore([BookRestoreDTO])                        // 削除の逆
    }
    @ObservationIgnored private var undoStack: [RemoteUndoOp] = []
    @ObservationIgnored private var redoStack: [RemoteUndoOp] = []
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    /// メニューの有効/無効判定用の変更カウンタ（push/pop のたびに ++。Observation 対象）。
    var undoStateVersion = 0
    private func pushUndo(_ op: RemoteUndoOp) {
        undoStack.append(op)
        redoStack.removeAll()
        undoStateVersion += 1
    }

    /// 適用済み patch (`applied`) と適用前の本の状態 (`old`) から逆 patch を作る。
    /// `old` は一覧表示用 BookListItemDTO なので、そこに存在しないフィールド（pageDirection）や、
    /// clear 手段のない optional フィールド（author/genre/neta/memo/keywordA-C を NULL に戻す方法が
    /// BookPatchDTO に無い）で旧値が nil の場合は、その項目を逆 patch に含めない
    /// （＝「表示済みフィールドの復元」。Task 8 brief 参照。捕捉できない項目は undo で復元されない）。
    static func inversePatch(applied: BookPatchDTO, old: BookListItemDTO) -> BookPatchDTO {
        var inv = BookPatchDTO()
        if applied.title != nil { inv.title = old.title }
        if applied.author != nil { inv.author = old.author }
        if applied.genre != nil { inv.genre = old.genre }
        if applied.neta != nil { inv.neta = old.neta }
        if applied.memo != nil { inv.memo = old.memo }
        if applied.keywordA != nil { inv.keywordA = old.keywordA }
        if applied.keywordB != nil { inv.keywordB = old.keywordB }
        if applied.keywordC != nil { inv.keywordC = old.keywordC }
        if applied.rating != nil { inv.rating = old.rating }
        if applied.unseen != nil { inv.unseen = old.unseen }
        if applied.bookType != nil { inv.bookType = old.bookType }
        if applied.series != nil || applied.clearSeries {
            if let s = old.series { inv.series = s } else { inv.clearSeries = true }
        }
        if applied.volume != nil || applied.clearVolume {
            if let v = old.volume { inv.volume = v } else { inv.clearVolume = true }
        }
        // pageDirection/clearPageDirection: BookListItemDTO に旧値がないため意図的に反転しない。
        return inv
    }

    /// 直近の undo 単位を取り消す（rePatch=逆 patch を再適用 / restore=削除を復元）。
    /// 成功後は reload して一覧を最新化し、選択中の詳細も再取得する。
    func undo() async {
        guard let op = undoStack.popLast() else { return }
        undoStateVersion += 1
        switch op {
        case .rePatch(let items):
            var redoItems: [(bookID: Int, patch: BookPatchDTO)] = []
            for (id, inv) in items {
                if let b = books.first(where: { $0.id == id }) {
                    redoItems.append((id, Self.inversePatch(applied: inv, old: b)))
                }
                _ = try? await client.updateBook(libraryUUID: libraryUUID, bookID: id, patch: inv, libraryToken: libraryToken)
            }
            redoStack.append(.rePatch(redoItems))
        case .restore(let rows):
            try? await client.restoreBooks(rows, libraryUUID: libraryUUID, libraryToken: libraryToken)
            // redo = 再削除（redo() 側で id から deleteBook する）。
            redoStack.append(.restore(rows))
        }
        await reload(clearFirst: false)
        if let id = selection { await selectBook(id) }
    }

    /// 直近に undo した操作をやり直す。
    func redo() async {
        guard let op = redoStack.popLast() else { return }
        undoStateVersion += 1
        switch op {
        case .rePatch(let items):
            var undoItems: [(bookID: Int, patch: BookPatchDTO)] = []
            for (id, p) in items {
                if let b = books.first(where: { $0.id == id }) {
                    undoItems.append((id, Self.inversePatch(applied: p, old: b)))
                }
                _ = try? await client.updateBook(libraryUUID: libraryUUID, bookID: id, patch: p, libraryToken: libraryToken)
            }
            undoStack.append(.rePatch(undoItems))
        case .restore(let rows):
            // restore の redo = 再削除。DB-only（trash:false）で行う: 元が trash 削除でも、
            // ファイルは undo（restore）時点で既にゴミ箱から復元済みのため、ここで trash:true にすると
            // 実ファイルの扱いが往復のたびに増える／不整合になりうる。DB のみ削除して往復を安全にする。
            var reRows: [BookRestoreDTO] = []
            for r in rows {
                reRows.append(r)
                _ = try? await client.deleteBook(libraryUUID: libraryUUID, bookID: r.id, trash: false, libraryToken: libraryToken)
            }
            undoStack.append(.restore(reRows))
        }
        await reload(clearFirst: false)
    }

    // MARK: - 4.2c-6a: 一括メタ編集（replace・per-book PATCH＋進捗/中断）

    /// 詳細ペイン複数選択編集の進捗（done, total）。実行中のみ非 nil。
    var editProgress: (done: Int, total: Int)? = nil
    var editSummary: String? = nil
    var editSummaryKind: BatchSummaryKind = .success
    private var editSummaryToken = 0
    private var editCancel: CancelFlag?
    private var editTask: Task<Void, Never>?

    private func showEditSummary(_ text: String, kind: BatchSummaryKind) {
        editSummary = text; editSummaryKind = kind
        editSummaryToken &+= 1
        let token = editSummaryToken
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, self.editSummaryToken == token else { return }
            self.editSummary = nil
        }
    }

    /// Phase C-②: 選択本をサーバから削除（admin 必須）。trash=true でゴミ箱＋DB削除、false で DB のみ。
    /// G12b-3c S5: 削除成功分は BookRestoreDTO として undo スタックに積み、undo() で復元できる。
    /// 成功分をローカル一覧から除去し、失敗は要約表示する。
    func deleteBooks(ids: Set<Int>, trash: Bool) async {
        guard canDelete, !ids.isEmpty else { return }
        let list = Array(ids)
        errorText = nil
        var ok = 0, fail = 0
        // G12b-3c S5: 削除に成功した行の BookRestoreDTO を集め、undo（restore）に使う。
        var restored: [BookRestoreDTO] = []
        for id in list {
            do {
                let row = try await client.deleteBook(libraryUUID: libraryUUID, bookID: id, trash: trash, libraryToken: libraryToken)
                restored.append(row)
                await coverCache.invalidate(libraryUUID: libraryUUID, bookID: id)
                await RemotePageCache.shared.deleteBook(serverID: serverID, libraryUUID: libraryUUID, bookID: id)
                books.removeAll { $0.id == id }
                ok += 1
            } catch {
                fail += 1
            }
        }
        if !restored.isEmpty { pushUndo(.restore(restored)) }
        multiSelection.removeAll()
        if let sel = selection, !books.contains(where: { $0.id == sel }) { selection = nil }
        total = max(0, total - ok)
        var parts = ["\(ok) 件削除"]
        if fail > 0 { parts.append("\(fail) 件失敗") }
        showEditSummary(parts.joined(separator: " / "), kind: fail > 0 ? .warning : .success)
    }

    /// 詳細ペインの複数選択一括編集を開始（RW 必須・×中断トークン付き）。
    func startBatchEdit(ids: Set<Int>, patch: BookPatch) {
        guard canEdit, !ids.isEmpty else { return }
        editCancel?.cancel(); editTask?.cancel()
        let flag = CancelFlag(); editCancel = flag
        editTask = Task { [weak self] in await self?.applyRemotePatchMulti(ids: ids, patch: patch, cancel: flag) }
    }

    func cancelBatchEdit() { editCancel?.cancel(); editTask?.cancel() }

    /// 一律 patch を選択本へ per-book PATCH（replace）。進捗・中断・要約を出す。
    private func applyRemotePatchMulti(ids: Set<Int>, patch: BookPatch, cancel: CancelFlag) async {
        let list = Array(ids)
        guard !list.isEmpty else { return }
        // G12b-3b Task 1: batch 中は各 PATCH が誘発する SSE .bookChanged の自エコー reload が
        // この関数末尾の reload と競合し、transient 失敗で赤バナーが立つ（PATCH 自体は成功）ため抑止する。
        // レビュー指摘対応: startBatchEdit は旧 Task を await せずキャンセル→新 Task 起動するため、
        // 重複実行時に旧 batch の tail が抑止フラグを先にクリアしうる。参照カウントで直す。
        activeBatchCount += 1
        var didDecrementEarly = false
        defer { if !didDecrementEarly { activeBatchCount -= 1 } }
        let dto = Self.patchToDTO(patch)
        // G12b-3c S5: 適用前の一覧値から id ごとに逆 patch を用意しておき、実際に PATCH が
        // 成功した本の分だけ undo に積む（失敗した本は old==current のままなので undo 対象にしない）。
        let preInverses: [Int: BookPatchDTO] = Dictionary(uniqueKeysWithValues: list.compactMap { id in
            books.first(where: { $0.id == id }).map { (id, Self.inversePatch(applied: dto, old: $0)) }
        })
        errorText = nil
        var ok = 0, fail = 0, cancelled = false
        var appliedInverses: [(bookID: Int, patch: BookPatchDTO)] = []
        editProgress = (0, list.count)
        for (i, id) in list.enumerated() {
            if cancel.isCancelled { cancelled = true; break }
            do {
                _ = try await client.updateBook(libraryUUID: libraryUUID, bookID: id, patch: dto, libraryToken: libraryToken)
                ok += 1
                if let inv = preInverses[id] { appliedInverses.append((id, inv)) }
            } catch { fail += 1 }
            editProgress = (i + 1, list.count)
        }
        if !appliedInverses.isEmpty { pushUndo(.rePatch(appliedInverses)) }
        editProgress = nil
        await reload(clearFirst: false)   // 旧リストを保持したまま差し替え（空表示防止）
        if let id = selection { await selectBook(id) }   // 詳細ペインを最新化
        // batch 自前の reload でサーバ真値へ揃えたので、抑止していた自エコー分は捨ててよい。
        // ただし抑止中に他クライアント由来の変更（他ユーザー編集等）も pending に混在しうるため、
        // 最後の batch 終了時にのみ 1 回だけ flush して取りこぼしを回収する。
        // レビュー指摘対応: activeBatchCount はまだこの関数の defer で減算されていないため、
        // ここで == 1 はこの batch が最後（唯一のアクティブ batch）であることを意味する。
        // >1 なら他の batch がまだ走っており、その batch の tail が自分の flush を担当する。
        // 注意: flushLiveEvents() 自体が「activeBatchCount > 0 なら抑止」というガードを持つため、
        // ここでまだ 1（自分自身の分）が残ったまま呼ぶと即座にブロックされ flush が空振りする。
        // そのため、最後の batch と判定した時点で先に 0 まで減算してから flush を呼び、
        // defer 側は didDecrementEarly により二重減算を防ぐ（両ガードの整合を取る）。
        if activeBatchCount == 1 {
            activeBatchCount -= 1
            didDecrementEarly = true
            if pendingLiveReload || pendingLiveStampReload || pendingLiveSelectionRefresh != nil {
                await flushLiveEvents()
            }
        }
        var parts = ["\(ok) 件更新"]
        if fail > 0 { parts.append("\(fail) 件失敗") }
        if cancelled { parts.append("\(max(0, list.count - ok - fail)) 件中断") }
        showEditSummary(parts.joined(separator: " / "), kind: cancelled ? .cancelled : (fail > 0 ? .warning : .success))
    }

    // MARK: - G12b-2: 設定 / シェルフ / 重複

    /// お気に入りシェルフの ID（kind=="favorites"）。shelves 未取得時は nil（呼び出し側は
    /// 必要に応じて loadShelves() 済みであることを前提とする）。
    var favoritesShelfID: Int64? { shelves.first { $0.kind == "favorites" }?.id }

    /// G14: お気に入り所属 book ID（動的トグル判定用・ローカル favoritesBookIDs 同型）。
    var favoriteBookIDs: Set<Int> = []

    /// 選択集合（multiSelection 優先・無ければ selection）が空でなく全てお気に入りなら true。
    var allSelectedAreFavorites: Bool {
        let ids: Set<Int> = multiSelection.isEmpty ? Set(selection.map { [$0] } ?? []) : multiSelection
        return allAreFavorites(ids)
    }

    /// 指定 ids が空でなく全てお気に入りなら true（grid 右クリック等・選択外 ids にも使える汎用版）。
    /// G14 Task 5 レビュー修正: grid の .contextMenu は右クリックで選択を更新しないため、
    /// 選択外の本を右クリックした際は allSelectedAreFavorites（selection/multiSelection 由来）
    /// ではなくトグル対象の ids そのものを判定に使う必要がある。
    func allAreFavorites(_ ids: Set<Int>) -> Bool {
        !ids.isEmpty && ids.isSubset(of: favoriteBookIDs)
    }

    /// G14: お気に入りシェルフの所属 book ID 集合を取得する。favoritesShelfID 未解決時は空にする。
    /// per:500 上限。お気に入りが 500 超は overflow 判定が近似（実運用でまれ・許容）。
    func refreshFavoriteIDs() async {
        // Minor #4: favoriteBookIDs はお気に入り右クリックトグル（edit 専用導線）の判定にのみ使う。
        // read 接続ではトグルが出ないため取得しない（無駄な /books 呼び出しを避ける）。
        // tier 解決前（fail-closed .read）に loadShelves がスキップしても、reload の tier 解決後に
        // 再度呼ばれるため edit 接続では確実に読み込まれる。
        guard canEdit else { favoriteBookIDs = []; return }
        guard let favID = favoritesShelfID else { favoriteBookIDs = []; return }
        if let page = try? await client.fetchBooks(
            libraryUUID: libraryUUID, query: nil, sort: "dateAdded", ascending: false,
            page: 1, per: 500, libraryToken: libraryToken,
            scope: "favorites", scopeId: favID, recentDays: nil, fields: ["id"]) {
            favoriteBookIDs = Set(page.items.map { $0.id })
        }
    }

    /// 取り込み設定を取得（RW 不要・閲覧のみでも表示可）。失敗時は errorText を立て nil。
    func loadImportConfig() async -> ImportConfigDTO? {
        do {
            return try await client.getImportConfig(libraryUUID: libraryUUID, libraryToken: libraryToken)
        } catch {
            errorText = "取り込み設定の取得に失敗しました"
            return nil
        }
    }

    /// 取り込み設定を保存（RW 必須）。
    func saveImportConfig(_ dto: ImportConfigDTO) async {
        guard canEdit else { return }
        do {
            _ = try await client.putImportConfig(dto, libraryUUID: libraryUUID, libraryToken: libraryToken)
        } catch {
            errorText = "取り込み設定の保存に失敗しました"
        }
    }

    // MARK: - G12b-2c: 監視フォルダ設定

    /// 監視設定を取得（RW 必須ではないが本タブは canEdit で表示）。失敗時は errorText を立て nil。
    func loadWatchConfig() async -> WatchConfigDTO? {
        do { return try await client.fetchWatchConfig(libraryUUID: libraryUUID, libraryToken: libraryToken) }
        catch { errorText = "監視設定の取得に失敗しました"; return nil }
    }

    /// 監視設定を保存（RW 必須）。パス検証エラー(400)・権限(403)を文言で提示。成功で適用後 DTO を返す。
    @discardableResult
    func saveWatchConfig(_ dto: WatchConfigDTO) async -> WatchConfigDTO? {
        do { return try await client.putWatchConfig(dto, libraryUUID: libraryUUID, libraryToken: libraryToken) }
        catch let e as RemoteClientError {
            switch e {
            case .badRequest(let msg):
                // サーバは不正パスを含む文言（例「監視フォルダのパスが無効です: /no/such/dir」）を返すので、
                // 複数追加時にどのパスが不正かを提示できるよう、その文言をそのまま出す（A3 smoke 修正）。
                errorText = msg ?? "監視フォルダのパスが無効です（ホストに存在しないか、フォルダではありません）"
            case .forbidden: errorText = "編集権限がありません"
            default: errorText = "監視設定の保存に失敗しました"
            }
            return nil
        } catch { errorText = "監視設定の保存に失敗しました"; return nil }
    }

    /// 指定フォルダの既存ファイルも取り込む（admin 必須。baseline をクリアして再スキャン）。
    func importExisting(folderID: String) async {
        guard canDelete else { errorText = "管理者権限が必要です"; return }
        do { try await client.importExistingInWatchedFolder(folderID: folderID, libraryUUID: libraryUUID, libraryToken: libraryToken) }
        catch let e as RemoteClientError {
            errorText = { if case .forbidden = e { return "管理者権限が必要です" } else { return "既存取り込みの開始に失敗しました" } }()
        }
        catch { errorText = "既存取り込みの開始に失敗しました" }
    }

    // MARK: - G12b-3c: 命名プリセット集合（GET/PUT）

    /// プリセット集合を取得（RW 不要・admin ゲート表示側の責務）。失敗時は errorText を立て nil。
    func loadPresets() async -> PresetSetDTO? {
        do { return try await client.fetchPresets(libraryUUID: libraryUUID, libraryToken: libraryToken) }
        catch { errorText = "プリセットの取得に失敗しました"; return nil }
    }

    /// プリセット集合を保存（admin 必須）。成功で適用後 DTO を返す。
    @discardableResult
    func savePresets(_ dto: PresetSetDTO) async -> PresetSetDTO? {
        do { return try await client.putPresets(dto, libraryUUID: libraryUUID, libraryToken: libraryToken) }
        catch let e as RemoteClientError {
            errorText = { if case .forbidden = e { return "管理者権限が必要です" } else { return "プリセットの保存に失敗しました" } }()
            return nil
        } catch { errorText = "プリセットの保存に失敗しました"; return nil }
    }

    // MARK: - G12b-3a: 一般設定・保守・scan-now

    func loadGeneralSettings() async -> GeneralSettingsDTO? {
        do { return try await client.fetchGeneralSettings(libraryUUID: libraryUUID, libraryToken: libraryToken) }
        catch { errorText = "一般設定の取得に失敗しました"; return nil }
    }
    @discardableResult
    func saveGeneralSettings(_ dto: GeneralSettingsDTO) async -> GeneralSettingsDTO? {
        do {
            let saved = try await client.putGeneralSettings(dto, libraryUUID: libraryUUID, libraryToken: libraryToken)
            // G2: 表示名を再接続なしで反映（navigationTitle が state.libraryName を直接読むため即時更新）。
            // 空欄はバンドル名フォールバックの既存挙動を壊さないため libraryName を変更しない。
            if !saved.displayName.isEmpty { libraryName = saved.displayName }
            return saved
        }
        catch let e as RemoteClientError {
            errorText = { if case .forbidden = e { return "管理者権限が必要です" } else { return "一般設定の保存に失敗しました" } }()
            return nil
        } catch { errorText = "一般設定の保存に失敗しました"; return nil }
    }
    func runIntegrityCheck() async -> IntegrityCheckDTO? {
        do { return try await client.checkIntegrity(libraryUUID: libraryUUID, libraryToken: libraryToken) }
        catch let e as RemoteClientError {
            errorText = { if case .forbidden = e { return "管理者権限が必要です" } else { return "整合性チェックに失敗しました" } }()
            return nil
        } catch { errorText = "整合性チェックに失敗しました"; return nil }
    }
    @discardableResult
    func runBackupNow() async -> Bool {
        do { try await client.backupNow(libraryUUID: libraryUUID, libraryToken: libraryToken); return true }
        catch let e as RemoteClientError {
            errorText = { if case .forbidden = e { return "管理者権限が必要です" } else { return "バックアップに失敗しました" } }()
            return false
        } catch { errorText = "バックアップに失敗しました"; return false }
    }
    @discardableResult
    func runScanNow() async -> Bool {
        do { try await client.scanWatchedFoldersNow(libraryUUID: libraryUUID, libraryToken: libraryToken); return true }
        catch let e as RemoteClientError {
            errorText = { if case .forbidden = e { return "管理者権限が必要です" } else { return "スキャンの開始に失敗しました" } }()
            return false
        } catch { errorText = "スキャンの開始に失敗しました"; return false }
    }

    // MARK: - G12b-3b: メンテナンス（メタデータ補完・表紙圧縮）

    /// サーバは進捗を fire-and-forget Task で emit するため、まれに `.maintenanceProgress` が
    /// `.maintenanceFinished` の後に届くことがある（順序保証なし）。このゲートが false の間は
    /// progress を無視し、完了で clear 済みの maintenanceJob が遅延イベントで再び埋まって進捗バーが
    /// 止まって見える事故を防ぐ。@ObservationIgnored で View 再描画のトリガーにはしない（内部制御用）。
    @ObservationIgnored private var maintenanceActive = false

    func runCompleteMetadata() async {
        guard canDelete else { errorText = "管理者権限が必要です"; return }
        // M2: finished が 202 応答を追い越しても取りこぼさないよう、await の前に gate を立てる。
        maintenanceActive = true
        maintenanceJob = MaintenanceUIState(job: "complete-metadata", done: 0, total: 0)
        do {
            try await client.startCompleteMetadata(libraryUUID: libraryUUID, libraryToken: libraryToken)
        } catch let e as RemoteClientError {
            maintenanceActive = false; maintenanceJob = nil   // 起動失敗 → gate を戻す
            errorText = Self.maintenanceMessage(for: e)
        } catch {
            maintenanceActive = false; maintenanceJob = nil
            errorText = "メタデータ補完の開始に失敗しました"
        }
    }
    func runCompressCovers() async {
        guard canDelete else { errorText = "管理者権限が必要です"; return }
        // M2: finished が 202 応答を追い越しても取りこぼさないよう、await の前に gate を立てる。
        maintenanceActive = true
        maintenanceJob = MaintenanceUIState(job: "compress-covers", done: 0, total: 0)
        do {
            try await client.startCompressCovers(libraryUUID: libraryUUID, libraryToken: libraryToken)
        } catch let e as RemoteClientError {
            maintenanceActive = false; maintenanceJob = nil   // 起動失敗 → gate を戻す
            errorText = Self.maintenanceMessage(for: e)
        } catch {
            maintenanceActive = false; maintenanceJob = nil
            errorText = "表紙圧縮の開始に失敗しました"
        }
    }
    func cancelMaintenance() async {
        do {
            try await client.cancelMaintenance(libraryUUID: libraryUUID, libraryToken: libraryToken)
            // I1: 楽観的に UI を解除する。ジョブがサーバ側でまだ走っていても、その finish が出す
            // structureChanged で一覧は更新される。finished を取りこぼしても手動で復帰できる escape hatch。
            maintenanceActive = false
            maintenanceJob = nil
        } catch {
            // 中断要求の失敗は握る（finished が来れば解決）。UI はそのまま。
        }
    }

    private static func maintenanceMessage(for e: RemoteClientError) -> String {
        if case .forbidden = e { return "管理者権限が必要です" }
        if case .server(let code) = e, code == 409 { return "別のメンテナンスが実行中です" }
        return "メンテナンスの開始に失敗しました"
    }

    /// ライブラリロックを設定（admin 必須）。
    func setLibraryLock(password: String) async {
        guard canDelete else { return }   // lock=admin
        do {
            try await client.setLock(password: password, libraryUUID: libraryUUID, libraryToken: libraryToken)
            showEditSummary("ロックを設定しました", kind: .success)
        } catch {
            errorText = "ロックの設定に失敗しました"
        }
    }

    /// ライブラリロックを解除（admin 必須）。
    func clearLibraryLock() async {
        guard canDelete else { return }
        do {
            try await client.clearLock(libraryUUID: libraryUUID, libraryToken: libraryToken)
            showEditSummary("ロックを解除しました", kind: .success)
        } catch {
            errorText = "ロックの解除に失敗しました"
        }
    }

    /// 選択本を指定シェルフへ追加（RW 必須）。
    func addSelectionToShelf(_ shelfID: Int64, ids: Set<Int>) async {
        guard canEdit, !ids.isEmpty else { return }
        do {
            try await client.addBooksToShelf(shelfID: shelfID, bookIDs: Array(ids), libraryUUID: libraryUUID, libraryToken: libraryToken)
            showEditSummary("\(ids.count) 件をシェルフに追加", kind: .success)
        } catch {
            errorText = "シェルフへの追加に失敗しました"
        }
    }

    /// 選択本を指定シェルフから除外（RW 必須）。現在シェルフ表示中なら一覧から消えるよう reload する。
    func removeSelectionFromShelf(_ shelfID: Int64, ids: Set<Int>) async {
        guard canEdit, !ids.isEmpty else { return }
        do {
            try await client.removeBooksFromShelf(shelfID: shelfID, bookIDs: Array(ids), libraryUUID: libraryUUID, libraryToken: libraryToken)
            await reload(clearFirst: false)
            showEditSummary("\(ids.count) 件をシェルフから除外", kind: .success)
        } catch {
            errorText = "シェルフからの除外に失敗しました"
        }
    }

    /// お気に入りシェルフへの追加/除外を切り替える（RW 必須）。favoritesShelfID が未解決なら
    /// errorText を出して何もしない（呼び出し側は事前に loadShelves() 済みであること）。
    func toggleFavorite(ids: Set<Int>, add: Bool) async {
        guard canEdit, !ids.isEmpty, let fid = favoritesShelfID else {
            if favoritesShelfID == nil { errorText = "お気に入りシェルフが見つかりません" }
            return
        }
        if add { await addSelectionToShelf(fid, ids: ids) } else { await removeSelectionFromShelf(fid, ids: ids) }
        // G14 fu: サイドバーのお気に入り件数は ShelfDTO.bookCount（listShelves 由来）なので、
        // loadShelves で shelves を取り直さないと更新されない（smoke バグ1）。loadShelves は
        // refreshCounts / refreshFavoriteIDs（動的トグル判定の再取得）も内包する。
        await loadShelves()
        // loadShelves 内の再取得がサーバ反映ラグ/キャッシュで所属を取りこぼしても、トグル直後の
        // ラベルが確実に正しくなるよう favoriteBookIDs を楽観更新（source of truth を上書きしない
        // 加減算・最後に適用して勝たせる）。smoke バグ2 の値側の担保。
        if add { favoriteBookIDs.formUnion(ids) } else { favoriteBookIDs.subtract(ids) }
    }

    /// 重複スキャンを実行（RW 必須）。失敗時は errorText を立て nil。
    func scanDuplicatesNow() async -> DuplicateScanReply? {
        guard canEdit else { return nil }
        do {
            return try await client.scanDuplicates(libraryUUID: libraryUUID, libraryToken: libraryToken)
        } catch {
            errorText = "重複スキャンに失敗しました"
            return nil
        }
    }

    // MARK: - 4.2c-6a: スタンプ（サーバ定義同期＋一括適用）

    /// サーバ常駐のスタンプ定義キャッシュ（dbColumn→値配列）。library open 時に GET、編集で PUT。
    var stampDefinitions: [String: [String]] = [:]

    /// サーバからスタンプ定義を取得してキャッシュする。
    func loadStampDefinitions() async {
        stampDefinitions = (try? await client.fetchStampDefinitions(
            libraryUUID: libraryUUID, libraryToken: libraryToken)) ?? [:]
    }

    // MARK: - 4.2c-9: レート（R 可・共有評価）

    /// 指定本のレートを更新（R 可・共有評価）。成功後に一覧/詳細を更新。失敗は errorText に出す。
    func setRating(ids: [Int], _ stars: Int) {
        guard !ids.isEmpty else { return }
        Task {
            var failed = false
            for id in ids {
                do {
                    try await client.setRating(libraryUUID: libraryUUID, bookID: id, rating: stars, libraryToken: libraryToken)
                } catch {
                    failed = true
                }
            }
            await reload(clearFirst: false)
            if let sel = selection, ids.contains(sel) { await selectBook(sel) }
            if failed { errorText = "レートの更新に失敗しました" }
        }
    }

    /// メニュー(⌘0–5)用。選択集合（multiSelection 優先・無ければ selection）へレート適用。
    func setRatingForSelection(_ stars: Int) {
        let ids: [Int] = multiSelection.isEmpty ? (selection.map { [$0] } ?? []) : Array(multiSelection)
        setRating(ids: ids, stars)
    }

    /// grid 右クリック等・ids を明示指定して bookType を適用（G12b-1 whole-branch fix）。
    /// ids.count == 1 なら単体 PATCH、複数なら一括編集（進捗/中断付き）。
    func setBookType(ids: Set<Int>, _ type: Int) {
        guard canEdit else { return }
        guard !ids.isEmpty else { return }
        if ids.count == 1, let only = ids.first {
            Task { await applyRemotePatch(bookID: only, patch: BookPatch(bookType: type)) }
        } else {
            startBatchEdit(ids: ids, patch: BookPatch(bookType: type))
        }
    }

    /// 右クリック「種類」submenu 用。選択集合（multiSelection 優先・無ければ selection）へ bookType 適用。
    func setBookTypeForSelection(_ type: Int) {
        let ids: Set<Int> = multiSelection.isEmpty ? Set(selection.map { [$0] } ?? []) : multiSelection
        setBookType(ids: ids, type)
    }

    /// 指定本の未読(unseen)を更新（R 可・共有閲覧状態）。失敗は errorText に出す。
    func setUnseen(ids: [Int], _ value: Bool) {
        guard !ids.isEmpty else { return }
        Task {
            var failed = false
            for id in ids {
                do {
                    try await client.setUnseen(libraryUUID: libraryUUID, bookID: id, unseen: value, libraryToken: libraryToken)
                } catch {
                    failed = true
                }
            }
            await reload(clearFirst: false)
            if let sel = selection, ids.contains(sel) { await selectBook(sel) }
            if failed { errorText = "未読状態の更新に失敗しました" }
        }
    }

    /// grid 右クリック等・ids を明示指定して先頭本の unseen を反転して ids 全体へ適用（G12b-1 whole-branch fix）。
    func toggleUnread(ids: Set<Int>) {
        guard !ids.isEmpty else { return }
        let first = books.first(where: { ids.contains($0.id) })
        let newValue = first.map { !$0.unseen } ?? true
        setUnseen(ids: Array(ids), newValue)
    }

    /// メニュー(⌘T)用。選択集合の先頭本の unseen を反転して全選択へ適用（ローカル同等）。
    func toggleUnreadForSelection() {
        let ids: Set<Int> = multiSelection.isEmpty ? Set(selection.map { [$0] } ?? []) : multiSelection
        toggleUnread(ids: ids)
    }

    // MARK: - 4.2c-8: ラベル同期

    /// サーバのラベルカスタマイズを取得（失敗時は空）。View が settings の override にセットする。
    func fetchLabels() async -> LabelSettingsDTO {
        (try? await client.fetchLabelSettings(libraryUUID: libraryUUID, libraryToken: libraryToken))
            ?? LabelSettingsDTO(customFieldLabels: [:], customBookTypeLabels: [:])
    }

    /// ラベルを保存（RW）。成功で保存後の DTO を返す。失敗は throws（呼び出し側でエラー表示）。
    func saveLabels(customFieldLabels: [String: String], customBookTypeLabels: [String: String]) async throws -> LabelSettingsDTO {
        try await client.putLabelSettings(
            libraryUUID: libraryUUID,
            customFieldLabels: customFieldLabels,
            customBookTypeLabels: customBookTypeLabels,
            libraryToken: libraryToken)
    }

    /// 選択本へスタンプ値を append 適用（サーバ一括 API・単一リクエスト）。
    func applyStamp(field: StampField, value: String) {
        guard canEdit, !multiSelection.isEmpty else { return }
        let ids = Array(multiSelection)
        Task {
            _ = try? await client.applyStamp(libraryUUID: libraryUUID, field: field.dbColumn,
                                             value: value, clear: false, bookIDs: ids, libraryToken: libraryToken)
            await reload(clearFirst: false)
            if let id = selection { await selectBook(id) }
        }
    }

    /// 選択本の当該スタンプフィールドを消去（サーバ一括 API）。
    func clearStamp(field: StampField) {
        guard canEdit, !multiSelection.isEmpty else { return }
        let ids = Array(multiSelection)
        Task {
            _ = try? await client.applyStamp(libraryUUID: libraryUUID, field: field.dbColumn,
                                             value: nil, clear: true, bookIDs: ids, libraryToken: libraryToken)
            await reload(clearFirst: false)
            if let id = selection { await selectBook(id) }
        }
    }

    /// スタンプ定義を追加（重複 skip）→ サーバ PUT。選択があれば併せて適用。RW 必須。
    func addStampDefinition(field: StampField, value: String) {
        guard canEdit else { return }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var defs = stampDefinitions
        var fieldDefs = defs[field.dbColumn] ?? []
        if !fieldDefs.contains(trimmed) {
            fieldDefs.append(trimmed); defs[field.dbColumn] = fieldDefs; stampDefinitions = defs
        }
        let snapshot = stampDefinitions
        Task {
            if let saved = try? await client.putStampDefinitions(snapshot, libraryUUID: libraryUUID, libraryToken: libraryToken) {
                stampDefinitions = saved
            }
        }
        if !multiSelection.isEmpty { applyStamp(field: field, value: trimmed) }
    }

    // MARK: - 4.2c-6b: リモート表紙/クロップ編集

    /// 表紙候補（アーカイブのページ名一覧）＋現 coverImageName。
    func coverCandidates(bookID: Int) async -> (entries: [String], current: String?) {
        (try? await client.fetchCoverCandidates(libraryUUID: libraryUUID, bookID: bookID, libraryToken: libraryToken)) ?? ([], nil)
    }

    /// 選択ページのプレビュー画像（クロップ編集用・maxw=800）。
    func entryImage(bookID: Int, name: String) async -> NSImage? {
        guard let data = try? await client.fetchEntryImage(
            libraryUUID: libraryUUID, bookID: bookID, name: name, maxw: 800, libraryToken: libraryToken) else { return nil }
        return NSImage(data: data)
    }

    /// 表紙更新（coverImageName/coverCropRect）。成功後は表紙キャッシュ無効化＋再読込で反映。
    func setRemoteCover(bookID: Int, coverImageName: String?, setName: Bool, cropJSON: String?, setCrop: Bool) async {
        do {
            _ = try await client.setRemoteCover(
                libraryUUID: libraryUUID, bookID: bookID,
                coverImageName: coverImageName, setName: setName,
                coverCropRectJSON: cropJSON, setCrop: setCrop, libraryToken: libraryToken)
            await coverCache.invalidate(libraryUUID: libraryUUID, bookID: bookID)
            // 表紙差し替えは表紙キャッシュのみ無効化（本文ページの L2 キャッシュは温存）。
            await RemotePageCache.shared.deleteCovers(serverID: serverID, libraryUUID: libraryUUID, bookID: bookID)
            // G4c: reload 完了後に bump する（L1 が版付きキーのため、reload の suspend 中に旧
            // coverVersion で描画が走ると版なし invalidate が空振りした stale エントリを引く窓があった）。
            await reload(clearFirst: false)
            downloadedVersion &+= 1   // grid/list セルの表紙再評価トリガ
            coverVersion &+= 1        // 詳細ペイン表紙の再描画/再取得トリガ（メタ不変でも）
            if selection == bookID { await selectBook(bookID) }
        } catch {
            if case RemoteClientError.forbidden = error { errorText = "編集権限がありません" }
            else { errorText = "表紙の更新に失敗しました" }
        }
    }

    /// G4b: 外部画像を表紙にアップロード（リモート・RW）。成功で表紙キャッシュ無効化＋リロード。
    func setRemoteExternalCover(bookID: Int, imageData: Data, cropJSON: String?) async {
        do {
            _ = try await client.setCoverImage(
                libraryUUID: libraryUUID, bookID: bookID,
                imageData: imageData, cropJSON: cropJSON, libraryToken: libraryToken)
            await coverCache.invalidate(libraryUUID: libraryUUID, bookID: bookID)
            await RemotePageCache.shared.deleteCovers(serverID: serverID, libraryUUID: libraryUUID, bookID: bookID)
            // G4c: reload 完了後に bump する（L1 が版付きキーのため、reload の suspend 中に旧
            // coverVersion で描画が走ると版なし invalidate が空振りした stale エントリを引く窓があった）。
            await reload(clearFirst: false)
            downloadedVersion &+= 1
            coverVersion &+= 1        // 詳細ペイン表紙の再描画/再取得トリガ（@external 差し替えでメタ不変でも）
            if selection == bookID { await selectBook(bookID) }
        } catch {
            if case RemoteClientError.forbidden = error { errorText = "編集権限がありません" }
            else if case RemoteClientError.server(413) = error { errorText = "画像が大きすぎます（30MB まで）" }
            else { errorText = "表紙の更新に失敗しました" }
        }
    }

    /// スタンプ定義を削除 → サーバ PUT。ショートカット定義のみ除去（本メタは不変）。RW 必須。
    func deleteStampDefinition(field: StampField, value: String) {
        guard canEdit else { return }
        var defs = stampDefinitions
        if var fieldDefs = defs[field.dbColumn], let i = fieldDefs.firstIndex(of: value) {
            fieldDefs.remove(at: i); defs[field.dbColumn] = fieldDefs; stampDefinitions = defs
        }
        let snapshot = stampDefinitions
        Task {
            if let saved = try? await client.putStampDefinitions(snapshot, libraryUUID: libraryUUID, libraryToken: libraryToken) {
                stampDefinitions = saved
            }
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
        // 4.2c-6a 修正: 複数選択時は選択中の一覧 DTO を BookRow に写して返す。これにより
        // DetailPaneView が複数選択編集パス（onApplyPatchMulti）を発火する（単一 detail だけだと
        // 一括編集が起動せず反映されなかった＝smoke A1/A2 NG の根因）。keywordC は list wire
        // 非対応のため複数選択編集時の現在値表示は nil（適用自体は全フィールド可能）。
        if multiSelection.count >= 2 {
            let rows = books.filter { multiSelection.contains($0.id) }.map { Self.detailRow(from: $0) }
            if !rows.isEmpty { return rows }
        }
        guard let d = detail else { return [] }
        return [Self.mapDetail(d)]
    }

    /// 一覧 DTO → 一括編集用 BookRow（表示可能フィールドを写す）。
    private static func detailRow(from dto: BookListItemDTO) -> BookRow {
        BookRow(
            id: dto.id, title: dto.title, author: dto.author, genre: dto.genre, path: nil,
            dateAdded: dto.dateAdded, playDate: dto.lastReadAt, bookType: dto.bookType, fileType: 0,
            pages: dto.pages, rating: dto.rating, unseen: dto.unseen,
            keywordA: dto.keywordA, keywordB: dto.keywordB, keywordC: dto.keywordC, neta: dto.neta,
            memo: dto.memo, series: dto.series, volume: dto.volume,
            coverImageName: nil, coverCropRect: nil, pageDirection: nil,
            contentHash: nil, fileSize: nil, fileMtime: nil)
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
        let version = coverVersionByID[bookID]   // G4c: 版鍵
        let key = RemoteCoverCache.Key(libraryUUID: uuid, bookID: bookID, maxWidth: 600, version: version)
        let data = try? await coverCache.data(for: key) {
            try await client.coverData(libraryUUID: uuid, bookID: bookID, maxw: 600, libraryToken: token)
        }
        return data.flatMap { NSImage(data: $0) }
    }

    // MARK: - Viewer

    /// 指定 bookID を開く。読み込み済み一覧に無ければ detail を取得して合成 DTO で開く（⌘⇧O resume 用）。
    func openBookByID(_ id: Int, resumeDirect: Bool) async {
        if let dto = books.first(where: { $0.id == id }) {
            openViewer(book: dto, resumeDirect: resumeDirect)
            return
        }
        guard let d = try? await client.bookDetail(libraryUUID: libraryUUID, bookID: id, libraryToken: libraryToken) else {
            errorText = "本を開けませんでした"
            return
        }
        let dto = BookListItemDTO(
            id: d.id, title: d.title, author: d.author, series: d.series, volume: d.volume,
            rating: d.rating, unseen: d.unseen, bookType: d.bookType, pages: d.pages,
            lastPage: d.lastPage, lastReadAt: nil, dateAdded: d.dateAdded, hasCover: false, coverVersion: nil)
        openViewer(book: dto, resumeDirect: resumeDirect)
    }

    /// リモート本を内蔵ビューワで開く。BookContent は RemoteBookContent。
    func openViewer(book: BookListItemDTO, resumeDirect: Bool = false) {
        // 直前の失敗バナー（「本を開けませんでした」等）をクリアする。これが無いと、紐付けの
        // 切れた本で失敗した後に別の本を正常に開いても警告が残り続ける（smoke 4.2b-4 指摘）。
        errorText = nil
        // 未読即時反映: 開いた瞬間にメモリ一覧の unseen を落とす（ローカルの「開いたら既読」に合わせる）。
        if let idx = books.firstIndex(where: { $0.id == book.id }), books[idx].unseen {
            books[idx] = books[idx].withUnseen(false)
        }
        // Phase 4.2c-2: 「最後に開いた本」を記録する（リモート）。
        LastReadTracker.shared.record(.remote(
            serverID: serverID, serverURL: client.baseURL.absoluteString,
            libraryUUID: libraryUUID, libraryName: libraryName,
            bookID: book.id, title: book.title, locked: locked))
        // 4.2c-3 (自由記載#1): DL 済みの本はローカルファイルから読む（ページ画像の
        // ネットワーク取得を避け負荷削減）。進捗はサーバへ POST 継続、多段巻送りの次巻は
        // 従来どおりリモート解決（簡易実装）。ローカルが壊れている等は失敗時にリモートへフォールバック。
        let downloaded = offlineStore.all().first {
            $0.serverID == serverID && $0.libraryUUID == libraryUUID && $0.detail.id == book.id
        }
        let content: BookContent
        let row: BookRow
        let sourceLabel: String
        let readingOffline: Bool
        // G3a: 可視保護用に、リモート閲覧時の RemoteBookContent を静的型のまま保持する
        // （content は BookContent 抽象のため。オフライン読み出し時は nil）。
        var remoteContent: RemoteBookContent?
        if let dl = downloaded {
            let offlineRow = offlineBookRow(dl, fileURL: offlineStore.fileURL(for: dl))
            if let made = try? BookContentFactory.make(for: offlineRow) {
                content = made
                row = offlineRow
                sourceLabel = "オフライン"
                readingOffline = true
            } else {
                let made = RemoteBookContent(
                    client: client, serverID: serverID, libraryUUID: libraryUUID, bookID: book.id,
                    libraryToken: libraryToken, maxWidth: 1600)
                content = made
                remoteContent = made
                row = Self.makeBookRow(from: book)
                sourceLabel = "リモート"
                readingOffline = false
            }
        } else {
            let made = RemoteBookContent(
                client: client, serverID: serverID, libraryUUID: libraryUUID, bookID: book.id,
                libraryToken: libraryToken, maxWidth: 1600)
            content = made
            remoteContent = made
            row = Self.makeBookRow(from: book)
            sourceLabel = "リモート"
            readingOffline = false
        }
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
            // 4.2c-5: DL済みは offline の lastPage も考慮し max で続きを解決（前進読み前提）。
            let resolvedLastPage = resolveResumePage(server: book.lastPage, offline: downloaded?.lastPage)
            // G3b: 起動時保護は controller の初回 recomputePrefetch()→reportActiveWindow が担う
            // （旧 setProtected 呼び出しは Task 2 で owner 必須になったため削除）。
            // 開いた時点で既読をサーバ確定（/progress は R でも許可）。offline 先行時にサーバを
            // 巻き戻さないよう、解決後ページで POST する。
            Task { try? await self.client.postProgress(libraryUUID: self.libraryUUID, bookID: book.id, page: resolvedLastPage, libraryToken: self.libraryToken) }
            // リモートでは per-book の永続見開き状態を持たないため、グローバル既定で開く。
            let initialState = ResolvedViewerState(
                spreadEnabled: ViewerSettings.shared.spreadByDefault,
                coverOffset: true,
                lastPage: resolvedLastPage,
                overrides: [:]
            )
            // 一覧 DTO には pageDirection が無いため、サーバの本詳細から実際の読む方向を取得する。
            // これが無いと、方向を変更してもビューアを開き直すたびにグローバル既定へ戻る（smoke G3）。
            // オフライン読み出し時は offline detail（row.pageDirection）を使い、無駄なネットワーク取得を避ける。
            let serverDir: PageDirection?
            if readingOffline {
                serverDir = row.pageDirection
            } else {
                let serverDetail = try? await self.client.bookDetail(
                    libraryUUID: self.libraryUUID, bookID: book.id, libraryToken: self.libraryToken)
                serverDir = serverDetail.flatMap { d in
                    d.pageDirection == "rtl" ? .rightToLeft
                        : (d.pageDirection == "ltr" ? .leftToRight : nil)
                }
            }
            let options = ViewerOptions(
                pageDirection: serverDir ?? row.pageDirection ?? ViewerSettings.shared.pageDirection,
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
                    // Phase 4.2c-2: 巻スワップ後も「最後に開いた本」を現在の巻に更新する（リモート）。
                    LastReadTracker.shared.record(.remote(
                        serverID: self.serverID, serverURL: self.client.baseURL.absoluteString,
                        libraryUUID: self.libraryUUID, libraryName: self.libraryName,
                        bookID: b.id, title: b.title, locked: self.locked))
                    Task {
                        try? await self.client.postProgress(
                            libraryUUID: self.libraryUUID, bookID: b.id,
                            page: lastPage, libraryToken: self.libraryToken)
                    }
                    // 4.2c-5: DL済み(オフライン読み出し)はオフラインストアの lastPage も更新し、
                    // オフラインビューアと続きを一致させる。未DLはエントリが無く no-op。
                    if readingOffline {
                        self.offlineStore.updateLastPage(
                            serverID: self.serverID, libraryUUID: self.libraryUUID,
                            bookID: b.id, page: lastPage)
                    }
                    // v4 修正: メモリ上の一覧 DTO の lastPage も更新する。これをしないと
                    // 一覧を再取得するまで stale な lastPage で開いてしまい、リモートで
                    // 開き直すと毎回元のページに戻る（サーバには POST 済でも一覧側が古い）。
                    // Phase 4.2c-2 (Bug 2): スワップした巻の unseen マーカーも消す。
                    if let i = self.books.firstIndex(where: { $0.id == b.id }) {
                        self.books[i] = self.books[i].withLastPage(lastPage).withUnseen(false).withLastReadAt(Date())
                    }
                },
                // ページレイアウト override はリモートでは永続化しない（no-op）。
                persistPageOverride: { _, _, _ in },
                onClose: { [weak self] in self?.viewerController = nil },
                suppressResumeDialog: resumeDirect,
                sourceLabel: sourceLabel
            )
            // G3b: リモート閲覧では RemotePrefetchContext を注入し、可視ページの保護を
            // ページ移動に追従させる（各 controller が別 owner=union 保護）。
            if remoteContent != nil {
                let owner = ObjectIdentifier(controller)
                let sID = serverID, luid = libraryUUID
                // 保護更新を発行順に直列化（fire-and-forget の到達順不定を排除・I2）。
                // 更新は MainActor（recompute/close）からのみ発行されるため @unchecked Sendable で安全。
                let chain = ProtectionChain()
                controller.remotePrefetch = RemotePrefetchContext(
                    reportActiveWindow: { pages, bid in
                        // bid はビューアが現在 content から渡す（巻スワップ追従・C1）。オフライン巻なら nil→no-op。
                        guard let bid else { return }
                        let keys = Set(pages.map {
                            RemotePageCache.Key(serverID: sID, libraryUUID: luid, bookID: bid, kind: .page, page: $0, maxw: 1600)
                        })
                        let prev = chain.task
                        chain.task = Task { await prev?.value; await RemotePageCache.shared.setProtected(keys, owner: owner) }
                    },
                    clearProtection: {
                        let prev = chain.task
                        chain.task = Task { await prev?.value; await RemotePageCache.shared.clearProtected(owner: owner) }
                    },
                    tier3Enabled: { RemoteCacheSettings.wholeBookPrefetch() },
                    cachedPages: { bid in
                        await RemotePageCache.shared.cachedPages(serverID: sID, libraryUUID: luid, bookID: bid, maxw: 1600)
                    }
                )
            }
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
            // 詳細ペインへ即反映するため、選択中の本なら詳細を再取得する。
            // これが無いと PageDirectionPicker が古い値のままで「編集できない」ように見える。
            if selection == bookID {
                detail = try? await client.bookDetail(libraryUUID: libraryUUID, bookID: bookID, libraryToken: libraryToken)
            }
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
        let state = ResolvedViewerState(
            spreadEnabled: ViewerSettings.shared.spreadByDefault,
            coverOffset: true,
            lastPage: max(0, dto.lastPage ?? 0),
            overrides: [:]
        )
        // 4.2c-3 (自由記載#1/#3): 次巻が DL 済みならオフラインから読む（負荷削減）＋ソースラベルを
        // 巻ごとに付け替える。未 DL はリモート解決のまま「リモート」バッジに更新する。
        if let dl = offlineStore.all().first(where: {
            $0.serverID == serverID && $0.libraryUUID == libraryUUID && $0.detail.id == dto.id
        }), let made = try? BookContentFactory.make(for: offlineBookRow(dl, fileURL: offlineStore.fileURL(for: dl))) {
            let row = offlineBookRow(dl, fileURL: offlineStore.fileURL(for: dl))
            return NextVolume(content: made, book: row, state: state, sourceLabel: "オフライン")
        }
        let content = RemoteBookContent(
            client: client, serverID: serverID, libraryUUID: libraryUUID,
            bookID: dto.id, libraryToken: libraryToken, maxWidth: 1600)
        let row = Self.makeBookRow(from: dto)
        return NextVolume(content: content, book: row, state: state, sourceLabel: "リモート")
    }

    // MARK: - G8a: リモート即時同期（SSE 購読・反映・再接続）

    /// G8a: settingsChanged 受信ごとに増分。ラベル override は View 所有（settings.remote*Override）のため
    /// state から直接触れない。View が `.onChange(of: settingsChangeToken)` で fetchLabels を再実行する。
    var settingsChangeToken = 0

    /// G8a Design 1: /events を購読し反映する。切断/一時障害は指数バックオフ再接続＋再接続時に
    /// reload(clearFirst:false) で取りこぼし回収。認証失効（401/403）は errorText に提示し再接続せず停止。
    /// View の `.task {}` から `await` で呼ぶ（view 消滅で .task がキャンセル→ループ終了）。
    func runLiveSync() async {
        var backoff: Duration = .seconds(1)              // 1s→2s→4s…→最大30s（エラー時のみ増加）
        let maxBackoff: Duration = .seconds(5)   // G14: 30s→5s。接続エラー赤字の自動復帰を最大~5秒に短縮。
        while !Task.isCancelled {
            do {
                // throwing 購読。events() は非200/URLError を型付き RemoteClientError で終端 throw、
                // サーバ正常クローズは throw なし finish、キャンセルは静音 finish。
                for try await event in client.events(libraryToken: libraryToken) {
                    handleLiveEvent(event)
                }
                if Task.isCancelled { break }
                backoff = .seconds(1)                    // 正常クローズ＝接続は成立していた→リセット
                await liveReload()                       // 取りこぼし回収（位置保持）
                try? await Task.sleep(for: backoff)
            } catch let e as RemoteClientError {
                if Task.isCancelled { break }
                switch e {
                case .unauthorized, .forbidden:
                    errorText = Self.message(for: e)     // 認証失効を提示（unlock 導線は locked/unlock UI が担う）
                    return                               // 再接続しない
                default:
                    await liveReload()                   // .offline/.timeout/.server 等は一時障害（位置保持）
                    try? await Task.sleep(for: backoff)
                    backoff = min(backoff * 2, maxBackoff)
                }
            } catch {
                if Task.isCancelled { break }
                await liveReload()                       // 位置保持
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, maxBackoff)
            }
        }
    }

    /// G8a whole-branch-review Important #2: SSE イベントは実反映せず pending フラグに畳み込む。ホストの
    /// 一括編集（applyPatch(bookIDs:)）は N 件の .bookChanged を連続送出するため、~200ms のデバウンス窓で
    /// 1 回の reload/選択再取得/スタンプ再読込に集約し、大量一括編集時の reload storm（体感カクつき）を防ぐ。
    private func handleLiveEvent(_ event: LiveEvent) {
        // G13: .connected はクライアント合成イベントで対象ライブラリを持たない（library == ""）ため、
        // 他イベントと違い library スコープ guard の対象外にする（誤って早期 return されると reload が発火しない）。
        if case .connected = event {
        } else {
            guard event.library == libraryUUID else { return }   // scope で絞られるが念のため
        }
        switch event {
        case .connected:
            // G13: SSE 接続（再接続含む）確立時に一覧を再取得。reload 冒頭で errorText=nil、
            // 成功で赤字が消える（サーバ再起動→復帰後の残留を解消）。取りこぼしも回収。
            // Minor #3: 切断中に他クライアントで本/お気に入りが増減している可能性があるため、
            // 再接続時にサイドバー件数とお気に入り判定も更新する（favoriteBookIDs は canEdit gate 済み）。
            Task { await liveReload() }                  // 位置保持（reconnect で先頭に戻さない）
            Task { await refreshCounts() }
            Task { await refreshFavoriteIDs() }
        case .bookChanged(_, let bookID):
            // setRating/setUnseen と同一の反映イディオム（単一本 GET は無い・progress 非 publish で低頻度）。
            pendingLiveReload = true
            if selection == bookID { pendingLiveSelectionRefresh = bookID }
        case .structureChanged:
            pendingLiveReload = true
            Task { await refreshCounts() }   // G14: 本の追加/削除で総数が変わるためサイドバー件数も更新
            // Minor #2: 本の追加/削除・お気に入りシェルフ所属変更で favoriteBookIDs が stale になり、
            // お気に入りトグルのラベル（追加/削除）がずれるため再取得する（canEdit gate 済み）。
            Task { await refreshFavoriteIDs() }
        case .settingsChanged:
            pendingLiveStampReload = true
        case .maintenanceProgress(_, let job, let done, let total):
            // maintenanceActive ゲート: サーバは progress を fire-and-forget Task で emit するため、
            // まれに finished の後に届く（順序保証なし）。ゲートが false（未実行 or 完了済み）の間は無視し、
            // 完了で clear 済みの maintenanceJob が遅延イベントで再び埋まる事故（進捗バーが止まって見える）を防ぐ。
            if maintenanceActive {
                maintenanceJob = MaintenanceUIState(job: job, done: done, total: total)
            }
        case .maintenanceFinished(_, _, let outcome, let count):
            maintenanceActive = false
            maintenanceJob = nil
            switch outcome {
            case "cancelled": maintenanceResult = "中断しました（\(count) 件処理済み）"
            case "failed":    maintenanceResult = "メンテナンスに失敗しました"
            default:          maintenanceResult = "\(count) 件を更新しました"
            }
            // 完了時の structureChanged は別途届き reload を誘発する（表紙更新）。progress/finished 自体は
            // reload を誘発しない（進捗 UI のみ）。
        }
        scheduleLiveFlush()
    }

    private var pendingLiveReload = false
    private var pendingLiveStampReload = false
    private var pendingLiveSelectionRefresh: Int?
    private var liveFlushTask: Task<Void, Never>?
    /// G12b-3b Task 1: 一括編集（applyRemotePatchMulti）実行中は SSE 自エコーによる reload を抑止する。
    /// pending フラグ自体は落とさず、batch 終了後の 1 回の flush でまとめて反映する（他タスク未使用）。
    /// レビュー指摘対応: startBatchEdit が旧 batch を await せず新 Task を起動しうるため（重複実行）、
    /// bool ではなく参照カウントで管理し、最後の batch が終わるまで抑止を継続する（reentrant）。
    @ObservationIgnored private var activeBatchCount = 0

    /// バーストを ~200ms 窓で 1 回に集約。イベントごとに再スケジュールし、静止後に flush する。
    private func scheduleLiveFlush() {
        liveFlushTask?.cancel()
        liveFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await self?.flushLiveEvents()
        }
    }

    private func flushLiveEvents() async {
        // G12b-3b Task 1: batch 実行中は自エコー reload を抑止（batch 末尾で自前 reload するため冗長かつ有害）。
        // pending は落とさず、batch 終了後の flush で 1 回だけ反映する。
        if activeBatchCount > 0 { return }
        let doReload = pendingLiveReload
        let doStamps = pendingLiveStampReload
        let sel = pendingLiveSelectionRefresh
        pendingLiveReload = false
        pendingLiveStampReload = false
        pendingLiveSelectionRefresh = nil
        if doReload { await liveReload() }   // .structureChanged/.bookChanged 反映も位置保持
        if let sel, selection == sel { await selectBook(sel) }
        if doStamps {
            await loadStampDefinitions()                 // スタンプ定義（observable）を即時反映
            settingsChangeToken &+= 1                    // View にラベル override 再取得を促す
        }
    }

    // MARK: - Error messages

    static func message(for error: RemoteClientError) -> String {
        switch error {
        case .offline: return "サーバに接続できません（ネットワーク/アドレスを確認）"
        case .timeout: return "接続がタイムアウトしました"
        case .unauthorized: return "トークンが無効です"
        case .forbidden: return "アクセスが拒否されました"
        case .notFound: return "見つかりませんでした"
        case .badRequest(let msg): return msg ?? "リクエストが不正です"
        case .server(let code): return "サーバエラー（\(code)）"
        case .decoding: return "応答の解析に失敗しました"
        case .badResponse: return "不正な応答を受信しました"
        }
    }
}
