// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import LibraryStore
import AppCore
import RemoteClient
import OSLog

/// 内蔵ビューアの専用ウィンドウを管理する。1 冊の BookContent を ViewerModel で遷移し
/// ViewerCanvasView で描画。キー処理と左右ゾーンクリック送り、HUD 自動非表示を担う。
@MainActor
final class ViewerWindowController: NSWindowController, NSWindowDelegate {
    /// `nonisolated`: G18 C2 の off-main `loadImage`（nonisolated static func）から参照するため。
    /// `Logger` は値型・スレッドセーフに設計されており MainActor 隔離は不要。
    private nonisolated static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "Viewer")

    private var content: BookContent
    private var book: BookRow
    private var model: ViewerModel
    /// G16 C1 fix: owner-supplied close hook。init 引数には `controller` 自身を渡せない
    /// （自身の init 呼び出し中は変数がまだ束縛されていない）ため、`onBookSwapped` と同様
    /// var にして `let controller = ViewerWindowController(...)` の後で `[weak controller]`
    /// キャプチャして代入する。これにより onClose は常に「現在の」controller 参照を握れる。
    var onClose: () -> Void = {}

    // Phase 2.6b-2 injected closures
    private let loadNextVolume: (BookRow) async -> NextVolume?
    private let loadPrevVolume: (BookRow) async -> NextVolume?
    private let persistState: (BookRow, Int, Bool, Bool) -> Void          // (book, lastPage, spreadEnabled, coverOffset)
    private let persistPageOverride: (BookRow, Int, Int?) -> Void          // (book, page, mode int or nil)
    /// Phase 2.6b-2 D3: コールバック。本のページ方向が変わったら AppState 経由で DB に永続化する。
    var onSetBookPageDirection: ((Int, PageDirection) -> Void)?
    /// G16 C1: 巻スワップが成功して表示中の本が切り替わったら、新しい本を渡して owner に通知する。
    /// owner はこれを使って ViewerWindowRegistry の identity を新しい本のものへ張り替える。
    /// 0-page で中断したスワップ（アトミックに commit されなかった場合）では呼ばれない。
    var onBookSwapped: ((BookRow) -> Void)?

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
    private let suppressResumeDialog: Bool
    /// 非 nil ならタイトルバーに "<ラベル>: <書名>" を表示する（リモート由来などの可視マーカ）。
    /// 4.2c-3: 巻送りでソースが変わる（DL済み=オフライン/未DL=リモート）ため var にして更新する。
    private var sourceLabel: String?
    /// 4.2c-3: 巻送り時にラベルを差し替えるため、左上の永続バッジ host を保持する。
    private var sourceBadge: PassthroughHostingView<AnyView>?

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
    /// G18 C2: 値は off-main で即時デコード済みの CGImage ラッパ（`NSImage`＝lazy decode ではない）。
    private var prefetch: [Int: DecodedImage] = [:]
    /// page → (token, task)。token で Task 同一性を判定し、古い cancel 済 Task の完了が
    /// 同一ページの新 Task エントリを誤除去する競合（高速連打）を防ぐ（I1 対策）。
    private var inFlightPrefetch: [Int: (token: Int, task: Task<Void, Never>)] = [:]
    private var prefetchToken = 0
    private var prefetchQueue: [Int] = []
    private let maxConcurrentPrefetch = 3
    /// リモート閲覧時のみ注入（可視保護・tier3）。ローカル/オフラインは nil。
    var remotePrefetch: RemotePrefetchContext?
    /// 現在 content がリモート本なら bookID。巻スワップで content が差し替わると追従（C1 対策）。
    var currentRemoteBookID: Int? { (content as? RemoteBookContent)?.bookIDValue }
    /// G3b: L2 キャッシュ済みページのカバレッジ帯（プログレスバー可視化・リモートのみ・~1s ポーリング）。
    private var cachedSegments: [ClosedRange<Double>] = []
    private var cacheCoverageTimer: Timer?
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
        suppressResumeDialog: Bool = false,
        sourceLabel: String? = nil
    ) {
        self.content = content
        self.book = book
        self.model = ViewerModel(pageCount: pageCount, options: options)
        self.loadNextVolume = loadNextVolume
        self.loadPrevVolume = loadPrevVolume
        self.persistState = persistState
        self.persistPageOverride = persistPageOverride
        self.suppressResumeDialog = suppressResumeDialog
        self.sourceLabel = sourceLabel
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

        // ソースラベル指定時はタイトルを可視化して由来（例: リモート）を明示する。
        // 未指定（local）は既存の没入型・タイトル非表示挙動のまま。
        if let sourceLabel {
            window.title = "\(sourceLabel): \(book.title)"
            window.titleVisibility = .visible
        }

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

        let hud = PassthroughHostingView(rootView: ViewerHUDView(progressText: model.progressText, progressFraction: model.progressFraction, isVisible: true, pageDirection: model.options.pageDirection, cachedSegments: cachedSegments))
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

        // ソースラベル指定時（リモート等）は、全画面でも常時可視な永続バッジを左上に重ねる。
        // タイトルバー由来のラベルは全画面でタイトルバーが隠れて見えなくなるため（smoke H-RV）。
        // PassthroughHostingView を使い hitTest=nil でページ送りタップを下の canvas に通す。
        // canvas/HUD/help より後に addSubview することで subview 順で最前面に来る。
        if let sourceLabel {
            let badge = PassthroughHostingView(rootView: Self.sourceBadgeView(sourceLabel))
            badge.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
                badge.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            ])
            sourceBadge = badge
        }

        window.makeFirstResponder(container)
        showHUDThenScheduleHide()
    }

    /// 4.2c-3: ソース識別バッジの SwiftUI ビュー（初期表示・巻送りでの差し替えで共用）。
    static func sourceBadgeView(_ label: String) -> AnyView {
        AnyView(
            Text(label)
                .font(.caption2).bold()
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.accentColor.opacity(0.85)))
                .padding(6)
        )
    }

    func present() {
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startCacheCoverageUpdatesIfRemote()
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

    /// G15 V1: 既存窓の前面化（dedup 時に呼ぶ）。
    func focus() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 続きから読む場合（resumeLastPage > 0）のみ、ウィンドウ表示後に一度だけシートダイアログを表示する。
    private func showResumeDialogIfNeeded() {
        guard !suppressResumeDialog, resumeLastPage > 0, !didShowResumeDialog else { return }
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
    private func recordOrientation(page: Int, image: DecodedImage) {
        let landscape = image.pixelSize.width > image.pixelSize.height
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
            recomputePrefetch()
            return
        }
        let token = model.currentSpreadIndex
        let maxPixelSize = decodeTargetMaxPixelSize()
        Task { [weak self] in
            guard let self else { return }
            var imgs: [DecodedImage] = []
            for p in pages {
                if let cached = self.prefetch[p] {
                    imgs.append(cached)
                } else if let img = await Self.loadImage(content: self.content, page: p, maxPixelSize: maxPixelSize) {
                    self.prefetch[p] = img
                    imgs.append(img)
                }
            }
            // 読み込み中にユーザーが別見開きへ移動していたら差し替えない。
            guard self.model.currentSpreadIndex == token else { return }
            self.canvas.setImages(imgs)
            self.updateHUD()
            self.recordOrientationsThenMaybeReload(displayedPages: pages, images: imgs)
            self.recomputePrefetch()
        }
    }

    /// 表示したページ群の向きを記録し、その結果現在見開きのページ集合が変わったら 1 回だけ再ロードする。
    private func recordOrientationsThenMaybeReload(displayedPages: [Int], images: [DecodedImage]) {
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

    /// 移動ごとに Web パリティの先読み plan を再計算し、遠方の in-flight を abort、近傍を優先取得する。
    private func recomputePrefetch() {
        let cur = model.currentPage
        let spreadPages: [Int]?
        var neighborSpreads: [[Int]] = []
        if model.displayMode == .spread, model.currentSpreadIndex >= 0, model.currentSpreadIndex < model.spreads.count {
            spreadPages = model.spreads[model.currentSpreadIndex].pages
            let idx = model.currentSpreadIndex
            for si in [idx - 1, idx + 1] where si >= 0 && si < model.spreads.count {
                neighborSpreads.append(model.spreads[si].pages)
            }
        } else {
            spreadPages = nil
        }
        let tier3 = remotePrefetch?.tier3Enabled() ?? false
        let plan = PrefetchPlanner.plan(current: cur, pageCount: model.pageCount,
                                        spreadPages: spreadPages, neighborSpreads: neighborSpreads, tier3: tier3)
        // abort: 近傍(先頭8)に無い in-flight を cancel
        let keep = Set(plan.queue.prefix(8))
        for (page, entry) in inFlightPrefetch where !keep.contains(page) {
            entry.task.cancel(); inFlightPrefetch.removeValue(forKey: page)
        }
        // 可視保護（ページ移動追従）。現在のリモート bookID を渡し巻スワップに追従（C1）。
        remotePrefetch?.reportActiveWindow(plan.activeWindow, currentRemoteBookID)
        // enqueue
        prefetchQueue = plan.queue
        pumpPrefetch()
    }

    private func pumpPrefetch() {
        let maxPixelSize = decodeTargetMaxPixelSize()
        while inFlightPrefetch.count < maxConcurrentPrefetch,
              let page = prefetchQueue.first(where: { prefetch[$0] == nil && inFlightPrefetch[$0] == nil }) {
            prefetchQueue.removeAll { $0 == page }
            let content = self.content
            prefetchToken += 1
            let token = prefetchToken
            // 自分の token に一致するときだけエントリを除去（別 Task に置換済みなら触らない）。
            let removeIfMine: () -> Void = { [weak self] in
                guard let self, self.inFlightPrefetch[page]?.token == token else { return }
                self.inFlightPrefetch.removeValue(forKey: page)
            }
            let task = Task { [weak self] in
                let img = await Self.loadImage(content: content, page: page, maxPixelSize: maxPixelSize)
                guard let self else { return }
                if Task.isCancelled { removeIfMine(); return }
                if let img {
                    self.prefetch[page] = img
                    // プリフェッチ済み画像からも向きを学習する（前方の横長ページへ進んだ時点で既に正しい配置）。
                    self.recordOrientation(page: page, image: img)
                    self.trimL1(around: self.model.currentPage)
                }
                removeIfMine()
                self.pumpPrefetch()
            }
            inFlightPrefetch[page] = (token, task)
        }
    }

    /// L1 メモリを可視近傍中心に間引く（現行の「最大8・遠方破棄」を踏襲）。
    private func trimL1(around cur: Int) {
        while prefetch.count > 8 {
            if let farthest = prefetch.keys.max(by: { abs($0 - cur) < abs($1 - cur) }) {
                prefetch.removeValue(forKey: farthest)
            } else { break }
        }
    }

    /// G18 C2 コアフィックス: `nonisolated` にすることで、MainActor（このクラス自体は @MainActor）
    /// から `await Self.loadImage(...)` した場合でも、この関数の本体は MainActor の executor 上では
    /// 実行されない。Swift の actor isolation は「MainActor-isolated なコンテキストから nonisolated な
    /// async 関数を呼ぶ」際、呼び出しが MainActor の executor を離れてグローバルな協調スレッドプール
    /// 上で実行されることを保証する（完了後、呼び出し元の続きだけが MainActor へ戻る）。
    /// `content.imageData(at:)` は `BookContent`（`Sendable` プロトコル・isolation 注釈なし）の
    /// 要求であり、実装（Archive/PDF/Remote 等）はいずれも MainActor に隔離されていない I/O。
    /// 続く `ViewerImageDecoder.decode` は同じ nonisolated 関数内・同じ off-main 実行文脈で呼ばれる
    /// ため、CPU バウンドな即時デコード（旧実装で `ViewerCanvasView.draw(_:)` 内・メインスレッドで
    /// 走っていた lazy decode の原因）もメインスレッドでは一切実行されない。
    /// メインスレッドに触れるのは呼び出し元（`loadCurrentPage`/`pumpPrefetch`）が `await` から
    /// 戻った後の「`prefetch` へ格納」「`canvas.setImages` で差し替え」だけである。
    nonisolated private static func loadImage(content: BookContent, page: Int, maxPixelSize: Int) async -> DecodedImage? {
        do {
            let data = try await content.imageData(at: page)
            return ViewerImageDecoder.decode(data, maxPixelSize: maxPixelSize)
        } catch {
            Self.logger.warning("viewer page \(page, privacy: .public) load failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// G18 C2 暫定実装: デコード先の目標最大辺（px）。正確な「表示サイズちょうど」の縮小は
    /// C3（後続タスク）で扱う（TODO(C3): ページ単体/見開き別の実表示サイズに応じた再デコード）。
    /// ここでは canvas の現在の bounds（バッキングスケール込み）から大まかな上限を出し、
    /// レイアウト前などで取得できない/不当に小さい場合はフォールバック定数を使う。
    /// MainActor 上（canvas/window に触れられる場所）で呼び、結果の Int だけを
    /// off-main の `loadImage` へ渡す（decode 自体は依然 off-main のまま）。
    private func decodeTargetMaxPixelSize() -> Int {
        let scale = window?.backingScaleFactor ?? 2.0
        let boundsSize = canvas.bounds.size
        let longestEdge = max(boundsSize.width, boundsSize.height) * scale
        guard longestEdge.isFinite, longestEdge > 0 else { return Self.fallbackDecodeMaxPixelSize }
        return max(Int(longestEdge), Self.fallbackDecodeMaxPixelSize / 2)
    }
    /// canvas の bounds が未確定（0）なときのフォールバック上限。
    private static let fallbackDecodeMaxPixelSize = 4000

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
            noteText: hudNoteText,
            cachedSegments: cachedSegments
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
        // 0-page の ViewerModel をインストールすると空白ビューアになるため、
        // openInBuiltInViewer のガードと同じ方針で早期リターンする。
        guard pageCount > 0 else {
            isSwapping = false
            hudNote("次の巻を開けません（0ページ）")
            return
        }
        // ここから content-swap と model-install の間に suspension は無い（atomic swap）。
        // 旧巻の先読みを止める（保護 owner は同一ビューアなので clear 不要・次 recompute で更新）。
        for (_, e) in inFlightPrefetch { e.task.cancel() }
        inFlightPrefetch.removeAll()
        content = nv.content
        book = nv.book
        // G16 C1: atomic swap が commit された（0-page 中断は上のガードで既に return 済み）。
        // owner に新しい本を通知し、ViewerWindowRegistry の identity を張り替えさせる。
        onBookSwapped?(nv.book)
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
        // 4.2c-3: 巻ごとにソースが変わる場合（DL済み=オフライン/未DL=リモート）はバッジ/タイトルを更新する。
        if let newLabel = nv.sourceLabel {
            sourceLabel = newLabel
            sourceBadge?.rootView = Self.sourceBadgeView(newLabel)
            window?.title = "\(newLabel): \(nv.book.title)"
        }
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

    /// G3b: リモート閲覧時、~1s ごとに L2 キャッシュ済みページを取得しカバレッジ帯を更新する。
    private func startCacheCoverageUpdatesIfRemote() {
        guard remotePrefetch != nil, cacheCoverageTimer == nil else { return }
        refreshCacheCoverage()
        cacheCoverageTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshCacheCoverage() }
        }
    }

    private func refreshCacheCoverage() {
        guard let ctx = remotePrefetch, let bid = currentRemoteBookID else { return }
        let pageCount = model.pageCount
        Task { @MainActor in
            let pages = await ctx.cachedPages(bid)
            let segs = CacheCoverage.segments(cached: pages, pageCount: pageCount)
            if segs != self.cachedSegments {
                self.cachedSegments = segs
                self.updateHUD()
            }
        }
    }

    private func updateHUD() {
        // hudNoteText を passthrough することで、loadCurrentPage() による progress 更新が
        // アクティブなノート（~3s）を消してしまうバグを防ぐ（Task 3 コアフィックス）。
        hudHosting?.rootView = ViewerHUDView(
            progressText: model.progressText,
            progressFraction: model.progressFraction,
            isVisible: hudVisible,
            pageDirection: model.options.pageDirection,
            noteText: hudNoteText,
            cachedSegments: cachedSegments
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
        cacheCoverageTimer?.invalidate()
        cacheCoverageTimer = nil
        prefetch.removeAll()
        for (_, e) in inFlightPrefetch { e.task.cancel() }
        inFlightPrefetch.removeAll()
        remotePrefetch?.clearProtection()
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
