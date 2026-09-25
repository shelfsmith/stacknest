// SPDX-License-Identifier: MIT
import AppCore
import AppKit
import EPUBAdapter
import LibraryServerAPI
import LibraryStore
import RemoteClient
import SwiftUI
import os

/// Phase 4.2b-2 Task 5: オフライン（ダウンロード済み）ライブラリの閲覧 UI。
/// サーバ接続を一切持たず、OfflineStore + ローカルファイルのみで動作する。
/// ダウンロード済みの本を一覧し、内蔵ビューアでオフライン再生する。
struct OfflineLibraryView: View {
    @State private var books: [DownloadedBook] = []
    @State private var query = ""
    @State private var errorText: String? = nil
    /// ネイティブ List(selection:) による複数選択（⌘/Shift）。単一選択でも詳細ペインを駆動する。
    @State private var multiSelection: Set<String> = []
    /// G10: 詳細ペインの表紙表示トグル（per-browser・このウィンドウ専用・既定 true）。
    @State private var showDetailCover = true
    /// Bug 3b: List に focus を当て、Return キーで選択中の本を開けるようにする
    /// （.searchable が focus を保持していると onKeyPress(.return) が発火しない）。
    @FocusState private var listFocused: Bool

    private let store = OfflineStore()
    /// G54-S2 修正 3: 内蔵→外部フォールバックのログ用（ローカル側 AppState.logger と同じ調子）。
    private static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "OfflineLibraryView")

    var body: some View {
        // O4: ローカル/リモートとの整合のため「一覧（主・広い）＋詳細（固定240）」の 2 ペイン。
        // HSplitView はコンテンツ理想サイズで配分し maxWidth を厳守しないため、詳細の中身
        // （未選択の空状態 vs 選択時）で一覧幅（＝footer 幅）が揺れる（V4 NG）。
        // → HStack で詳細を真の固定幅にし、一覧幅を選択状態に依らず一定にする。
        NavigationStack {
            HStack(spacing: 0) {
                listColumn
                    .frame(maxWidth: .infinity)
                Divider()
                detailPane
                    .frame(width: 240)
            }
            .frame(minWidth: 760, minHeight: 480)
            .navigationTitle("StackNest Remote Offline")
            .searchable(text: $query, placement: .toolbar, prompt: "タイトルで検索")
            .toolbar {
                // 4.2c-3 (D4): 一括バーを廃し、選択削除はツールバーの削除ボタンに統一。
                // 0 件でグレーアウト、1 件以上で有効（リモートのダウンロードボタンと同方針）。
                ToolbarItem {
                    Button(role: .destructive) { deleteSelected() } label: {
                        Label("削除", systemImage: "trash")
                    }
                    .disabled(multiSelection.isEmpty)
                    .help("選択した本のオフライン保存を削除")
                }
                // G10: 詳細ペインの表紙表示を per-browser でトグル（このウィンドウのみ・既定 ON）。
                ToolbarItem {
                    Button { showDetailCover.toggle() } label: {
                        Label("詳細ペインの表紙", systemImage: showDetailCover ? "photo.fill" : "photo")
                    }
                    .help("詳細ペインの表紙表示を切り替え")
                }
            }
        }
        .task { reload() }
        // O2: 別ウィンドウ（リモートブラウズ）で DL/削除されたら即座に反映する。
        .onReceive(NotificationCenter.default.publisher(for: .offlineStoreDidChange)) { _ in
            reload()
        }
        // ⌘⇧O 復帰: オフラインウィンドウが既に開いている場合、openWindow はフォーカスのみで
        // .task を再実行しないため、通知で reload() を発火し pendingBookID を消費する。
        .onReceive(NotificationCenter.default.publisher(for: .offlineResumeRequested)) { _ in
            reload()
        }
    }

    // MARK: - Reload

    private func reload() {
        books = store.all()
        // Phase 4.2c-2: オフライン resume 意図を 1 回だけ消費する。対象本（サーバ側 bookID 一致）が
        // DL 済みにあれば続き確認なしで開く。self-clear するため再 reload では再発火しない。
        if let id = OfflineResumeIntent.shared.pendingBookID, let book = books.first(where: { $0.detail.id == id }) {
            OfflineResumeIntent.shared.pendingBookID = nil
            openOffline(book, resumeDirect: true)
        }
    }

    /// query（タイトル一致）で絞り込んだ本。
    private var filtered: [DownloadedBook] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return books }
        return books.filter { $0.detail.title.localizedCaseInsensitiveContains(q) }
    }

    /// libraryName ごとにグルーピング（セクション表示用）。
    private var groups: [(library: String, books: [DownloadedBook])] {
        let dict = Dictionary(grouping: filtered, by: { $0.libraryName })
        return dict.keys.sorted().map { name in
            (library: name, books: dict[name]!.sorted { $0.detail.title < $1.detail.title })
        }
    }

    // MARK: - List column (main pane)

    private var listColumn: some View {
        VStack(spacing: 0) {
            if let errorText {
                banner(errorText)
                Divider()
            }
            if books.isEmpty {
                ContentUnavailableView(
                    "ダウンロード済みの書籍がありません",
                    systemImage: "arrow.down.circle",
                    description: Text("サーバ接続時に書籍をダウンロードすると、ここでオフライン閲覧できます。")
                )
            } else {
                listView
                Divider()
                // O1: footer（件数/合計サイズ）は本があるときだけ表示（空状態で出さない）。
                footer
            }
        }
    }

    private var listView: some View {
        // ネイティブ複数選択: Set バインディングにより単一クリック選択・⌘/Shift 複数選択ができる。
        // v1 デグレ対策: 行ごとの .contextMenu は List のネイティブ単一クリック選択を奪う。
        // List 全体に .contextMenu(forSelectionType:) を付け、選択と統合された右クリック +
        // primaryAction（ダブルクリック / Return）で開く（macOS 標準 API）。
        List(selection: $multiSelection) {
            ForEach(groups, id: \.library) { group in
                Section(group.library) {
                    ForEach(group.books) { book in
                        row(book)
                            .tag(book.id)
                    }
                }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.count >= 2 {
                Button("削除", role: .destructive) { deleteSelected() }
            } else if let id = ids.first, let book = books.first(where: { $0.id == id }) {
                Button("開く") { openOffline(book) }
                Divider()
                Button("削除", role: .destructive) { delete(book) }
            }
        } primaryAction: { ids in
            // ダブルクリック / Return: 先頭の選択本を開く（オフラインビューアは 1 ウィンドウ運用）。
            if let id = ids.first, let book = books.first(where: { $0.id == id }) {
                openOffline(book)
            }
        }
        // Bug 3b: List 自身に focus を当てて primaryAction（Return）を確実に発火させる。
        .focusable()
        .focused($listFocused)
        .task { listFocused = true }
    }

    private func row(_ book: DownloadedBook) -> some View {
        HStack(spacing: 8) {
            thumbnail(book)
                .frame(width: 36, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.detail.title)
                    .font(.body)
                    .lineLimit(2)
                let sub = [book.detail.author, book.detail.series]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: " / ")
                if !sub.isEmpty {
                    Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func thumbnail(_ book: DownloadedBook) -> some View {
        if book.hasCachedCover, let img = NSImage(contentsOf: store.coverURL(for: book)) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.secondary.opacity(0.15))
                .overlay(Image(systemName: "book").foregroundStyle(.secondary))
        }
    }

    private var footer: some View {
        HStack {
            Text("\(books.count) 件")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: store.totalSizeBytes(), countStyle: .file))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func banner(_ text: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.red)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.red.opacity(0.1))
    }

    // MARK: - Detail pane

    /// 詳細ペイン用: 単一選択のときのみ本を返す（複数選択時は nil）。
    private var selectedBook: DownloadedBook? {
        multiSelection.count == 1 ? books.first { multiSelection.contains($0.id) } : nil
    }

    private func selectedRows() -> [BookRow] {
        guard let book = selectedBook else { return [] }
        return [offlineBookRow(book, fileURL: store.fileURL(for: book))]
    }

    /// 共有 read-only DetailPaneView（RemoteLibraryView と同様、編集系は no-op）。
    private var detailPane: some View {
        DetailPaneView(
            books: selectedRows(),
            librarySettings: nil,
            bundleURL: URL(fileURLWithPath: "/"),
            loader: nil,
            canEdit: false,
            showCover: showDetailCover,
            onApplyPatch: { _, _ in }, onApplyPatchMulti: { _, _ in },
            onSetCover: { _, _ in }, onClearCrop: { _ in }, onSetCrop: { _, _ in },
            onJump: { _, _ in }, onError: { _ in },
            coverImage: { id in await offlineCover(id) }
        )
    }

    /// detail pane の coverImage 注入用。選択中の本のキャッシュ表紙を NSImage で返す。
    private func offlineCover(_ bookID: Int) async -> NSImage? {
        guard let book = books.first(where: { $0.detail.id == bookID }), book.hasCachedCover else {
            return nil
        }
        return NSImage(contentsOf: store.coverURL(for: book))
    }

    // MARK: - Actions

    /// G54-S2: オフライン本を外部ビューアへ渡す。題名のリンクを作ってからそのパスを渡す。
    /// 失敗したら理由を `errorText` に出す（`HelperLauncher` が文言を持っている）。
    /// 修正 2: 成功したら `errorText` を消す。内蔵からの引き継ぎ（G54-S2 修正前の内蔵失敗経路）が
    /// 先に赤帯を立てていることがあり、外部起動が成功した後もそれが残ると
    /// 「開いているのに開けなかった」という誤表示になる（赤帯に閉じるボタンが無いため）。
    private func openOfflineExternally(_ book: DownloadedBook, fileURL: URL) {
        let link = OfflineExternalLink(baseDirectory: store.baseDirectory)
        let handoff = link.linkURL(for: book, fileURL: fileURL)
        let row = offlineBookRow(book, fileURL: handoff)
        if let error = HelperLauncher.open(book: row, settings: ViewerSettings.shared) {
            // G54-S2 統合前レビュー Minor #2: HelperLauncher が返す path は題名リンク（`_external/...`）の
            // 内部パスなので、利用者に見せる文言では実体の path（`fileURL`）に差し替える。
            // `reason` はそのまま使う。
            if case .launchFailed(_, let reason) = error {
                errorText = AppError.launchFailed(path: fileURL.path, reason: reason).localizedDescription
            } else {
                errorText = error.localizedDescription
            }
        } else {
            errorText = nil
        }
    }

    /// オフライン保存済みの本を内蔵ビューアで開く。BookContent はローカルファイル経由。
    private func openOffline(_ book: DownloadedBook, resumeDirect: Bool = false) {
        // Phase 4.2c-2: 「最後に開いた本」を記録する（オフライン・サーバ側 bookID を採用）。
        LastReadTracker.shared.record(.offline(bookID: book.detail.id, title: book.detail.title))
        // G54-S2: 形式に応じた設定が外部なら、内蔵の経路に入らずここで外部へ渡す。
        // 動画と txt/md/rtf は内蔵に描く手段が無いので、設定に関わらずここを通る。
        let offlineFileURL = store.fileURL(for: book)
        if !ViewerChoice.shouldTryBuiltIn(forPath: offlineFileURL.path, settings: ViewerSettings.shared) {
            openOfflineExternally(book, fileURL: offlineFileURL)
            return
        }
        // Phase 4.2c-2 (B2): 開く瞬間に OfflineStore から最新の lastPage を読む。
        // captured `book`（@State books 由来）は前回 read 後 reload 前だと古い lastPage を持つため。
        let freshLastPage = store.all().first(where: { $0.id == book.id })?.lastPage ?? book.lastPage
        // G15 V1 / G16 C3: dedup 登録。既存窓があれば前面化して抜け、開き中なら無視して抜ける。
        // オフライン読み出しとリモート読み出しは同一の本を指すため identity を `.remote` に統一する
        // （でないと同じ本をオフラインタブとリモートタブから開くと dedup が効かない）。
        let identity = ViewerIdentity.remote(
            serverID: book.serverID.uuidString, libraryUUID: book.libraryUUID, bookID: book.bookID)
        guard ViewerWindowRegistry.shared.beginOpen(identity) else { return }

        let fileURL = store.fileURL(for: book)
        let row = offlineBookRow(book, fileURL: fileURL)

        // G48-3: ダウンロード済みのテキスト EPUB はローカルと同じ Washi の窓。画像本は従来の画像経路（G48-2b）。
        // G51 offline-extension-migration: 起動時の移行（OfflineStore.migrateFileExtensions）で
        // ファイル実体の拡張子は本来のものへ揃っているため、ファイル名の拡張子を正として判定してよい。
        if fileURL.pathExtension.lowercased() == "epub", let reader = EPUBAdapter.reader, EPUBAdapter.renderer != nil {
            Task { @MainActor in
                if (try? await reader.openImageBook(url: fileURL)) != nil {
                    self.openOfflinePages(book, row: row, identity: identity, freshLastPage: freshLastPage, resumeDirect: resumeDirect)
                    return
                }
                do {
                    let prepared = try await Self.prepareOfflineEPUBReader(store: self.store, book: book)
                    let controller = EPUBReaderWindowController(prepared: prepared, suppressResumeDialog: resumeDirect)
                    self.wireOfflineEPUBWindow(controller, serverID: book.serverID, libraryUUID: book.libraryUUID)
                    ViewerWindowRegistry.shared.finishOpen(identity, controller: controller)
                    controller.present()
                } catch {
                    // G54-S2: EPUB の窓を作れなければ外部へ落とす（ローカルと同じ扱い）。
                    Self.logger.warning("openOffline: makeReaderView failed for bookID=\(book.bookID, privacy: .public) path=\(fileURL.path, privacy: .public): \(String(describing: error), privacy: .public) → falling back to external viewer")
                    ViewerWindowRegistry.shared.cancelOpen(identity)
                    self.openOfflineExternally(book, fileURL: fileURL)
                }
            }
            return
        }

        openOfflinePages(book, row: row, identity: identity, freshLastPage: freshLastPage, resumeDirect: resumeDirect)
    }

    /// G54-S3c: オフラインのテキスト EPUB の reader を用意する（窓には載せない）。開く経路と巻送りの両方で使う。
    private static func prepareOfflineEPUBReader(store: OfflineStore, book: DownloadedBook)
        async throws -> EPUBReaderWindowController.PreparedBook {
        guard let renderer = EPUBAdapter.renderer else { throw EPUBAdapterError.cannotOpen("EPUB renderer unavailable") }
        let fileURL = store.fileURL(for: book)
        let row = offlineBookRow(book, fileURL: fileURL)
        let saved = (store.all().first { $0.id == book.id }?.epubLocator)
            .map { EPUBLocatorValue(spine: $0.spine, progress: $0.progress, cfi: $0.cfi, engine: $0.engine) }
        let reader = try await renderer.makeReaderView(url: fileURL, at: saved)
        let sid = book.serverID, lib = book.libraryUUID, id = book.bookID
        return EPUBReaderWindowController.PreparedBook(
            book: row, reader: reader, resumeLocator: saved,
            persist: { loc in
                store.updateEPUBLocator(serverID: sid, libraryUUID: lib, bookID: id,
                                        locator: EPUBLocatorDTO(spine: loc.spine, progress: loc.progress, cfi: loc.cfi, engine: loc.engine))
            })
    }

    /// G54-S3c: オフラインの EPUB の窓の巻送り・閉じる処理を配線する（文字倍率と配色は窓が当てる）。
    private func wireOfflineEPUBWindow(_ controller: EPUBReaderWindowController, serverID: UUID, libraryUUID: String) {
        let store = self.store
        controller.resolveSibling = { cur, dir in
            await Self.resolveOfflineEPUBSibling(store: store, serverID: serverID, libraryUUID: libraryUUID,
                                                 current: cur, direction: dir == .next ? .next : .prev)
        }
        // G54-S3c（spec §4.2）: 開き直すときも読みかけなら訊く。`row.id` は `DownloadedBook.bookID`
        // （`offlineBookRow` 参照）。同じ id が別のサーバにもありうるので、サーバとライブラリも合わせて引く。
        controller.openSibling = { row in self.reopenDownloadedSibling(row, serverID: serverID, libraryUUID: libraryUUID) }
        controller.onBookSwapped = { [weak controller] newBook in
            guard let controller else { return }
            LastReadTracker.shared.record(.offline(bookID: newBook.id, title: newBook.title))
            // G16 C3: オフラインとリモートは同じ本なので identity は `.remote` に揃えている。
            ViewerWindowRegistry.shared.reidentify(
                to: .remote(serverID: serverID.uuidString, libraryUUID: libraryUUID, bookID: newBook.id),
                controller: controller)
        }
        controller.onClose = { [weak controller] in
            guard let controller else { return }
            ViewerWindowRegistry.shared.unregister(controller: controller)
        }
    }

    /// G54-S3cd 最終レビュー Minor: EPUB の窓の `openSibling` と画像ビューアの `onOpenInEPUBReader` は
    /// どちらも「DL 済みの一覧から一致する本を探して openOffline で開き直す」だけの同じ中身なので、ここへ集約する。
    private func reopenDownloadedSibling(_ row: BookRow, serverID: UUID, libraryUUID: String) {
        guard let downloaded = store.all().first(where: {
            $0.serverID == serverID && $0.libraryUUID == libraryUUID && $0.bookID == row.id }) else {
            // G54-S3e: 窓は既に閉じているので HUD は出せない。解決（`resolveOfflineVolume` /
            // `resolveOfflineEPUBSibling`）が先にファイルの有無を確かめるので、ここへ来るのは解決の後で
            // 保存が消された場合だけ。黙らずに記録は残す。
            Self.logger.warning("reopenDownloadedSibling: not in the offline store bookID=\(row.id, privacy: .public)")
            return
        }
        openOffline(downloaded)
    }

    /// G54-S3c: オフラインの EPUB の窓の次（前）の巻（DL 済みの隣の巻だけ）。テキスト EPUB なら reader まで用意する。
    private static func resolveOfflineEPUBSibling(store: OfflineStore, serverID: UUID, libraryUUID: String,
                                                  current: BookRow, direction: OfflineStore.AdjacentDirection)
        async -> EPUBReaderWindowController.SiblingResolution {
        guard let series = current.series, let volume = current.volume,
              let sib = store.adjacentDownloaded(serverID: serverID, libraryUUID: libraryUUID,
                                                 series: series, volume: volume, direction: direction)
        else { return .noSibling }
        let url = store.fileURL(for: sib)
        // G54-S3e: ファイルが無ければ今の本のまま。ここで止めないと、隣が zip のとき `.reopen` → 窓を閉じる
        // → `openOffline` → 外部ビューアへ落ちる（ローカルの EPUB の窓と同じ穴）。
        if FileReadProbe.check(url) == .notFound {
            logger.warning("resolveOfflineEPUBSibling: sibling file missing bookID=\(sib.bookID, privacy: .public)")
            return .failed
        }
        let row = offlineBookRow(sib, fileURL: url)
        let kind = await SiblingVolumeKind.probeLocal(path: url.path, reader: EPUBAdapter.reader).kind
        guard kind == .textEPUB, EPUBAdapter.renderer != nil else { return .reopen(row) }
        do {
            return .swapIn(try await prepareOfflineEPUBReader(store: store, book: sib))
        } catch {
            logger.warning("resolveOfflineEPUBSibling: makeReaderView failed for bookID=\(sib.bookID, privacy: .public): \(String(describing: error), privacy: .public)")
            return .failed
        }
    }

    /// G48-3: 従来の内蔵ビューア（画像本・PDF 等）で開く経路。openOffline から切り出し（挙動は変更なし）。
    /// EPUB リーダー未登録・EPUB でない・画像本 EPUB（openImageBook が成功）の場合はここへ流れる。
    private func openOfflinePages(_ book: DownloadedBook, row: BookRow, identity: ViewerIdentity, freshLastPage: Int?, resumeDirect: Bool) {
        let content: BookContent
        do {
            content = try BookContentFactory.make(for: row)
        } catch {
            // G54-S2: ローカル（AppState.openInBuiltInViewer）と同じく、内蔵で作れなければ外部へ落とす。
            let bookPath = store.fileURL(for: book).path
            Self.logger.warning("openOfflinePages: BookContentFactory.make failed for bookID=\(book.bookID, privacy: .public) path=\(bookPath, privacy: .public): \(String(describing: error), privacy: .public) → falling back to external viewer")
            ViewerWindowRegistry.shared.cancelOpen(identity)
            openOfflineExternally(book, fileURL: store.fileURL(for: book))
            return
        }
        Task { @MainActor in
            let pageCount: Int
            do {
                pageCount = try await content.pageCount
            } catch {
                // G54-S2 統合前レビュー Important #1: ローカル（AppState.presentBuiltInViewer）と
                // 同じく、pageCount が throw したら外部にフォールバックする。詰まっているのは
                // 内蔵の読み手であって外部ビューアではないため、ここで行き止まりにしない。
                let bookPath = store.fileURL(for: book).path
                Self.logger.warning("openOfflinePages: pageCount threw for bookID=\(book.bookID, privacy: .public) path=\(bookPath, privacy: .public): \(String(describing: error), privacy: .public) → falling back to external viewer")
                ViewerWindowRegistry.shared.cancelOpen(identity)
                self.openOfflineExternally(book, fileURL: self.store.fileURL(for: book))
                return
            }
            guard pageCount > 0 else {
                // G54-S2 統合前レビュー Important #1: pageCount==0 も同様に外部へ落とす。
                let bookPath = store.fileURL(for: book).path
                Self.logger.warning("openOfflinePages: pageCount==0 for bookID=\(book.bookID, privacy: .public) path=\(bookPath, privacy: .public) → falling back to external viewer")
                ViewerWindowRegistry.shared.cancelOpen(identity)
                self.openOfflineExternally(book, fileURL: self.store.fileURL(for: book))
                return
            }
            // G26: 破損（打ち切り読み）注意文を content と一緒に確定させてビューアへ渡す
            // （ビューア側で遅延取得すると永続化ゲートに間に合わない — `TruncatedReadPolicy` 参照）。
            let damageNote = await content.damageNote
            // ローカル DB は持たないため、見開きはグローバル既定で開き、lastPage は OfflineStore の値。
            let initialState = ResolvedViewerState(
                spreadEnabled: ViewerSettings.shared.spreadByDefault,
                coverOffset: true,
                lastPage: max(0, freshLastPage ?? 0),
                overrides: [:]
            )
            let options = ViewerOptions(
                pageDirection: row.pageDirection ?? ViewerSettings.shared.pageDirection,
                endOfBookBehavior: ViewerSettings.shared.endOfBookBehavior
            )
            let serverID = book.serverID
            let libraryUUID = book.libraryUUID
            let store = self.store
            let controller = ViewerWindowController(
                content: content,
                book: row,
                pageCount: pageCount,
                options: options,
                initialState: initialState,
                // 多段巻送り対応: 解決はクロージャ引数 `cur`（=現在スワップ済みの巻）の
                // series/volume を基点にする。serverID/libraryUUID は同一シリーズ内で不変なので
                // 開いた本のものを使う。`cur` を無視して最初の book から再解決すると 2 巻目で
                // 止まる/自動進行が 2 巻目をループする（ローカル/リモートと同じく cur を使う）。
                loadNextVolume: { [store] cur in
                    await Self.resolveOfflineVolume(store: store, serverID: serverID, libraryUUID: libraryUUID,
                                              current: cur, direction: .next)
                },
                loadPrevVolume: { [store] cur in
                    await Self.resolveOfflineVolume(store: store, serverID: serverID, libraryUUID: libraryUUID,
                                              current: cur, direction: .prev)
                },
                // 進捗を OfflineStore に永続化する（リモートサーバへの POST の代替）。
                // G26 Codex Important #1: 第 5 引数（「最初から」の意思表示）は下の best-effort
                // POST に必ず載せる。オフライン読みでも本体はサーバ上の同じ本なので、伝えないと
                // サーバ側 `/progress` の打ち切りゲートが「最初から」を握り潰す。
                persistState: { b, lastPage, _, _, restart in
                    LastReadTracker.shared.record(.offline(bookID: b.id, title: b.title))
                    store.updateLastPage(serverID: serverID, libraryUUID: libraryUUID, bookID: b.id, page: lastPage)
                    // 4.2c-5: サーバへも best-effort で POST（リモートビューアと続きを一致させる）。
                    // オフライン/接続なし/ロック庫(トークン無し)は握り潰す。
                    Task {
                        guard let conn = ServerConnectionStore().connection(id: serverID),
                              let base = URL(string: conn.baseURL) else { return }
                        let client = RemoteLibraryClient(baseURL: base, deviceToken: conn.token)
                        try? await client.postProgress(
                            libraryUUID: libraryUUID, bookID: b.id, page: lastPage,
                            restart: restart, libraryToken: nil)
                    }
                },
                // ページレイアウト override はオフラインでは永続化しない（no-op）。
                persistPageOverride: { _, _, _ in },
                suppressResumeDialog: resumeDirect,
                sourceLabel: "オフライン",
                damageNote: damageNote
            )
            // G16 C1 fix: onClose は controller 生成後に [weak controller] で設定する
            // （init 引数の時点では自身の identity をまだ束縛できないため controller を渡せない）。
            // unregister(controller:) は現在のキー（reidentify 後でも常に最新）を逆引きして
            // 除去するので、巻スワップ後に閉じても registry entry が residual リークしない。
            // B2: close 時に reload して、保存された lastPage を次回 open に反映する
            // （updateLastPage は .offlineStoreDidChange を post しないため）。
            controller.onClose = { [weak controller] in
                guard let controller else { return }
                ViewerWindowRegistry.shared.unregister(controller: controller)
                self.reload()
            }
            // G54-S3c: 次の巻がテキスト EPUB なら、通常の経路で EPUB の窓を開く（読みかけなら訊く）。
            controller.onOpenInEPUBReader = { row in self.reopenDownloadedSibling(row, serverID: serverID, libraryUUID: libraryUUID) }
            // G16 C1: 巻送りで bookID が変わったら registry の identity を追従させる
            // （serverID/libraryUUID はシリーズ内で不変・.remote へ統一済み＝C3）。
            // G26 fix round 2: pageCount 引数はローカル DB を持たないオフライン/リモート経路では使わない
            // （pages 収束はローカル database を持つ AppState 側のみ・onBookSwapped 参照）。
            controller.onBookSwapped = { [weak controller] newBook, _, _ in
                guard let controller else { return }
                let newIdentity = ViewerIdentity.remote(
                    serverID: serverID.uuidString, libraryUUID: libraryUUID, bookID: newBook.id)
                ViewerWindowRegistry.shared.reidentify(to: newIdentity, controller: controller)
            }
            ViewerWindowRegistry.shared.finishOpen(identity, controller: controller)
            self.errorText = nil
            controller.present()
        }
    }

    // MARK: - Multi-select state helpers

    private func deleteSelected() {
        let targets = books.filter { multiSelection.contains($0.id) }
        // G54-S2 修正 1: 小部屋の削除は OfflineStore.remove 側に寄せた（重複除去）。
        store.removeBooks(targets)
        multiSelection.removeAll()
        reload()
    }

    /// オフライン保存を削除して一覧を更新する。
    private func delete(_ book: DownloadedBook) {
        // G54-S2 修正 1: 小部屋の削除は OfflineStore.remove 側に寄せた（重複除去）。
        store.remove(serverID: book.serverID, libraryUUID: book.libraryUUID, bookID: book.bookID)
        multiSelection.remove(book.id)
        reload()
    }

    /// DL 済の連続隣接巻を解決する。該当なし/失敗は nil。
    /// `current` は現在表示中の巻（多段巻送りで毎回更新される）。その series/volume を基点に解決する。
    /// G54-S3c: 次の巻がテキスト EPUB なら `.openInEPUBReader`。画像本 EPUB は判定で開いた handle を使う。
    private static func resolveOfflineVolume(store: OfflineStore, serverID: UUID, libraryUUID: String,
                                             current: BookRow,
                                             direction: OfflineStore.AdjacentDirection) async -> VolumeLoad? {
        guard let series = current.series, let volume = current.volume else { return nil }
        guard let sib = store.adjacentDownloaded(
            serverID: serverID, libraryUUID: libraryUUID,
            series: series, volume: volume, direction: direction) else { return nil }
        let url = store.fileURL(for: sib)
        // G54-S3e（spec §2.1-3）: ファイルが無ければ窓を閉じずに留まる（ローカルと同じ）。
        if case .unavailable(let note) = VolumeHandover.imageViewerPrecheck(
            FileReadProbe.check(url), forward: direction == .next) {
            return .unavailable(note: note)
        }
        let row = offlineBookRow(sib, fileURL: url)
        let probe = await SiblingVolumeKind.probeLocal(path: url.path, reader: EPUBAdapter.reader)
        if probe.kind == .textEPUB { return .openInEPUBReader(row) }
        let content: BookContent
        if let handle = probe.imageBook {
            content = EPUBImageBookContent(handle: handle)
        } else {
            guard let made = try? BookContentFactory.make(for: row) else { return nil }
            content = made
        }
        let state = ResolvedViewerState(
            spreadEnabled: ViewerSettings.shared.spreadByDefault,
            coverOffset: true,
            lastPage: max(0, sib.lastPage ?? 0),
            overrides: [:]
        )
        return .swap(NextVolume(content: content, book: row, state: state))
    }
}
