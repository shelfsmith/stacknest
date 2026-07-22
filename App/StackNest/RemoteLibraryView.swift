// SPDX-License-Identifier: MIT
import AppCore
import AppKit
import CoreGraphics
import LibraryServerAPI
import LibraryStore
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

    /// G12b-1 Task 5 Fix: 自 window への参照。メインメニュー由来の削除通知（⌫/⌘⌫）を
    /// frontmost（key）window のみで処理するための判定に使う（ローカル LibraryBrowserView と同方針）。
    @State private var hostWindow: NSWindow?

    /// 4.2c-4: グリッドの ⌘/Shift クリック複数選択用。NSEvent ローカルモニタで連続追跡する。
    @State private var currentModifiers: NSEvent.ModifierFlags = []
    @State private var modifierMonitor: Any?
    /// Shift クリックの範囲選択アンカー。
    @State private var anchorBookID: Int?
    /// G12b-1 Task 4 Fix: ⇧+矢印による範囲選択の伸長先（lead）。⇧ シーケンス中は anchor を
    /// 据え置きつつ lead だけを 1 マスずつ進める（Finder 同様の累積拡張）。非 shift の選択操作
    /// （anchor が動く操作）が起きたら nil にリセットし、次の ⇧ シーケンス開始時に anchor から再 seed する。
    @State private var rangeLeadBookID: Int?

    /// Task 3: paged per の TextField 入力（数字のみ・commit 時に clamp）。
    @State private var perInput = ""

    /// 4.2b-1b-1: per TextField のフォーカス追跡（フォーカスを外したときに commitPerInput() を発火）。
    @FocusState private var perFieldFocused: Bool

    /// B2: サイドバー列表示制御（NavigationSplitView columnVisibility binding）。
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    /// 4.2c-8 B1(v2): リモートライブラリ設定シート（現状ラベルのみ・RW）の表示フラグ。
    @State private var showRemoteSettings = false

    /// G12b-2 Task 5: 重複検出結果（`.sheet(item:)` 提示用の Identifiable ラッパ）。nil = 非表示。
    @State private var dupScanResult: RemoteDuplicateScanResult?
    /// G12b-2 Task 5: 重複スキャン実行中フラグ（メニュー連打の多重起動防止 + 簡易 ProgressView 表示用）。
    @State private var isScanningDuplicates = false

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
        // G12b-1 Task 5 Fix: hostWindow を捕捉（メニュー削除通知の frontmost 判定用）。
        .background(WindowAccessor { window in
            if self.hostWindow == nil { self.hostWindow = window }
        })
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
                // 4.2c-8 B1(v2): 上ペイン切替をローカルと同じ Picker segmented に揃える
                // （カスタム RemoteTopPaneControl のごちゃつきを解消・スタンプは tag のまま）。
                ToolbarItem(placement: .primaryAction) {
                    Picker("", selection: $settings.topPaneMode) {
                        Image(systemName: "rectangle.split.3x1").tag("browse")
                        Image(systemName: "tag").tag("stamp")
                        Image(systemName: "eye.slash").tag("hidden")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                    .help("上ペイン切替")
                }
                // 4.2c-8 B1(v2): ラベル編集は歯車「ライブラリ設定」（現状ラベルのみ・RW）。
                if state.canEdit {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showRemoteSettings = true
                        } label: {
                            Label("ライブラリ設定", systemImage: "gearshape")
                        }
                        .help("ライブラリ設定")
                    }
                }
                // G10: 詳細ペインの表紙表示を per-browser でトグル（このウィンドウのみ・既定 ON）。
                ToolbarItem(placement: .primaryAction) {
                    Button { state.showDetailCover.toggle() } label: {
                        Label("詳細ペインの表紙", systemImage: state.showDetailCover ? "photo.fill" : "photo")
                    }
                    .help("詳細ペインの表紙表示を切り替え")
                }
            }
        }
        .sheet(isPresented: $showRemoteSettings) {
            RemoteLibrarySettingsSheet(state: state, settings: settings)
        }
        // 4.2c-9: メニューコマンドのルーティング用（リモートターゲット）。openSettingsAction は
        // この per-window の設定シートを開く（focusedSceneValue が選んだアクティブウィンドウのみ）。
        .focusedSceneValue(\.browserCommandTarget,
            RemoteCommandTarget(state: state, settings: settings,
                                openSettingsAction: { showRemoteSettings = true }) as (any BrowserCommandTarget)?)
        // G12b-3c Task 9: Edit メニューの取り消す/やり直す をこのウィンドウの
        // RemoteLibraryState.undo()/redo() へルーティングするための FocusedValue 公開。
        // appState と同じ .focusedSceneValue パターン（ローカル LibraryWindowContainer と対）。
        .focusedSceneValue(\.remoteState, state)
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
        // Phase C-②.1: File メニュー「ライブラリから削除（⌫）」/「ファイルをゴミ箱に移動（⌘⌫）」を
        // admin リモートで受信。
        // G12b-1 Task 5 Fix: メインメニューの keyboardShortcut がテーブル/グリッドの keyDown より
        // 先に消費するため、grid/list どちらの表示でもこの通知経路が唯一の到達点になる。よって
        // listFocused（grid 専用フォーカス）ではなく、ローカル LibraryBrowserView と同じ
        // hostWindow（frontmost/key window）ガードに揃える。複数リモートウィンドウでは
        // フロント窓のみが反応する。
        .onReceive(NotificationCenter.default.publisher(for: .stacknestDeleteFromLibraryRequest)) { _ in
            guard hostWindow == nil || NSApp.keyWindow === hostWindow else { return }
            guard state.canDelete else { return }
            let ids = !state.multiSelection.isEmpty ? state.multiSelection : (state.selection.map { Set([$0]) } ?? [])
            RemoteDeleteCommand.confirmAndDelete(ids: ids, state: state, trash: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .stacknestMoveToTrashRequest)) { _ in
            guard hostWindow == nil || NSApp.keyWindow === hostWindow else { return }
            guard state.canDelete else { return }
            let ids = !state.multiSelection.isEmpty ? state.multiSelection : (state.selection.map { Set([$0]) } ?? [])
            RemoteDeleteCommand.confirmAndDelete(ids: ids, state: state, trash: true)
        }
        // G12b-2 Task 5: WindowCommands「重複を検出…」（.openDuplicateScan）をローカルと同じ
        // hostWindow（frontmost/key window）ガードで受信する。edit 未満（read）では起動しない。
        .onReceive(NotificationCenter.default.publisher(for: .openDuplicateScan)) { _ in
            guard hostWindow == nil || NSApp.keyWindow === hostWindow else { return }
            guard state.canEdit, !isScanningDuplicates else { return }
            isScanningDuplicates = true
            Task {
                let reply = await state.scanDuplicatesNow()
                isScanningDuplicates = false
                if let reply { dupScanResult = RemoteDuplicateScanResult(reply: reply) }
            }
        }
        .sheet(item: $dupScanResult) { result in
            RemoteDuplicateScanSheet(reply: result.reply, state: state)
        }
        // G12b-2 Task 5: スキャン中の簡易インジケータ（サーバ側ハッシュ算出に時間がかかりうる）。
        .overlay {
            if isScanningDuplicates {
                ProgressView("重複を検索中…")
                    .padding(16)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
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

    /// 詳細 DetailPaneView。edit トークン時は編集可（canEdit = state.canEdit）。
    /// v1: 単一本のメタデータ編集のみ。カバー・クロップ・マルチ選択編集は no-op。
    private var detailPane: some View {
        DetailPaneView(
            books: state.detailBookRows(),
            librarySettings: settings,   // 4.2c-8: サーバ同期ラベルを詳細ペインにも反映
            bundleURL: URL(fileURLWithPath: "/"),
            loader: nil,
            canEdit: state.canEdit,
            showCover: state.showDetailCover,
            canShowFinder: false,   // リモートはローカルにファイルが無いため非表示
            remoteFileExtension: state.detail?.fileExtension,
            remoteFilename: state.detail?.filename,
            ratingEditable: true,   // 4.2c-9: レートは R でも編集可（共有評価）
            onSetRating: { stars, ids in state.setRating(ids: ids, stars) },
            unseenEditable: true,   // 4.2c-9: 未読も R でも編集可（共有閲覧状態）
            onSetUnseen: { value, ids in state.setUnseen(ids: ids, value) },
            directionEditable: true,
            onSetPageDirection: { id, dir in Task { await state.setRemoteDirection(bookID: id, direction: dir) } },
            onApplyPatch: { id, patch in Task { await state.applyRemotePatch(bookID: id, patch: patch) } },
            onApplyPatchMulti: { ids, patch in state.startBatchEdit(ids: Set(ids), patch: patch) },
            onSetCover: { name, id in
                await state.setRemoteCover(bookID: id, coverImageName: name, setName: true, cropJSON: nil, setCrop: false)
            },
            onClearCrop: { id in
                Task { await state.setRemoteCover(bookID: id, coverImageName: nil, setName: false, cropJSON: nil, setCrop: true) }
            },
            onSetCrop: { id, json in
                Task { await state.setRemoteCover(bookID: id, coverImageName: nil, setName: false, cropJSON: json, setCrop: true) }
            },
            onJump: { field, value in Task { await state.jumpToFilter(field: field, value: value) } },
            onError: { _ in },
            coverImage: { id in await state.coverImage(id) },
            remoteCoverCandidates: { id in await state.coverCandidates(bookID: id) },
            remoteEntryImage: { id, name in await state.entryImage(bookID: id, name: name) },
            onSetExternalCover: { data, crop, id in
                let json = crop.map(BookRow.encodeCoverCropRect)
                await state.setRemoteExternalCover(bookID: id, imageData: data, cropJSON: json)
            },
            coverVersion: state.coverVersion,
            // G21 #5: 右クリック「表紙を再生成」。外部表紙は disabled 済みなので、
            // ここに来る呼び出しは常に上書きしてよいケースのみ。
            onRegenerateCover: { id in
                Task { await state.regenerateCover(bookID: id) }
            }
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
                    labelFor: { settings.browseLabel(for: $0) },   // 4.2c-8: サーバ同期ラベルを反映
                    refreshKey: state.facetRefreshKey,
                    facetValues: { col, upper in await state.facetValues(col, upper) }
                )
                Divider()
            } else if settings.topPaneMode == "stamp" {
                RemoteStampPaneView(state: state, settings: settings)
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
        .task {
            await state.reload()
            await state.loadStampDefinitions()
            // G12b-2 Task 4: 右クリックの「お気に入り」「シェルフに追加」は state.shelves に依存する。
            // 従来は RemoteSidebarView の .task でのみロードしており、サイドバー非表示時は空のまま
            // だった。サイドバー表示に依存せず載るよう、ここでも一度ロードする（RemoteSidebarView 側の
            // ロードと重複しても loadShelves() は単純な再取得で副作用は無い）。
            await state.loadShelves()
            // 4.2c-8: サーバのラベルカスタマイズを取得し、この per-window settings の override に反映。
            let labels = await state.fetchLabels()
            settings.remoteFieldLabelOverride = labels.customFieldLabels
            settings.remoteBookTypeLabelOverride = labels.customBookTypeLabels
            // G8a: /events 購読ループ。view 消滅で .task がキャンセルされループ終了する（stored task 不要）。
            await state.runLiveSync()
        }
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
        // G8a: settingsChanged 受信のたびに View 所有のラベル override を再取得する（.task と同一処理）。
        .onChange(of: state.settingsChangeToken) { _, _ in
            Task {
                let labels = await state.fetchLabels()
                settings.remoteFieldLabelOverride = labels.customFieldLabels
                settings.remoteBookTypeLabelOverride = labels.customBookTypeLabels
            }
        }
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

            // 4.2c-6a (smoke v2/v3/v4 自由記載): このリモート接続が編集可か閲覧のみかを一目で示す。
            // v4: 小さい pencil は棒に見えるため square.and.pencil に＋フォントを拡大。
            // Phase C-②.1: 接続 tier（read/edit/admin）を一目で示す。admin=ローカルコントロール。
            Label(state.tier == .admin ? "管理者" : (state.canEdit ? "編集可" : "閲覧のみ"),
                  systemImage: state.tier == .admin ? "key.fill" : (state.canEdit ? "square.and.pencil" : "eye"))
                .font(.callout)
                .foregroundStyle(state.canEdit ? Color.accentColor : .secondary)
                .help(state.tier == .admin ? "管理者（ローカルコントロール・フル操作）"
                      : (state.canEdit ? "編集可能（RW トークン）" : "閲覧のみ（R トークン）"))

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
        rangeLeadBookID = nil  // Fix: anchor が動くので lead をリセット（次回 ⇧ 開始時に再 seed）
        Task { await state.selectBook(book.id) }
    }

    /// ⌘: トグル。
    private func toggleSelection(_ book: BookListItemDTO) {
        if state.multiSelection.contains(book.id) {
            state.multiSelection.remove(book.id)
        } else {
            state.multiSelection.insert(book.id)
            anchorBookID = book.id
            rangeLeadBookID = nil  // Fix: anchor が動くので lead をリセット
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
        // Fix: 以降 ⇧+矢印で続けて伸ばすとき、クリックした位置から再開できるよう lead を同期する。
        rangeLeadBookID = book.id
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
        rangeLeadBookID = nil  // Fix: 選択解除で anchor も消えるので lead もリセット
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

    /// Task 3: グリッドセル右クリックのレート/種類/未読/開く（list の row context menu と同等）。
    /// レート/未読は共有状態のため canEdit ゲート不要。種類のみ canEdit でゲートする。
    /// G12b-1 whole-branch fix: SwiftUI の .contextMenu は右クリックで選択を更新しないため、
    /// *ForSelection（既存選択集合頼り）を呼ぶと「右クリックしたセル」ではなく既存選択に適用されてしまう。
    /// 削除ボタンと同じ解決（multiSelection に含まれていれば選択集合、無ければ右クリックしたセル単体）を使う。
    @ViewBuilder
    private func rateTypeUnreadOpenMenu(_ book: BookListItemDTO) -> some View {
        let ids: Set<Int> = state.multiSelection.contains(book.id) ? state.multiSelection : [book.id]
        Button("ビューアで開く") { state.openViewer(book: book) }
        Menu("レート") {
            Button("レートなし") { state.setRating(ids: Array(ids), 0) }
            ForEach(1...5, id: \.self) { s in
                Button(String(repeating: "★", count: s)) { state.setRating(ids: Array(ids), s) }
            }
        }
        if state.canEdit {
            Menu("種類") {
                ForEach(0...5, id: \.self) { t in
                    Button(settings.bookTypeLabel(t)) { state.setBookType(ids: ids, t) }
                }
            }
        }
        Button("未読チェック") { state.toggleUnread(ids: ids) }
        // G12b-2 Task 4: お気に入り 追加/削除・シェルフに追加（edit 未満では出さない）。
        // シェルフに追加の対象は「スマートでなく、お気に入りでもない」棚（RemoteSidebarView.userShelves
        // と同じ判定）。kind=="user" だけだとスマート棚も含んでしまう（サーバは kind を常に "user" で
        // 発行し isSmart で区別するため）。スマート棚は membership 変更不可（サーバ 409）なので必ず除外する。
        if state.canEdit {
            if state.favoritesShelfID != nil {
                // G14 Task 5 レビュー修正: 判定はトグル対象の ids（右クリック起点。multiSelection に
                // 含まれていれば選択集合、無ければ右クリックしたセル単体）で行う。.contextMenu は
                // 右クリックで選択を更新しないため、allSelectedAreFavorites（selection/multiSelection
                // 由来）だと選択外セルの右クリックでラベルと実対象が食い違う。
                let add = !state.allAreFavorites(ids)
                Button(add ? "お気に入りに追加" : "お気に入りから削除") {
                    Task { await state.toggleFavorite(ids: ids, add: add) }
                }
            }
            let userShelves = state.shelves.filter { !$0.isSmart && $0.kind != "favorites" }
            if !userShelves.isEmpty {
                Menu("シェルフに追加") {
                    ForEach(userShelves, id: \.id) { sh in
                        Button(sh.title) { Task { await state.addSelectionToShelf(sh.id, ids: ids) } }
                    }
                }
            }
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
                    // 4.2c-8: サーバ同期ラベルを反映（A2）。
                    let title = settings.label(for: col)
                    Text(state.sortKey == key
                         ? "\(title) \(state.ascending ? "↑" : "↓")"
                         : title)
                }
            }
        }
    }

    // MARK: - Grid mode

    private let gridSpacing: CGFloat = 16

    /// O6: グリッド幅を GeometryReader で取得し、列数計算に使う。
    @State private var gridWidth: CGFloat = 0

    /// G12b-1 Task 4: グリッド可視高さ（GeometryReader）。PageUp/PageDown の可視行数近似に使う。
    @State private var gridHeight: CGFloat = 0

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

    /// G12b-1 Task 4: PageUp/PageDown の 1 ページ相当の行数。可視高さ / セル高さで近似。
    /// gridHeight が未計測（0）等の病的値では 4 行にフォールバックする。
    private var currentPageRows: Int {
        let cellExtent = settings.gridItemSize + gridSpacing
        guard gridHeight > 0, cellExtent > 0 else { return 4 }
        return max(1, Int(gridHeight / cellExtent))
    }

    private var gridView: some View {
        VStack(spacing: 0) {
            // 4.2c-4: グリッド表示サイズスライダー（ローカルと同じ GridSubToolbar を再利用）。
            GridSubToolbar(settings: settings)
            Divider()
            gridScroll
        }
    }

    /// G16 E1: グリッドの先頭スクロールアンカー ID。ユーザー操作由来のリセット
    /// （listScrollResetVersion 変化）で ScrollViewReader.scrollTo の対象にする。
    private static let gridTopAnchorID = "remoteGridTop"

    private var gridScroll: some View {
        GeometryReader { geo in
            // G16 E1: ScrollView（LazyVGrid）は無限スクロール後にフィルタで件数が減っても
            // スクロール位置が自動で先頭へ戻らない（List と違い NSScrollView のオフセットを保持する
            // だけの実装のため、旧オフセットがそのまま新しい＝短くなったコンテンツに適用され、
            // リストと同様の「空の末尾に取り残される」不具合が起きる）。ScrollViewReader で
            // listScrollResetVersion の変化を監視し、ユーザー操作由来のリセット時のみ先頭へ戻す。
            ScrollViewReader { proxy in
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
                            // G14 fu(smoke バグ2): favorited を ForEach body で読むことで、この行に
                            // favoriteBookIDs への observation 依存を張る。これが無いと favoriteBookIDs
                            // 変更でセルが再評価されず、.contextMenu closure（lazy 評価）内の
                            // allAreFavorites が古いまま＝再選択するまでラベルが反映されない。
                            RemoteBookCell(book: book, state: state,
                                           selected: state.multiSelection.contains(book.id),
                                           downloaded: downloadedBadge(book.id),
                                           favorited: state.favoriteBookIDs.contains(book.id))
                                .onTapGesture(count: 2) { state.openViewer(book: book) }
                                // 4.2c-4: 単一クリックは修飾子で分岐（⌘トグル / ⇧範囲 / 無修飾置換）。
                                .onTapGesture { handleGridClick(book) }
                                .contextMenu {
                                    downloadMenu(book)
                                    Divider()
                                    rateTypeUnreadOpenMenu(book)
                                    if state.canDelete {
                                        Divider()
                                        let ids = (state.multiSelection.contains(book.id) && !state.multiSelection.isEmpty)
                                            ? state.multiSelection : Set([book.id])
                                        Button("ライブラリから削除", role: .destructive) {
                                            RemoteDeleteCommand.confirmAndDelete(ids: ids, state: state, trash: false)
                                        }
                                        Button("ファイルをゴミ箱に移動…", role: .destructive) {
                                            RemoteDeleteCommand.confirmAndDelete(ids: ids, state: state, trash: true)
                                        }
                                    }
                                    Divider()
                                    sortMenu()
                                }
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
                .id(Self.gridTopAnchorID)
            }
            .onAppear { gridWidth = geo.size.width; gridHeight = geo.size.height }
            .onChange(of: geo.size.width) { _, w in gridWidth = w }
            .onChange(of: geo.size.height) { _, h in gridHeight = h }
            // G16 E1: ユーザー操作由来のリセット（filter/sort/sidebar/mode/search）でのみ先頭へ戻す。
            // liveReload/loadMore/reload(clearFirst: false)（位置保持経路）では version が不変。
            .onChange(of: state.listScrollResetVersion) { _, _ in
                proxy.scrollTo(Self.gridTopAnchorID, anchor: .top)
            }
            // D1: グリッドでも Return で選択中の本を開く。
            .focusable()
            // 自由記載#1: フォーカスリングでグリッド全体が選択状態に見えるのを抑止（ローカル相当）。
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(.return) { openSelected() }
            // G12b-1 Task 4: テンキー Enter（keyCode 76 / character 0x03）でも選択中の本を開く。
            // メインの Return（0x0D）とは character が異なるため別 KeyEquivalent として登録する。
            .onKeyPress(keys: [KeyEquivalent("\u{3}")], phases: .down) { _ in openSelected() }
            // O6: 矢印キーでグリッドセルを移動する（4.2c-4: multiSelection を単一に置換しながら移動）。
            // G12b-1 Task 4: ⌘↑/⌘↓ で先頭/末尾へ、⇧+矢印で anchor 基準の範囲選択を追加。
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow], phases: .down) { press in
                let books = state.books
                guard !books.isEmpty else { return .ignored }
                let cols = max(1, currentColumnCount)
                let total = books.count
                let cur = anchorBookID.flatMap { id in books.firstIndex(where: { $0.id == id }) }
                    ?? state.multiSelection.first.flatMap { id in books.firstIndex(where: { $0.id == id }) }

                // ⌘↑/⌘↓: 先頭/末尾へジャンプ（単一選択に置換）。
                if press.modifiers.contains(.command), press.key == .upArrow || press.key == .downArrow {
                    let t = press.key == .upArrow ? GridNavigator.firstIndex(total: total) : GridNavigator.lastIndex(total: total)
                    guard let t else { return .handled }
                    let id = books[t].id
                    state.multiSelection = [id]
                    anchorBookID = id
                    rangeLeadBookID = nil  // Fix: anchor が動くので lead をリセット
                    Task { await state.selectBook(id) }
                    return .handled
                }

                let direction: GridNavigator.Direction
                switch press.key {
                case .upArrow:    direction = .up
                case .downArrow:  direction = .down
                case .leftArrow:  direction = .left
                case .rightArrow: direction = .right
                default: return .ignored
                }
                // ⇧+矢印: anchor 基準の範囲選択。lead（伸長先）を anchor とは別に @State で追跡し、
                // ⇧+矢印を押すたびに lead の index から nextIndex で 1 マスずつ伸ばす（anchor は据え置き）。
                // これにより Finder 同様、⇧+矢印の連打で選択範囲が累積的に拡張される
                // （Fix: 従来は毎回 anchor を起点に nextIndex していたため、範囲が [anchor, anchor+1] に固定されていた）。
                // ⇧ シーケンス開始時（lead 未 seed＝直前が非 shift 操作）は anchor の位置から seed する。
                // anchor 未設定時は通常の単一選択にフォールバック。
                if press.modifiers.contains(.shift),
                   let a = anchorBookID.flatMap({ id in books.firstIndex(where: { $0.id == id }) }) {
                    let leadCur = rangeLeadBookID.flatMap { id in books.firstIndex(where: { $0.id == id }) } ?? a
                    guard let leadTarget = GridNavigator.nextIndex(current: leadCur, direction: direction, total: total, columns: cols) else {
                        return .handled  // 端で消費（スクロール等に伝播させない）
                    }
                    state.multiSelection = Set(GridNavigator.rangeIndices(anchor: a, target: leadTarget).map { books[$0].id })
                    rangeLeadBookID = books[leadTarget].id
                    syncDetailAfterMulti()
                    return .handled
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
                rangeLeadBookID = nil  // Fix: 非 shift 選択で anchor が動いたので lead をリセット（次回 ⇧ 開始時に再 seed）
                Task { await state.selectBook(id) }
                return .handled
            }
            // G12b-1 Task 4: Home/End/PageUp/PageDown でジャンプ移動（単一選択に置換）。
            .onKeyPress(keys: [.home, .end, .pageUp, .pageDown], phases: .down) { press in
                let books = state.books
                guard !books.isEmpty else { return .ignored }
                let cols = max(1, currentColumnCount)
                let cur = anchorBookID.flatMap { id in books.firstIndex(where: { $0.id == id }) } ?? 0
                let target: Int?
                switch press.key {
                case .home:     target = GridNavigator.firstIndex(total: books.count)
                case .end:      target = GridNavigator.lastIndex(total: books.count)
                case .pageUp:   target = GridNavigator.pageIndex(current: cur, total: books.count, columns: cols, rows: currentPageRows, up: true)
                case .pageDown: target = GridNavigator.pageIndex(current: cur, total: books.count, columns: cols, rows: currentPageRows, up: false)
                default:        target = nil
                }
                guard let t = target else { return .handled }
                let id = books[t].id
                state.multiSelection = [id]
                anchorBookID = id
                rangeLeadBookID = nil  // Fix: anchor が動くので lead をリセット
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
    /// G14 fu(smoke バグ2): お気に入り所属。親が ForEach body で favoriteBookIDs を読んで算出することで
    /// この行に observation 依存を張る（右クリックの動的トグルラベルを即時反映させるため）。表示にも使う。
    let favorited: Bool

    /// V2: 無表紙・取得失敗を spinner に留めずプレースホルダへ解決するための状態。
    private enum CoverPhase: Equatable {
        case loading
        case loaded(CGImage)
        case noCover
    }

    @State private var coverPhase: CoverPhase = .loading

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.15))
                switch coverPhase {
                case .loaded(let cg):
                    // 4.2c-6b smoke R2: ローカル BookCell と同じ croppedImage でクロップ適用。
                    Image(decorative: BookCell.croppedImage(
                        cg, rect: BookRow.decodeCoverCropRect(json: book.coverCropRectJSON)), scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                case .loading:
                    ProgressView().controlSize(.small)
                case .noCover:
                    // 詳細ペインの無表紙アイコン（DetailPaneView.CoverImageView）と同じ SF Symbol に合わせる。
                    Image(systemName: "book.closed")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
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
            .overlay(alignment: .topLeading) {
                // G14 fu(smoke バグ2): お気に入りをグリッドでも視認できるように（favorited 依存の可視化も兼ねる）。
                if favorited {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.pink)
                        .padding(4)
                        .background(.thinMaterial, in: Circle())
                        .padding(4)
                        .help("お気に入り")
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
        // 4.2c-6b smoke A4/R2: 表紙差し替えで book.id は不変だが coverVersion（thumbnail
        // mtime+size 由来）が変わる。クロップのみの変更は coverVersion を変えない（thumbnail
        // 非再生成）ため coverCropRectJSON も複合キーに含め、両方の変化で再取得・再クロップさせる。
        .task(id: "\(book.id)#\(book.coverVersion ?? "")#\(book.coverCropRectJSON ?? "")") {
            if !book.hasCover {
                coverPhase = .noCover
                return
            }
            coverPhase = .loading
            if let data = await state.cover(bookID: book.id),
               let ns = NSImage(data: data),
               let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                coverPhase = .loaded(cg)
            } else {
                // 取得失敗も spinner に留めずプレースホルダへ解決する。
                coverPhase = .noCover
            }
        }
    }
}
