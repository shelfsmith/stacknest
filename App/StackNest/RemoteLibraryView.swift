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

    /// 4.2c-4: グリッドの ⌘/Shift クリック複数選択用。NSEvent ローカルモニタで連続追跡する。
    @State private var currentModifiers: NSEvent.ModifierFlags = []
    @State private var modifierMonitor: Any?
    /// Shift クリックの範囲選択アンカー。
    @State private var anchorBookID: Int?

    /// Task 3: paged per の TextField 入力（数字のみ・commit 時に clamp）。
    @State private var perInput = ""

    /// 4.2b-1b-1: per TextField のフォーカス追跡（フォーカスを外したときに commitPerInput() を発火）。
    @FocusState private var perFieldFocused: Bool

    /// B2: サイドバー列表示制御（NavigationSplitView columnVisibility binding）。
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all

    /// 解錠フォーム（未解錠の保護ライブラリ）を表示中か。body の分岐と .toolbar の出し分けで共有する。
    private var isUnlockFormShown: Bool { state.locked && state.libraryToken == nil }

    var body: some View {
        Group {
            if isUnlockFormShown {
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
        // 4.2c-4 (smoke v4 自由記載): ツールバー配置をローカルブラウザに揃える。
        // - grid/list 切替を中央(principal)に・順序を grid→list（ローカルと同一）。
        // - フィルタボタン（= ユーザーの言う「ソートボタン」）を primaryAction に（ローカルと同部品）。
        // - 上ペイン切替 [ブラウズ|スタンプ|隠す] をローカルから移植（スタンプは現状グレーアウト）。
        //   「隠す」(eye.slash) でファセット（=カラム）ペインを非表示にする。
        .toolbar {
            if !isUnlockFormShown {
                ToolbarItem(placement: .principal) {
                    Picker("", selection: $state.isGrid) {
                        Image(systemName: "square.grid.2x2").tag(true)
                        Image(systemName: "list.bullet").tag(false)
                    }
                    .pickerStyle(.segmented)
                }
                ToolbarItem(placement: .primaryAction) {
                    FilterToolbarButton(filter: $state.filterState, settings: settings)
                }
                ToolbarItem(placement: .primaryAction) {
                    RemoteTopPaneControl(settings: settings)
                }
            }
        }
        // 4.2c-3 (Issue 4): 別ウィンドウ（オフラインビューア等）で DL/削除されたら、リモート一覧の
        // DL バッジを即時再評価する。downloadedVersion を bump → updateNSView 再走 → DL 列再描画。
        .onReceive(NotificationCenter.default.publisher(for: .offlineStoreDidChange)) { _ in
            state.downloadedVersion &+= 1
        }
        // 4.2c-4 (A5): グリッドは LazyVGrid が selectAll: を持たないため、編集メニュー「すべてを選択」
        // (⌘A) の通知をグリッド表示中に受けて全件選択する（リストは NSTableView が selectAll: を直接処理）。
        .onReceive(NotificationCenter.default.publisher(for: .stacknestSelectAllRequest)) { _ in
            guard state.isGrid, listFocused else { return }
            state.multiSelection = Set(state.books.map(\.id))
        }
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
            onApplyPatchMulti: { ids, patch in state.startBatchEdit(ids: Set(ids), patch: patch) },
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
            // Task 6 / B2 / 4.2c-4 / 4.2c-6a: 上ペイン切替。"browse"=ファセット / "stamp"=スタンプ
            // / "hidden"=非表示。
            if settings.topPaneMode == "browse" {
                BrowserPaneView(
                    browserPaneState: $state.browserPaneState,
                    labelFor: { defaultBrowseFieldLabel($0) },
                    refreshKey: state.facetRefreshKey,
                    facetValues: { col, upper in await state.facetValues(col, upper) }
                )
                Divider()
            } else if settings.topPaneMode == "stamp" {
                RemoteStampPaneView(state: state)
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
        .task { await state.reload(); await state.loadStampDefinitions() }
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
        // 4.2c-7: grid/list トグルは reload を伴わないため個別にブラウズ状態を永続化する。
        .onChange(of: state.isGrid) { _, _ in state.persistBrowseState() }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            // 4.2c-4: フィルタ・上ペイン切替・grid/list 切替はネイティブツールバー（body の .toolbar）
            // に移動しローカルと配置を揃えた。この行にはリモート固有のコントロールのみ残す。
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

            // 4.2c-6a (smoke v2 自由記載): このリモート接続が編集可(RW)か閲覧のみ(R)かを一目で示す。
            Label(state.canEditServer ? "RW" : "R",
                  systemImage: state.canEditServer ? "pencil.circle" : "eye.circle")
                .font(.caption)
                .foregroundStyle(state.canEditServer ? Color.accentColor : .secondary)
                .help(state.canEditServer ? "編集可能（RW トークン）" : "閲覧のみ（R トークン）")

            Spacer()

            // 4.2c-3 (v7 自由記載修正): ダウンロード進捗/中断ボタンは独立した子ビューに分離する。
            // downloadProgress は 64KB ごとに更新されるため、toolbar/browseView 本体がこれを読むと
            // 進捗のたびに本体全体が再評価され、上部ファセットペイン（ジャンル/作者/シリーズ）の List が
            // 高頻度に再レイアウトされてチラつく。子ビューに切り出すと本体は downloadProgress を読まず
            // 再評価されない（リストの DL リングは RemoteBookTable.updateNSView が downloadProgress を
            // 自前で購読しているため独立して更新される）。
            RemoteBatchEditButton(state: state)
            RemoteDownloadButton(state: state)
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

    /// D1 / 4.2c-4: 選択中（アンカー優先→複数選択先頭→単一選択）の本を開く。グリッドの Return 用。
    private func openSelected() -> KeyPress.Result {
        let id = anchorBookID ?? state.multiSelection.first ?? state.selection
        if let id, let book = state.books.first(where: { $0.id == id }) {
            state.openViewer(book: book)
            return .handled
        }
        return .ignored
    }

    // MARK: - Grid modifier monitor (4.2c-4)

    private func startModifierMonitor() {
        guard modifierMonitor == nil else { return }
        currentModifiers = []
        modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { event in
            currentModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            return event
        }
    }

    private func stopModifierMonitor() {
        if let monitor = modifierMonitor {
            NSEvent.removeMonitor(monitor)
            modifierMonitor = nil
        }
    }

    // MARK: - Grid selection (4.2c-4)

    /// 単一クリック: 修飾子で分岐（ローカルグリッドと同方針）。
    private func handleGridClick(_ book: BookListItemDTO) {
        if currentModifiers.contains(.command) {
            toggleSelection(book)
        } else if currentModifiers.contains(.shift) {
            rangeSelect(to: book)
        } else {
            replaceSelection(book)
        }
    }

    /// 修飾なし: 単一選択に置換＋アンカー更新＋詳細追従。
    private func replaceSelection(_ book: BookListItemDTO) {
        state.multiSelection = [book.id]
        anchorBookID = book.id
        Task { await state.selectBook(book.id) }
    }

    /// ⌘: トグル。
    private func toggleSelection(_ book: BookListItemDTO) {
        if state.multiSelection.contains(book.id) {
            state.multiSelection.remove(book.id)
        } else {
            state.multiSelection.insert(book.id)
            anchorBookID = book.id
        }
        syncDetailAfterMulti()
    }

    /// ⇧: アンカーからの範囲選択。
    private func rangeSelect(to book: BookListItemDTO) {
        let books = state.books
        guard let anchor = anchorBookID,
              let a = books.firstIndex(where: { $0.id == anchor }),
              let c = books.firstIndex(where: { $0.id == book.id }) else {
            replaceSelection(book)
            return
        }
        let lo = min(a, c), hi = max(a, c)
        state.multiSelection = Set(books[lo...hi].map(\.id))
        syncDetailAfterMulti()
    }

    /// 複数選択後: 単一選択になったときだけ詳細ペインを追従させる（リスト挙動に一致）。
    private func syncDetailAfterMulti() {
        if state.multiSelection.count == 1, let id = state.multiSelection.first {
            Task { await state.selectBook(id) }
        }
    }

    /// グリッド空白タップ: 選択を全解除し詳細をクリア。
    private func clearGridSelection() {
        state.multiSelection = []
        anchorBookID = nil
        Task { await state.selectBook(nil) }
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
            // 4.2c-4: 単一 DL も一括と同じ進捗バー/×中断 UI を出す。
            Button("ダウンロード") { state.startSingleDownload(book) }
        }
    }

    /// 4.2c-4: グリッドセル右クリックの並び替え。state.sortKey/ascending を設定して reload する。
    /// リスト（NSTableView ヘッダ並び替え）とは state.sortKey を共有するため自動的に相互同期する。
    /// smoke v2 要望: リストは列ヘッダで全列を並び替えできるため、グリッドのメニューも
    /// 全 BookColumn（= サーバ対応の全ソートキー）を出してリストと同等にする。キー・ラベルは
    /// BookColumn.serverSortKey / localizedTitleString を直接使い、列ヘッダと表記を揃える。
    @ViewBuilder
    private func sortMenu() -> some View {
        Menu("並び替え") {
            ForEach(BookColumn.allCases, id: \.self) { col in
                let key = col.serverSortKey
                Button {
                    if state.sortKey == key {
                        state.ascending.toggle()
                    } else {
                        state.sortKey = key
                        state.ascending = true
                    }
                    Task { await state.reload() }
                } label: {
                    Text(state.sortKey == key
                         ? "\(col.localizedTitleString) \(state.ascending ? "↑" : "↓")"
                         : col.localizedTitleString)
                }
            }
        }
    }

    // MARK: - Grid mode

    private let gridSpacing: CGFloat = 16

    /// O6: グリッド幅を GeometryReader で取得し、列数計算に使う。
    @State private var gridWidth: CGFloat = 0

    /// 4.2c-4: グリッドのセルサイズは LibrarySettings.gridItemSize（GridSubToolbar スライダー・100...300）
    /// に従う。ローカルグリッドと同様 minimum=maximum を同値にして連続的にサイズ変更を反映する。
    private var gridColumns: [GridItem] {
        let size = settings.gridItemSize
        return [GridItem(.adaptive(minimum: size, maximum: size), spacing: gridSpacing)]
    }

    /// O6: 現在の列数（GridColumnCalculator を使用）。itemMinSize は gridItemSize に従う。
    private var currentColumnCount: Int {
        GridColumnCalculator.columns(viewportWidth: gridWidth, itemMinSize: settings.gridItemSize, spacing: gridSpacing)
    }

    private var gridView: some View {
        VStack(spacing: 0) {
            // 4.2c-4: グリッド表示サイズスライダー（ローカルと同じ GridSubToolbar を再利用）。
            GridSubToolbar(settings: settings)
            Divider()
            gridScroll
        }
    }

    private var gridScroll: some View {
        GeometryReader { geo in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    // 4.2c-4: 空白タップで選択解除（最下層・viewport 全面）。ローカルグリッドと同方針。
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(maxWidth: .infinity, minHeight: geo.size.height)
                        .onTapGesture { clearGridSelection() }
                        // C1: 項目外（空白）の右クリックでも並び替えメニューを出す（ローカル相当）。
                        .contextMenu { sortMenu() }

                    LazyVGrid(columns: gridColumns, spacing: gridSpacing) {
                        ForEach(state.books, id: \.id) { book in
                            // 4.2c-4: ハイライトは multiSelection に従う（リストと共有）。
                            RemoteBookCell(book: book, state: state,
                                           selected: state.multiSelection.contains(book.id),
                                           downloaded: downloadedBadge(book.id))
                                .onTapGesture(count: 2) { state.openViewer(book: book) }
                                // 4.2c-4: 単一クリックは修飾子で分岐（⌘トグル / ⇧範囲 / 無修飾置換）。
                                .onTapGesture { handleGridClick(book) }
                                .contextMenu { downloadMenu(book); Divider(); sortMenu() }
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
                .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .topLeading)
            }
            .onAppear { gridWidth = geo.size.width }
            .onChange(of: geo.size.width) { _, w in gridWidth = w }
            // D1: グリッドでも Return で選択中の本を開く。
            .focusable()
            // 自由記載#1: フォーカスリングでグリッド全体が選択状態に見えるのを抑止（ローカル相当）。
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(.return) { openSelected() }
            // O6: 矢印キーでグリッドセルを移動する（4.2c-4: multiSelection を単一に置換しながら移動）。
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow], phases: .down) { press in
                let books = state.books
                guard !books.isEmpty else { return .ignored }
                let cols = max(1, currentColumnCount)
                let total = books.count
                let cur = anchorBookID.flatMap { id in books.firstIndex(where: { $0.id == id }) }
                    ?? state.multiSelection.first.flatMap { id in books.firstIndex(where: { $0.id == id }) }
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
                state.multiSelection = [id]
                anchorBookID = id
                Task { await state.selectBook(id) }
                return .handled
            }
            .task { listFocused = true }
            // 4.2c-4: ⌘/Shift クリック判定用の NSEvent モニタをグリッド表示中だけ有効化する。
            // list→grid 切替直後の初回 ⇧クリックが範囲選択になるよう、アンカー未設定なら現在の選択で seed する。
            .onAppear {
                startModifierMonitor()
                if anchorBookID == nil { anchorBookID = state.multiSelection.first ?? state.selection }
            }
            .onDisappear { stopModifierMonitor() }
        }
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

// MARK: - Top pane control (4.2c-4)

/// 4.2c-4 (smoke v4 自由記載): ローカルの上ペイン切替 [ブラウズ|スタンプ|隠す] をリモートにも
/// 移植したセグメント風コントロール。ローカルは native segmented Picker だが、リモートでは
/// 「スタンプ」を将来機能（リモート RW ブラウザのスタンプ・別フェーズ）の placeholder として
/// グレーアウト（無効）表示する必要があり、segmented Picker は個別 segment の無効化ができない
/// ため、無効化可能な自前のセグメント風 HStack で実装する。
/// - ブラウズ(rectangle.split.3x1): ファセットペインを表示。
/// - スタンプ(tag): 現状グレーアウト（無効）。
/// - 隠す(eye.slash): 上ペイン（ファセット=カラム）を非表示。ユーザー要望の「斜め線」。
private struct RemoteTopPaneControl: View {
    @Bindable var settings: LibrarySettings

    private struct Item { let mode: String; let icon: String; let help: String; let enabled: Bool }
    private static let items: [Item] = [
        Item(mode: "browse", icon: "rectangle.split.3x1", help: "ブラウズ", enabled: true),
        Item(mode: "stamp",  icon: "tag",                 help: "スタンプ", enabled: true),
        Item(mode: "hidden", icon: "eye.slash",           help: "隠す", enabled: true),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(Self.items.enumerated()), id: \.element.mode) { index, item in
                if index > 0 {
                    Divider().frame(height: 16)
                }
                let selected = settings.topPaneMode == item.mode
                Button {
                    settings.topPaneMode = item.mode
                } label: {
                    Image(systemName: item.icon)
                        .frame(width: 32, height: 22)
                        .contentShape(Rectangle())
                        .background(selected ? Color.accentColor.opacity(0.25) : Color.clear)
                }
                .buttonStyle(.borderless)
                .disabled(!item.enabled)
                .foregroundStyle(!item.enabled ? Color.secondary
                                 : (selected ? Color.accentColor : Color.primary))
                .help(item.help)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
        // 注: "stamp"→"browse" の矯正は RemoteLibrarySettingsProvider.makeSettings() で
        // ロード時に一度だけ行う（ビュー出現ごとの書込み・複数ウィンドウでの重複発火を避ける）。
    }
}

// MARK: - Batch edit indicator (4.2c-6a)

/// 4.2c-6a: 詳細ペイン複数選択編集（replace）の進捗バー / 中断(×) / 完了要約。
/// editProgress を読むのはこの子ビューだけにして本体の高頻度再評価を避ける。
private struct RemoteBatchEditButton: View {
    @Bindable var state: RemoteLibraryState

    private static func summaryStyle(_ kind: RemoteLibraryState.BatchSummaryKind) -> (icon: String, color: Color) {
        switch kind {
        case .success:   return ("checkmark.circle", .secondary)
        case .warning:   return ("exclamationmark.triangle", .orange)
        case .cancelled: return ("xmark.circle", .secondary)
        case .info:      return ("info.circle", .secondary)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if let p = state.editProgress {
                ProgressView(value: Double(p.done) / Double(max(1, p.total))).frame(width: 80)
                Text("\(p.done)/\(p.total)").font(.caption).foregroundStyle(.secondary)
                Button { state.cancelBatchEdit() } label: { Image(systemName: "xmark.circle") }
                    .help("一括編集を中断")
            } else if let summary = state.editSummary {
                let style = Self.summaryStyle(state.editSummaryKind)
                Label(summary, systemImage: style.icon).font(.caption).foregroundStyle(style.color)
            }
        }
    }
}

// MARK: - Download button (isolated)

/// 4.2c-3: ダウンロード進捗バー / 中断(×) / 開始ボタン。downloadProgress（64KB ごと更新）を
/// 読むのはこの子ビューだけにして、RemoteLibraryView 本体（ファセットペイン等）の高頻度
/// 再評価＝チラつきを防ぐ。
private struct RemoteDownloadButton: View {
    @Bindable var state: RemoteLibraryState

    /// 4.2c-3: 要約の種別に応じたアイコン/色。成功のみ=✓ / 失敗あり=⚠(橙) / 中断=✕ / 情報=ⓘ。
    private static func summaryStyle(_ kind: RemoteLibraryState.BatchSummaryKind) -> (icon: String, color: Color) {
        switch kind {
        case .success:   return ("checkmark.circle", .secondary)
        case .warning:   return ("exclamationmark.triangle", .orange)
        case .cancelled: return ("xmark.circle", .secondary)
        case .info:      return ("info.circle", .secondary)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            if let p = state.batchProgress {
                // D2b: 進捗バーは「完了件数 + 進行中ファイルのバイト割合」で滑らかに動かす。
                // ラベルは進行中の項目番号（1始まり。0/1 ではなく 1/1）を表示する。
                let frac = state.downloadProgress?.fraction ?? 0
                let value = (Double(p.done) + frac) / Double(max(1, p.total))
                let current = min(p.done + 1, p.total)
                ProgressView(value: min(1, max(0, value))).frame(width: 80)
                Text("\(current)/\(p.total)").font(.caption).foregroundStyle(.secondary)
                Button { state.cancelBatchDownload() } label: {
                    Image(systemName: "xmark.circle")
                }
                .help("ダウンロードを中断")
            } else {
                if let summary = state.batchSummary {
                    let style = Self.summaryStyle(state.batchSummaryKind)
                    Label(summary, systemImage: style.icon).font(.caption).foregroundStyle(style.color)
                }
                Button { state.startBatchDownload() } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .help("選択した書籍をダウンロード")
                .disabled(state.multiSelection.isEmpty)
            }
        }
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
            // 4.2c-4: 表紙を 2:3 の枠で列幅に追従させる（gridItemSize スライダーで拡縮・ローカル相当）。
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
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
            // 自由記載#3: ダウンロード中の本にはリスト DL 列と同じ進捗リングを重ねる。
            .overlay {
                if let prog = state.downloadProgress, prog.bookID == book.id {
                    ProgressView(value: prog.fraction)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .padding(6)
                        .background(.thinMaterial, in: Circle())
                }
            }

            // smoke v2 自由記載: タイトルは「最大2行」だと1行で収まる本だけセル全高が低くなり、
            // LazyVGrid が行内の高さ違いセルを縦中央寄せするため左端等が上下にずれて見える。
            // reservesSpace: true で常に2行分の高さを確保し、全セル高さを統一してずれを解消する。
            Text(book.title)
                .font(.caption)
                .lineLimit(2, reservesSpace: true)
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
