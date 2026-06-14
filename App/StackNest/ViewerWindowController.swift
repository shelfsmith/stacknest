// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import LibraryStore
import AppCore
import OSLog

/// 内蔵ビューワの専用ウィンドウを管理する。1 冊の BookContent を ViewerModel で遷移し
/// ViewerCanvasView で描画。キー処理と左右ゾーンクリック送り、HUD 自動非表示を担う。
@MainActor
final class ViewerWindowController: NSWindowController, NSWindowDelegate {
    private static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "Viewer")

    private var content: BookContent
    private var book: BookRow
    private var model: ViewerModel
    private let onClose: () -> Void

    // Phase 2.6b-2 injected closures
    private let loadNextVolume: (BookRow) async -> NextVolume?
    private let loadPrevVolume: (BookRow) async -> NextVolume?
    private let persistState: (BookRow, Int, Bool, Bool) -> Void          // (book, lastPage, spreadEnabled, coverOffset)
    private let persistPageOverride: (BookRow, Int, Int?) -> Void          // (book, page, mode int or nil)
    /// Phase 2.6b-2 D3: コールバック。本のページ方向が変わったら AppState 経由で DB に永続化する。
    var onSetBookPageDirection: ((Int, PageDirection) -> Void)?

    // Per-book spread state
    private var overrides: [Int: PageLayoutOverride] = [:]
    private var orientations: [Int: Bool] = [:]                            // page → isLandscape (true=横長)。表示/プリフェッチで学習
    private var autoAdvanceTimer: Timer?
    /// 巻スワップ中フラグ。await content.pageCount 中はあらゆる入力/自動進行を無効化し、
    /// 旧 model と新 content が混在する瞬間を作らない（atomic swap を保証する）。
    private var isSwapping = false
    /// 前回の読書位置（lastPage）。> 0 の場合のみ present() でダイアログを表示する。
    private let resumeLastPage: Int
    /// resume ダイアログを 1 回だけ表示するフラグ。
    private var didShowResumeDialog = false

    private let canvas = ViewerCanvasView()
    private var hudHosting: PassthroughHostingView<ViewerHUDView>?
    private var hudVisible = true
    private var idleTimer: Timer?
    /// 一時ノートテキスト。updateHUD() はこの値を passthrough するので progress 更新でノートが消えない。
    private var hudNoteText: String?
    /// ノート専用タイマー（~3.0s）。idleTimer とは独立して管理し、progress 更新と競合しない。
    private var hudNoteTimer: Timer?
    /// ノート表示時間（秒）。idle-hide はこの時間以上 HUD を表示し続ける。
    private let hudNoteDuration: TimeInterval = 3.0
    /// ノートなし時の idle-hide 遅延（秒）。
    private let hudIdleHideDelay: TimeInterval = 2.0
    private var prefetch: [Int: NSImage] = [:]
    private let bindings = ViewerKeyBindings.load()
    /// ヘルプオーバーレイ（? / h）。PassthroughHostingView で canvas にジェスチャを通す。
    private var helpOverlayHosting: PassthroughHostingView<ViewerHelpOverlayView>?
    private var helpOverlayTimer: Timer?

    init(
        content: BookContent,
        book: BookRow,
        pageCount: Int,
        options: ViewerOptions,
        initialState: ResolvedViewerState,
        loadNextVolume: @escaping (BookRow) async -> NextVolume?,
        loadPrevVolume: @escaping (BookRow) async -> NextVolume?,
        persistState: @escaping (BookRow, Int, Bool, Bool) -> Void,
        persistPageOverride: @escaping (BookRow, Int, Int?) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.content = content
        self.book = book
        self.model = ViewerModel(pageCount: pageCount, options: options)
        self.loadNextVolume = loadNextVolume
        self.loadPrevVolume = loadPrevVolume
        self.persistState = persistState
        self.persistPageOverride = persistPageOverride
        self.onClose = onClose
        self.overrides = initialState.overrides
        self.resumeLastPage = initialState.lastPage

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        super.init(window: window)
        window.delegate = self

        // 初期表示状態をモデルへ反映
        model.setCoverOffset(initialState.coverOffset)
        model.setDisplayMode(initialState.spreadEnabled ? .spread : .single)
        model.goTo(page: initialState.lastPage)

        setupContent()

        // 初期見開きを構築し、読書位置の見開きへアンカー。
        // 向き（横長）は未知なので暫定で全縦長と仮定する。表示時にデコード画像から学習し、
        // 判明次第に再ページングする（recordOrientation 経由）。
        rebuildSpreads()   // 末尾で model.setSpreads(...) し currentPage から currentSpreadIndex を再アンカー
        loadCurrentPage()  // スプレッド構築・再アンカー後に初回ロード（resume 後の黒画面バグを防ぐ）
        // 続きから開いた場合のダイアログは present() でウィンドウ表示後にシート表示する。
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupContent() {
        guard let window = window else { return }
        let container = KeyCatcherView()
        container.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }
        container.onMouseMoved = { [weak self] in self?.showHUDThenScheduleHide() }
        container.translatesAutoresizingMaskIntoConstraints = false

        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.onZoneClick = { [weak self] leftHalf in self?.handleZoneClick(leftHalf: leftHalf) }
        canvas.firstOnRight = (model.options.pageDirection == .rightToLeft)
        container.addSubview(canvas)

        let hud = PassthroughHostingView(rootView: ViewerHUDView(progressText: model.progressText, progressFraction: model.progressFraction, isVisible: true, pageDirection: model.options.pageDirection))
        hud.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hud)
        hudHosting = hud

        // ヘルプオーバーレイ: center-anchored PassthroughHostingView（初期非表示）
        let helpOverlay = PassthroughHostingView(rootView: ViewerHelpOverlayView(isVisible: false))
        helpOverlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(helpOverlay)
        helpOverlayHosting = helpOverlay

        window.contentView = container
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: container.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hud.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hud.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hud.topAnchor.constraint(equalTo: container.topAnchor),
            hud.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            // ヘルプオーバーレイはウィンドウ中央に固定（サイズは SwiftUI コンテンツに依存）。
            helpOverlay.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            helpOverlay.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        let tracking = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseMoved], owner: container, userInfo: nil)
        container.addTrackingArea(tracking)
        window.makeFirstResponder(container)
        showHUDThenScheduleHide()
    }

    func present() {
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Phase 2.6b-2 T-F1: 全画面で開く設定が ON かつウィンドウが通常表示のとき全画面へ移行する。
        // toggleFullScreen は window が on-screen になった直後に呼ぶ必要があるため
        // DispatchQueue.main.async で 1 runloop 遅延させる。
        // resume ダイアログは全画面遷移完了後（windowDidEnterFullScreen）に表示する（レース防止）。
        if ViewerSettings.shared.openFullScreenByDefault,
           let w = window,
           !w.styleMask.contains(.fullScreen) {
            DispatchQueue.main.async { [weak w] in
                w?.toggleFullScreen(nil)
            }
            // resume ダイアログは windowDidEnterFullScreen で表示するため、ここでは呼ばない。
        } else {
            showResumeDialogIfNeeded()
        }
    }

    /// 続きから読む場合（resumeLastPage > 0）のみ、ウィンドウ表示後に一度だけシートダイアログを表示する。
    private func showResumeDialogIfNeeded() {
        guard resumeLastPage > 0, !didShowResumeDialog else { return }
        didShowResumeDialog = true
        showResumeDialog(forLastPage: resumeLastPage)
    }

    /// 指定の lastPage（> 0）で「続きから / 最初から」シートを表示する汎用版。
    /// 初回オープン（showResumeDialogIfNeeded）と巻送り（performSwap）の双方から使う（4.2b-6）。
    /// 呼び出し時点で model は lastPage に移動済みのため、「続きから」は no-op。
    private func showResumeDialog(forLastPage lastPage: Int) {
        guard lastPage > 0, let window else { return }
        let alert = NSAlert()
        alert.messageText = "続きから読みますか？"
        alert.informativeText = "前回は P.\(lastPage + 1) まで読みました。"
        alert.addButton(withTitle: "続きから (P.\(lastPage + 1))")   // .alertFirstButtonReturn
        alert.addButton(withTitle: "最初から")                       // .alertSecondButtonReturn
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertSecondButtonReturn {
                self.model.goFirst()
                self.rebuildSpreads()
                self.loadCurrentPage()
                self.persistCurrent()
            }
            // .alertFirstButtonReturn → 続きから（既にレジューム済みページを表示中）→ no-op
        }
    }

    // MARK: - Phase 2.6b-2: spreads / orientation

    /// 現在の向き情報とオーバーライドから見開き配列を再構築してモデルへ設定する。
    /// single モードでは 1 ページ=1 見開きの自明な配列にする。
    private func rebuildSpreads() {
        let count = model.pageCount
        guard count > 0 else { model.setSpreads([]); return }
        if model.displayMode == .single {
            model.setSpreads((0..<count).map { Spread(pages: [$0]) })
            return
        }
        let spreads = SpreadPaginator.paginate(
            pageCount: count,
            isLandscape: { [weak self] p in self?.orientations[p] ?? false },
            override: { [weak self] p in self?.overrides[p] },
            coverOffset: model.coverOffset
        )
        model.setSpreads(spreads)
    }

    /// 表示/プリフェッチでデコード済みの画像から向きを学習する（別途 I/O なし）。
    /// 既知と異なればスプレッドを再構築し、現在ページを保ったまま再アンカーする。
    private func recordOrientation(page: Int, image: NSImage) {
        let landscape = image.size.width > image.size.height
        guard orientations[page] != landscape else { return }
        orientations[page] = landscape
        guard model.displayMode == .spread else { return }
        let anchor = model.currentPage
        rebuildSpreads()                 // rebuildSpreads() must end by calling model.setSpreads(...)
        model.goTo(page: anchor)         // re-anchor to the spread containing the page we were on
    }

    /// 現在の見開きのページ（1〜2 枚）を読み込んで canvas に設定する。
    /// 表示後にデコード画像から向きを学習し（recordOrientation）、再ページングで現在見開きの
    /// ページ集合が変わった場合のみ 1 回だけ再ロードする（画像はキャッシュ済みなので再デコードは起きず、
    /// 2 周目は同じ向きを記録 → 再構築なし → 収束する）。
    private func loadCurrentPage() {
        canvas.firstOnRight = (model.options.pageDirection == .rightToLeft)
        let pages = currentSpreadPages()
        guard !pages.isEmpty else { canvas.setImages([]); updateHUD(); return }

        // 全ページがキャッシュ済なら即時表示
        let cachedAll = pages.compactMap { prefetch[$0] }
        if cachedAll.count == pages.count {
            canvas.setImages(cachedAll)
            updateHUD()
            recordOrientationsThenMaybeReload(displayedPages: pages, images: cachedAll)
            prefetchNeighbors()
            return
        }
        let token = model.currentSpreadIndex
        Task { [weak self] in
            guard let self else { return }
            var imgs: [NSImage] = []
            for p in pages {
                if let cached = self.prefetch[p] {
                    imgs.append(cached)
                } else if let img = await Self.loadImage(content: self.content, page: p) {
                    self.prefetch[p] = img
                    imgs.append(img)
                }
            }
            // 読み込み中にユーザーが別見開きへ移動していたら差し替えない。
            guard self.model.currentSpreadIndex == token else { return }
            self.canvas.setImages(imgs)
            self.updateHUD()
            self.recordOrientationsThenMaybeReload(displayedPages: pages, images: imgs)
            self.prefetchNeighbors()
        }
    }

    /// 表示したページ群の向きを記録し、その結果現在見開きのページ集合が変わったら 1 回だけ再ロードする。
    private func recordOrientationsThenMaybeReload(displayedPages: [Int], images: [NSImage]) {
        for (i, p) in displayedPages.enumerated() where i < images.count {
            recordOrientation(page: p, image: images[i])
        }
        // 再構築で現在見開きのページ集合が変わったら 1 回だけ再ロード（キャッシュ済→再デコードなし→収束）。
        if currentSpreadPages() != displayedPages {
            loadCurrentPage()
        }
    }

    /// 現在の見開きに含まれるページ（読む順）。spread モードは spreads から、single は [currentPage]。
    private func currentSpreadPages() -> [Int] {
        if model.displayMode == .spread,
           !model.spreads.isEmpty,
           model.currentSpreadIndex >= 0,
           model.currentSpreadIndex < model.spreads.count {
            return model.spreads[model.currentSpreadIndex].pages
        }
        return model.pageCount > 0 ? [model.currentPage] : []
    }

    /// 見開きモードでは前後の見開きのページ（±2 ページ相当）まで広げてプリフェッチする。
    private func prefetchNeighbors() {
        var targets: Set<Int> = []
        if model.displayMode == .spread {
            let idx = model.currentSpreadIndex
            for si in [idx - 1, idx + 1] where si >= 0 && si < model.spreads.count {
                for p in model.spreads[si].pages { targets.insert(p) }
            }
        } else {
            targets.insert(model.currentPage - 1)
            targets.insert(model.currentPage + 1)
        }
        for p in targets where p >= 0 && p < model.pageCount && prefetch[p] == nil {
            Task { [weak self] in
                guard let self else { return }
                if let img = await Self.loadImage(content: self.content, page: p) {
                    self.prefetch[p] = img
                    // プリフェッチ済み画像からも向きを学習する（前方の横長ページへ進んだ時点で既に正しい配置）。
                    self.recordOrientation(page: p, image: img)
                    if self.prefetch.count > 8 {
                        let cur = self.model.currentPage
                        if let farthest = self.prefetch.keys.max(by: { abs($0 - cur) < abs($1 - cur) }) {
                            self.prefetch.removeValue(forKey: farthest)
                        }
                    }
                }
            }
        }
    }

    private static func loadImage(content: BookContent, page: Int) async -> NSImage? {
        do {
            let data = try await content.imageData(at: page)
            return NSImage(data: data)
        } catch {
            Self.logger.warning("viewer page \(page, privacy: .public) load failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func goNext() {
        let result = model.advance()
        switch result {
        case .moved:
            loadCurrentPage()
            persistCurrent()
        case .endStop:
            hudNote("最終ページです")
        case .endLoop:
            loadCurrentPage()
            persistCurrent()
            hudNote("先頭ページに移動しました")
        case .endNextBook:
            // 成功時のノートは performSwap 内の hudNote が発火する。
            // 次巻なし時は loadVolume 内の hudNote("次の巻なし") が発火する。
            loadNextVolumeNow()
        }
    }

    private func goPrev() {
        model.goBack()
        loadCurrentPage()
        persistCurrent()
    }

    private func jumpToPercent(_ fraction: Double) {
        guard model.pageCount > 0 else { return }
        let target = Int((Double(model.pageCount - 1) * fraction).rounded())
        model.goTo(page: target)
        loadCurrentPage()
        persistCurrent()
    }

    private func skipPages(_ delta: Int) {
        guard model.pageCount > 0 else { return }
        let target = min(max(model.currentPage + delta, 0), model.pageCount - 1)
        model.goTo(page: target)
        loadCurrentPage()
        persistCurrent()
    }

    /// 現在の表示状態（last_page + flags）を永続化する。
    private func persistCurrent() {
        persistState(book, model.currentPage, model.displayMode == .spread, model.coverOffset)
    }

    private func handleZoneClick(leftHalf: Bool) {
        perform(leftHalf ? .pageLeftward : .pageRightward)
    }

    private func chord(from event: NSEvent) -> KeyChord {
        KeyChord(keyCode: event.keyCode,
                 modifiers: UInt(event.modifierFlags.rawValue) & KeyChord.relevantMask)
    }

    /// 戻り値 true = 消費。すべて binding 表経由（per-keyCode 分岐は持たない）。
    private func handleKey(_ event: NSEvent) -> Bool {
        let c = chord(from: event)
        let resolved = bindings.action(for: c)
            ?? event.charactersIgnoringModifiers.flatMap { bindings.action(forCharacter: $0) }
        guard let action = resolved else { return false }
        perform(action)
        return true
    }

    private func perform(_ action: ViewerAction) {
        // 巻スワップ中（await content.pageCount 中）は古い model に対する全入力を無視する。
        guard !isSwapping else { return }
        // スライドショー中はトグル以外のあらゆる手動操作で自動進行を解除する。
        if action != .toggleAutoAdvance { stopAutoAdvance() }

        switch action {
        case .nextPage:        goNext()
        case .previousPage:    goPrev()
        case .pageLeftward:    (model.options.pageDirection == .rightToLeft) ? goNext() : goPrev()
        case .pageRightward:   (model.options.pageDirection == .rightToLeft) ? goPrev() : goNext()
        case .firstPage:       model.goFirst(); loadCurrentPage(); persistCurrent()
        case .lastPage:        model.goLast(); loadCurrentPage(); persistCurrent()
        case .zoomIn:          canvas.zoomIn()
        case .zoomOut:         canvas.zoomOut()
        case .fitToWindow:     canvas.fitToWindow()
        case .toggleFullScreen: window?.toggleFullScreen(nil)
        case .close:           window?.close()
        case .toggleSpread:    toggleSpread()
        case .toggleCoverOffset: toggleCoverOffset()
        case .cyclePageLayout: cyclePageLayout()
        case .toggleAutoAdvance: toggleAutoAdvance()
        case .nextVolume:      loadNextVolumeNow()
        case .prevVolume:      loadPrevVolumeNow()
        case .cycleEndOfBookBehavior: cycleEndOfBookBehavior()
        case .showHelp:        showHelpOverlay()
        case .togglePageDirection: togglePageDirection()
        case .jumpToPercent0:  jumpToPercent(0.0)
        case .jumpToPercent10: jumpToPercent(0.1)
        case .jumpToPercent20: jumpToPercent(0.2)
        case .jumpToPercent30: jumpToPercent(0.3)
        case .jumpToPercent40: jumpToPercent(0.4)
        case .jumpToPercent50: jumpToPercent(0.5)
        case .jumpToPercent60: jumpToPercent(0.6)
        case .jumpToPercent70: jumpToPercent(0.7)
        case .jumpToPercent80: jumpToPercent(0.8)
        case .jumpToPercent90: jumpToPercent(0.9)
        case .skipForward:  skipPages(ViewerSettings.shared.tabSkipPageCount)
        case .skipBackward: skipPages(-ViewerSettings.shared.tabSkipPageCount)
        }
        if action.showsHUD { showHUDThenScheduleHide() }
    }

    // MARK: - Phase 2.6b-2: spread / coverOffset / page-layout actions

    private func toggleSpread() {
        let newMode: ViewerDisplayMode = (model.displayMode == .spread) ? .single : .spread
        model.setDisplayMode(newMode)
        rebuildSpreads()   // 末尾の model.setSpreads(...) が currentPage から再アンカーする
        loadCurrentPage()  // 表示時にデコード画像から向きを学習し、判明次第に再ページングする
        persistCurrent()
        hudNote(newMode == .spread ? "見開き" : "単ページ")
    }

    private func toggleCoverOffset() {
        guard model.displayMode == .spread else {
            hudNote("見開きモードで有効")
            return
        }
        model.setCoverOffset(!model.coverOffset)
        rebuildSpreads()   // 末尾の model.setSpreads(...) が currentPage から再アンカーする
        loadCurrentPage()
        persistCurrent()
        hudNote(model.coverOffset ? "表紙独立" : "先頭からペア")
    }

    /// 現在見開きの先頭ページ（single なら現在ページ）の横長オーバーライドを
    /// 自動 → 強制単独 → 強制ペア → 自動 で巡回する。
    private func cyclePageLayout() {
        guard model.displayMode == .spread else {
            hudNote("見開きモードで有効")
            return
        }
        let target = currentSpreadPages().first ?? model.currentPage
        let current = overrides[target]
        let next: PageLayoutOverride?
        switch current {
        case nil:            next = .forceSolo
        case .forceSolo?:    next = .forcePair
        case .forcePair?:    next = nil
        }
        if let next {
            overrides[target] = next
        } else {
            overrides.removeValue(forKey: target)
        }
        persistPageOverride(book, target, next?.rawValue)
        rebuildSpreads()           // 末尾の model.setSpreads(...) が currentPage から再アンカーする
        model.goTo(page: target)   // 対象ページを含む見開きへ明示的に再アンカー
        loadCurrentPage()
        persistCurrent()
        let label: String
        switch next {
        case nil:          label = "自動"
        case .forceSolo?:  label = "強制単独"
        case .forcePair?:  label = "強制ペア"
        }
        hudNote("\(target + 1): \(label)")
    }

    /// HUD に短いテキストを ~3s 表示する（progress チャネルとは独立した専用ノートチャネル）。
    /// updateHUD() は hudNoteText を passthrough するので loadCurrentPage() が割り込んでもノートが消えない。
    private func hudNote(_ text: String) {
        hudNoteText = text
        hudVisible = true
        hudHosting?.rootView = ViewerHUDView(
            progressText: model.progressText,
            progressFraction: model.progressFraction,
            isVisible: true,
            pageDirection: model.options.pageDirection,
            noteText: hudNoteText
        )
        // ノート専用タイマー（~3.0s）。idleTimer（マウス操作による HUD 表示制御）とは別に管理する。
        hudNoteTimer?.invalidate()
        hudNoteTimer = Timer.scheduledTimer(withTimeInterval: hudNoteDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.hudNoteText = nil
                self.updateHUD()
                // ノートが消えた後（hudNoteText == nil）に short delay で HUD を隠す。
                self.scheduleHudHide()
            }
        }
        // ノート表示中はマウス idle タイマーもリセットする。note-aware なので note 表示中は隠さない。
        scheduleHudHide()
    }

    // MARK: - Phase 2.6b-2: auto-advance / volume nav / end-of-book cycle

    private func stopAutoAdvance() {
        autoAdvanceTimer?.invalidate()
        autoAdvanceTimer = nil
    }

    /// スライドショー（自動進行）を開始/停止する。間隔は ViewerSettings.shared.autoAdvanceInterval。
    /// 発火ごとに goNext() 相当（末挙動連動: nextBook は次巻へ続行、loop は先頭へ、stop は停止）。
    private func toggleAutoAdvance() {
        if autoAdvanceTimer != nil {
            stopAutoAdvance()
            hudNote("スライドショー 停止")
            return
        }
        let interval = max(1.0, ViewerSettings.shared.autoAdvanceInterval)
        autoAdvanceTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.autoAdvanceTick() }
        }
        let arrow = model.options.pageDirection == .rightToLeft ? "◀" : "▶"
        hudNote("スライドショー \(arrow) \(Int(interval))秒")
    }

    /// タイマー発火時の 1 ステップ。advance の結果に応じて次巻/ループ/停止を処理する。
    /// AdvanceResult の分岐は goNext() のものと意味的に一致させること（片方を変えたら両方更新）。
    private func autoAdvanceTick() {
        // スワップ中（await 中）の 2 回目のタイマー発火が重複スワップを開始しないようにする。
        guard !isSwapping else { return }
        let result = model.advance()
        switch result {
        case .moved:
            loadCurrentPage()
            persistCurrent()
        case .endLoop:
            loadCurrentPage()
            persistCurrent()
            hudNote("先頭ページに移動しました")
        case .endNextBook:
            // 成功時のノートは performSwap 内の hudNote が発火。次巻なし時は loadVolume 内で
            // hudNote("次の巻なし")＋stopAutoAdvance() が発火する（タイマー停止もそこで担う）。
            loadNextVolumeNow()
        case .endStop:
            stopAutoAdvance()
            hudNote("最終ページです")
        }
    }

    /// 次巻を同一ウィンドウでロードする（解決は非同期）。
    private func loadNextVolumeNow() {
        loadVolume(resolve: loadNextVolume, hudPrefix: "次の巻を開きました", noVolumeNote: "次の巻なし")
    }

    /// 前巻を同一ウィンドウでロードする（解決は非同期）。
    private func loadPrevVolumeNow() {
        loadVolume(resolve: loadPrevVolume, hudPrefix: "前の巻を開きました", noVolumeNote: "前の巻なし")
    }

    /// 隣接巻の「解決(async)」と「atomic swap」を 1 つの isSwapping ガード＋1 つの Task に統合する。
    /// await 中は isSwapping=true で全入力/タイマーを無視し、旧 model と新 content の混在を防ぐ。
    private func loadVolume(resolve: @escaping (BookRow) async -> NextVolume?,
                            hudPrefix: String, noVolumeNote: String) {
        guard !isSwapping else { return }
        isSwapping = true
        persistCurrent()                 // 旧巻の最終状態を保存（解決前に確定）
        let cur = book
        Task { [weak self] in
            guard let self else { return }
            guard let nv = await resolve(cur) else {
                self.isSwapping = false
                self.hudNote(noVolumeNote)
                self.stopAutoAdvance()    // 自動進行中なら停止（手動時は既停止で無害）
                return
            }
            await self.performSwap(nv, hudPrefix: hudPrefix)
        }
    }

    /// content/book/model を差し替えて、その巻の保存済み読書位置から表示する。
    /// 呼び出し時点で isSwapping=true・旧巻保存済み。pageCount を await 取得後、
    /// content/book/model 等を **同期で一括** 差し替える（await 中の混在を作らない）。
    private func performSwap(_ nv: NextVolume, hudPrefix: String) async {
        // 次巻の per-book 方向を解決する。nil の場合はグローバル設定を引き継ぐ。
        var options = model.options
        options.pageDirection = nv.book.pageDirection ?? ViewerSettings.shared.pageDirection
        let state = nv.state
        let pageCount = (try? await nv.content.pageCount) ?? 0
        // Phase 2.6b-2 T-B: 0-page ならスワップを中断し HUD ノートで通知する。
        // 0-page の ViewerModel をインストールすると空白ビューワになるため、
        // openInBuiltInViewer のガードと同じ方針で早期リターンする。
        guard pageCount > 0 else {
            isSwapping = false
            hudNote("次の巻を開けません（0ページ）")
            return
        }
        // ここから content-swap と model-install の間に suspension は無い（atomic swap）。
        content = nv.content
        book = nv.book
        overrides = state.overrides
        orientations = [:]
        prefetch.removeAll()
        let newModel = ViewerModel(pageCount: pageCount, options: options)
        newModel.setCoverOffset(state.coverOffset)
        newModel.setDisplayMode(state.spreadEnabled ? .spread : .single)
        newModel.goTo(page: state.lastPage)
        model = newModel
        canvas.firstOnRight = (options.pageDirection == .rightToLeft)
        rebuildSpreads()   // 末尾の model.setSpreads(...) が currentPage から再アンカーする
        loadCurrentPage()
        persistCurrent()
        isSwapping = false
        hudNote("\(hudPrefix)：\(nv.book.title)")
        // 4.2b-6: 巻送り先が読みかけなら、初回オープンと同じ「続き/最初」シートを出す。
        // 未読（lastPage==0）のときは出さず黙って先頭（既存挙動と一貫）。
        if state.lastPage > 0 {
            showResumeDialog(forLastPage: state.lastPage)
        }
    }

    /// 末挙動をセッション内で stop → nextBook → loop → stop に巡回する（ViewerSettings へは保存しない）。
    private func cycleEndOfBookBehavior() {
        let next: EndOfBookBehavior
        switch model.options.endOfBookBehavior {
        case .stop:     next = .nextBook
        case .nextBook: next = .loop
        case .loop:     next = .stop
        }
        model.options.endOfBookBehavior = next
        let label: String
        switch next {
        case .stop:     label = "末: 停止"
        case .nextBook: label = "末: 次の巻へ"
        case .loop:     label = "末: ループ"
        }
        hudNote(label)
    }

    // MARK: - Phase 2.6b-2 D3: per-book page direction toggle

    /// "r" キー: 現在の本のページ方向を rtl ↔ ltr で切り替え、モデルと canvas に即反映して永続化する。
    private func togglePageDirection() {
        let newDir: PageDirection = (model.options.pageDirection == .rightToLeft) ? .leftToRight : .rightToLeft
        model.options.pageDirection = newDir
        canvas.firstOnRight = (newDir == .rightToLeft)
        rebuildSpreads()
        loadCurrentPage()
        let label = newDir == .rightToLeft ? "右→左" : "左→右"
        hudNote("ページ方向: \(label)")
        onSetBookPageDirection?(book.id, newDir)
    }

    // MARK: - Phase 2.6b-2-2: keybinding help overlay

    /// ? / h → ヘルプオーバーレイを表示し、約5秒後に自動非表示する。
    private func showHelpOverlay() {
        helpOverlayHosting?.rootView = ViewerHelpOverlayView(isVisible: true)
        helpOverlayTimer?.invalidate()
        helpOverlayTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hideHelpOverlay() }
        }
    }

    private func hideHelpOverlay() {
        helpOverlayTimer?.invalidate()
        helpOverlayTimer = nil
        helpOverlayHosting?.rootView = ViewerHelpOverlayView(isVisible: false)
    }

    private func updateHUD() {
        // hudNoteText を passthrough することで、loadCurrentPage() による progress 更新が
        // アクティブなノート（~3s）を消してしまうバグを防ぐ（Task 3 コアフィックス）。
        hudHosting?.rootView = ViewerHUDView(
            progressText: model.progressText,
            progressFraction: model.progressFraction,
            isVisible: hudVisible,
            pageDirection: model.options.pageDirection,
            noteText: hudNoteText
        )
    }

    private func showHUDThenScheduleHide() {
        hudVisible = true
        updateHUD()
        scheduleHudHide()
    }

    /// HUD を一定時間後に隠す。note 表示中は note が消えるまで（hudNoteDuration）隠さない。
    private func scheduleHudHide() {
        idleTimer?.invalidate()
        let delay = (hudNoteText != nil) ? (hudNoteDuration + 0.3) : hudIdleHideDelay
        idleTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.hudVisible = false
                self?.updateHUD()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        persistCurrent()
        stopAutoAdvance()
        idleTimer?.invalidate()
        idleTimer = nil
        hudNoteTimer?.invalidate()
        hudNoteTimer = nil
        helpOverlayTimer?.invalidate()
        helpOverlayTimer = nil
        prefetch.removeAll()
        onClose()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        // 全画面遷移完了後に resume ダイアログを表示する（present() での同期呼び出しを回避）。
        // didShowResumeDialog ガードにより、手動の ctrl-cmd-F 時や再表示時には発火しない。
        showResumeDialogIfNeeded()
    }

    func windowDidResize(_ notification: Notification) {
        // 冗長な安全網: 主トリガは ViewerCanvasView.setFrameSize（bounds 更新後に確実に発火）。
        // windowDidResize は canvas の bounds 更新前に届くことがあるが、handleResize は冪等なので無害。
        canvas.handleResize()
    }
}

/// 表示専用 HUD。hitTest を常に nil にして、ピンチ/スクロール/クリックを下の canvas に通す。
/// （NSHostingView は .allowsHitTesting(false) でも AppKit のジェスチャ配送を素通りさせないため、
///  ここで明示的に透過させる。pinch が canvas.magnify に届かない smoke v2/v3 NG の根因。）
@MainActor
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    required init(rootView: Content) { super.init(rootView: rootView) }
    required init?(coder: NSCoder) { super.init(coder: coder) }
}

/// keyDown / mouseMoved を closure に転送する first-responder NSView。
@MainActor
final class KeyCatcherView: NSView {
    var onKeyDown: ((NSEvent) -> Bool)?
    var onMouseMoved: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
    override func mouseMoved(with event: NSEvent) {
        onMouseMoved?()
        super.mouseMoved(with: event)
    }
}
