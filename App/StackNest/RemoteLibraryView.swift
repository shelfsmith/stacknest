// SPDX-License-Identifier: MIT
import AppCore
import AppKit
import LibraryServerAPI
import RemoteClient
import SwiftUI

/// Phase 4.2b-1: リモートライブラリの閲覧 UI（解錠フォーム / 一覧 / グリッド / ページャ）。
struct RemoteLibraryView: View {
    @Bindable var state: RemoteLibraryState

    /// Phase 4.2c-1: リスト表示は NSTableView パリティウィジェット（RemoteBookTableViewRepresentable）が
    /// 列構成・列幅を読み書きするための LibrarySettings。リモートウィンドウ共有インスタンス。
    @Bindable var settings: LibrarySettings

    /// D1: グリッドに focus を与えて .onKeyPress(.return) を確実に発火させる。
    @FocusState private var listFocused: Bool

    /// Task 3: paged per の TextField 入力（数字のみ・commit 時に clamp）。
    @State private var perInput = ""

    /// 4.2b-1b-1: per TextField のフォーカス追跡（フォーカスを外したときに commitPerInput() を発火）。
    @FocusState private var perFieldFocused: Bool

    /// Task 6: フィルタ popover の表示制御。
    @State private var filterShown = false

    /// B2: ファセットペイン表示制御（セッションスコープ）。
    @State private var showFacets = true

    /// B2: サイドバー列表示制御（NavigationSplitView columnVisibility binding）。
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            if state.locked && state.libraryToken == nil {
                unlockForm
                    .frame(minWidth: 720, minHeight: 480)
            } else {
                splitView
            }
        }
        // 4.2c-3 (A3): タイトルはツールバー中央(principal)ではなく、ウィンドウタイトル
        // （左・背景なし・プレーン）として表示する（ローカルと同方針）。
        .navigationTitle("StackNest Remote – \(state.libraryName)")
        // Phase 4.2c-3: ローカルブラウザと同じライブフィルタ + クリア(×)ボタンの検索欄。
        // .searchable がツールバーに検索フィールドと × クリアを提供。入力ごとに onChange が
        // 発火し scheduleSearchReload() が 300ms デバウンスして reload する（キー入力毎の
        // ネットワーク再取得を避ける）。× クリアで query="" → onChange → 全件再読込。
        .searchable(text: $state.query, placement: .toolbar, prompt: "検索")
        .onChange(of: state.query) { _, _ in state.scheduleSearchReload() }
    }

    // MARK: - Split layout (Task 6)

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            RemoteSidebarView(state: state)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } content: {
            browseView
                .frame(minWidth: 480)
        } detail: {
            detailPane
                // O5: ローカルブラウザと同様に詳細ペインを固定幅にする（伸びて広すぎる問題の修正）。
                .navigationSplitViewColumnWidth(min: 240, ideal: 240, max: 240)
        }
        .frame(minWidth: 960, minHeight: 480)
    }

    /// 詳細 DetailPaneView。write トークン時は編集可（canEdit = state.canEditServer）。
    /// v1: 単一本のメタデータ編集のみ。カバー・クロップ・マルチ選択編集は no-op。
    private var detailPane: some View {
        DetailPaneView(
            books: state.detailBookRows(),
            librarySettings: nil,
            bundleURL: URL(fileURLWithPath: "/"),
            loader: nil,
            canEdit: state.canEditServer,
            directionEditable: true,
            onSetPageDirection: { id, dir in Task { await state.setRemoteDirection(bookID: id, direction: dir) } },
            onApplyPatch: { id, patch in Task { await state.applyRemotePatch(bookID: id, patch: patch) } },
            onApplyPatchMulti: { _, _ in },
            onSetCover: { _, _ in }, onClearCrop: { _ in }, onSetCrop: { _, _ in },
            onJump: { field, value in Task { await state.jumpToFilter(field: field, value: value) } },
            onError: { _ in },
            coverImage: { id in await state.coverImage(id) }
        )
    }

    // MARK: - Unlock

    @State private var password = ""

    private var unlockForm: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("「\(state.libraryName)」は保護されています")
                .font(.headline)
            SecureField("パスワード", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit { Task { await state.unlock(password: password) } }
            Button("解錠") { Task { await state.unlock(password: password) } }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
            if let err = state.errorText {
                Text(err).foregroundStyle(.red).font(.caption)
            }
        }
        .padding(40)
    }

    // MARK: - Browse

    private var browseView: some View {
        VStack(spacing: 0) {
            toolbar
            if let err = state.errorText {
                banner(err)
            }
            Divider()
            // Task 6 / B2: 共有ファセット pane（上端）。showFacets で表示切替可。
            if showFacets {
                BrowserPaneView(
                    browserPaneState: $state.browserPaneState,
                    labelFor: { defaultBrowseFieldLabel($0) },
                    refreshKey: state.facetRefreshKey,
                    facetValues: { col, upper in await state.facetValues(col, upper) }
                )
                Divider()
            }
            if state.isGrid {
                gridView
            } else {
                // Phase 4.2c-1: SwiftUI List をローカルと同じ多列 NSTableView パリティ
                // ウィジェットに置換。列構成・列幅・ソート・選択・ダウンロード文脈メニュー・
                // infinite スクロールは RemoteBookTableCoordinator 内で配線済み。
                RemoteBookTableViewRepresentable(state: state, settings: settings)
            }
            // Task 3: paged のみページャ表示。infinite では非表示。
            if state.scrollMode == .paged {
                Divider()
                pager
            }
        }
        .task { await state.reload() }
        .onAppear { perInput = String(state.per) }
        .onChange(of: state.per) { _, newValue in
            // setPer 経由などで per が変わったら TextField を同期。
            let synced = String(newValue)
            if perInput != synced { perInput = synced }
        }
        // Task 6: フィルタ変更で先頭から読み直す。
        .onChange(of: state.filterState) { _, _ in
            Task { await state.reload() }
        }
        // Task 6: ファセット選択で先頭から読み直す。
        .onChange(of: state.browserPaneState.selections) { _, _ in
            Task { await state.reload() }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("並び替え", selection: $state.sortKey) {
                Text("タイトル").tag("title")
                Text("シリーズ").tag("series")
                Text("追加日").tag("dateAdded")
                Text("最終閲覧").tag("lastRead")
            }
            .frame(width: 150)
            .onChange(of: state.sortKey) { _, _ in
                Task { await state.reload() }
            }

            Button {
                state.ascending.toggle()
                Task { await state.reload() }
            } label: {
                Image(systemName: state.ascending ? "arrow.up" : "arrow.down")
            }
            .help(state.ascending ? "昇順" : "降順")

            // Task 3: 表示モード（ページ表示 / 無限スクロール）。
            Picker("", selection: modeBinding) {
                Text("ページ表示").tag(RemoteScrollMode.paged)
                Text("無限スクロール").tag(RemoteScrollMode.infinite)
            }
            .frame(width: 160)
            .help("表示モード")

            // Task 3: paged のみ per 件数コントロール（Stepper + TextField）。
            if state.scrollMode == .paged {
                perControl
            }

            Spacer()

            // 4.2c-3 (D2): バッチバーを廃し、選択ダウンロードはツールバーの常設ボタンに統一。
            // 選択 0 件でグレーアウト、1 件以上で有効。DL 中は×（中断）ボタンに変わる（D2a）。
            if let p = state.batchProgress {
                ProgressView(value: Double(p.done), total: Double(max(1, p.total))).frame(width: 80)
                Text("\(p.done)/\(p.total)").font(.caption).foregroundStyle(.secondary)
                Button { state.cancelBatchDownload() } label: {
                    Image(systemName: "xmark.circle")
                }
                .help("ダウンロードを中断")
            } else {
                if let summary = state.batchSummary {
                    Label(summary, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                }
                Button { Task { await state.downloadSelected() } } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .help("選択した書籍をダウンロード")
                .disabled(state.multiSelection.isEmpty)
            }

            // Task 6: フィルタ popover（FilterPopoverView を再利用、data-agnostic）。
            Button {
                filterShown.toggle()
            } label: {
                Image(systemName: state.filterState.isEmpty
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill")
            }
            .help("フィルタ")
            .popover(isPresented: $filterShown, arrowEdge: .bottom) {
                FilterPopoverView(filter: $state.filterState)
                    .frame(width: 280)
            }

            // B2: ファセットペイン表示切替ボタン。
            Button { showFacets.toggle() } label: {
                Image(systemName: showFacets ? "rectangle.split.3x1" : "rectangle")
            }
            .help(showFacets ? "ファセットを隠す" : "ファセットを表示")

            Picker("", selection: $state.isGrid) {
                Image(systemName: "list.bullet").tag(false)
                Image(systemName: "square.grid.2x2").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 90)
        }
        .padding(8)
    }

    /// 表示モード Picker の binding。変更時に state.setMode を呼ぶ。
    private var modeBinding: Binding<RemoteScrollMode> {
        Binding(
            get: { state.scrollMode },
            set: { state.setMode($0) }
        )
    }

    /// Task 3: 1 ページの件数（Stepper + TextField、20...500、commit 時 clamp）。
    /// SettingsView の thickBookThreshold パターンを踏襲。
    private var perControl: some View {
        HStack(spacing: 4) {
            Text("1ページ")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("", text: $perInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 48)
                .multilineTextAlignment(.trailing)
                .focused($perFieldFocused)
                .onChange(of: perInput) { _, newValue in
                    // 数字以外を弾く + 最大 3 桁（20...500 範囲なので十分）。
                    let cleaned = String(newValue.filter(\.isNumber).prefix(3))
                    if cleaned != newValue { perInput = cleaned }
                }
                .onSubmit { commitPerInput() }
                .onChange(of: perFieldFocused) { _, focused in
                    if !focused { commitPerInput() }
                }
            Text("件")
                .font(.caption)
                .foregroundStyle(.secondary)
            Stepper("", value: stepperBinding, in: 20...500, step: 1)
                .labelsHidden()
        }
    }

    /// Stepper の binding。増減で state.setPer を呼ぶ。
    private var stepperBinding: Binding<Int> {
        Binding(
            get: { state.per },
            set: { state.setPer($0) }
        )
    }

    /// TextField 入力を Int に変換し clamp して setPer に渡す。
    /// 空文字・parse 失敗時は state.per を表示し直す（.onChange(of: state.per) で同期される）。
    private func commitPerInput() {
        if let v = Int(perInput) {
            state.setPer(v)
        }
        perInput = String(state.per)
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

    // MARK: - Selection helpers

    /// D1: 選択中の本を開く。グリッドの Return キー処理で使用。
    private func openSelected() -> KeyPress.Result {
        if let id = state.selection, let book = state.books.first(where: { $0.id == id }) {
            state.openViewer(book: book)
            return .handled
        }
        return .ignored
    }

    // MARK: - Offline download (Task 4)

    /// ダウンロード済みか。state.downloadedVersion を参照して body 再評価時に再計算させる。
    private func downloadedBadge(_ bookID: Int) -> Bool {
        _ = state.downloadedVersion
        return state.isDownloaded(bookID)
    }

    /// コンテキストメニュー（ダウンロード / オフラインから削除）。
    @ViewBuilder
    private func downloadMenu(_ book: BookListItemDTO) -> some View {
        if downloadedBadge(book.id) {
            Button("オフラインから削除") { state.removeDownload(book.id) }
        } else {
            Button("ダウンロード") { Task { await state.downloadBook(book) } }
        }
    }

    // MARK: - Grid mode

    private let gridColumns = [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 16)]
    private let gridItemMinSize: CGFloat = 140
    private let gridSpacing: CGFloat = 16

    /// O6: グリッド幅を GeometryReader で取得し、列数計算に使う。
    @State private var gridWidth: CGFloat = 0

    /// O6: 現在の列数（GridColumnCalculator を使用）。
    private var currentColumnCount: Int {
        GridColumnCalculator.columns(viewportWidth: gridWidth, itemMinSize: gridItemMinSize, spacing: gridSpacing)
    }

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: gridSpacing) {
                ForEach(state.books, id: \.id) { book in
                    RemoteBookCell(book: book, state: state, selected: state.selection == book.id,
                                   downloaded: downloadedBadge(book.id))
                        .onTapGesture(count: 2) { state.openViewer(book: book) }
                        .onTapGesture { Task { await state.selectBook(book.id) } }
                        .contextMenu { downloadMenu(book) }
                        // Task 3: infinite モードで末尾セルが見えたら次チャンクを取得。
                        .onAppear {
                            if state.scrollMode == .infinite, book.id == state.books.last?.id {
                                Task { await state.loadMore() }
                            }
                        }
                }
            }
            .padding(gridSpacing)
        }
        // O6: グリッド幅を背景 GeometryReader で取得（ScrollView レイアウトを変えない）。
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { gridWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, w in gridWidth = w }
        })
        // D1: グリッドでも Return で選択中の本を開く。
        .focusable()
        .focused($listFocused)
        .onKeyPress(.return) { openSelected() }
        // O6: 矢印キーでグリッドセルを移動する。
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow], phases: .down) { press in
            let books = state.books
            guard !books.isEmpty else { return .ignored }
            let cols = max(1, currentColumnCount)
            let total = books.count
            let cur = state.selection.flatMap { id in books.firstIndex(where: { $0.id == id }) }
            let direction: GridNavigator.Direction
            switch press.key {
            case .upArrow:    direction = .up
            case .downArrow:  direction = .down
            case .leftArrow:  direction = .left
            case .rightArrow: direction = .right
            default: return .ignored
            }
            let targetIdx: Int
            if let cur {
                guard let next = GridNavigator.nextIndex(current: cur, direction: direction, total: total, columns: cols) else {
                    return .handled  // 端で消費（スクロール等に伝播させない）
                }
                targetIdx = next
            } else {
                targetIdx = 0  // 未選択 + 矢印 → 先頭
            }
            let id = books[targetIdx].id
            Task { await state.selectBook(id) }
            return .handled
        }
        .task { listFocused = true }
    }

    // MARK: - Pager

    private var pager: some View {
        HStack {
            Button("前") {
                if state.page > 1 {
                    state.page -= 1
                    Task { await state.load() }
                }
            }
            .disabled(state.page <= 1)

            Text("\(state.page) / \(state.pageCountTotalPages) ページ")
                .font(.caption)
                .monospacedDigit()

            Button("次") {
                if state.page < state.pageCountTotalPages {
                    state.page += 1
                    Task { await state.load() }
                }
            }
            .disabled(state.page >= state.pageCountTotalPages)

            Spacer()
            Text("全 \(state.total) 件").font(.caption).foregroundStyle(.secondary)
        }
        .padding(8)
    }
}

// MARK: - Grid cell

/// グリッドセル。可視時に .task で表紙を遅延ロードする（LazyVGrid なので可視セルのみ発火）。
private struct RemoteBookCell: View {
    let book: BookListItemDTO
    let state: RemoteLibraryState
    let selected: Bool
    /// Task 4: ダウンロード済みバッジ表示フラグ（親が downloadedVersion 参照込みで算出）。
    let downloaded: Bool

    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.15))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 180)
            .overlay(alignment: .topTrailing) {
                if downloaded {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.tint)
                        .padding(4)
                        .background(.thinMaterial, in: Circle())
                        .padding(4)
                        .help("オフライン保存済み")
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2)
            )

            Text(book.title)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .task(id: book.id) {
            if book.hasCover {
                if let data = await state.cover(bookID: book.id) {
                    image = NSImage(data: data)
                }
            }
        }
    }
}
