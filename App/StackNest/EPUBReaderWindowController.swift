// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import AppCore
import EPUBAdapter
import LibraryStore

/// G48-2: EPUB 用の 2 つ目の窓。契約 `EPUBReaderViewing` の view を載せるだけで、Washi は知らない。
/// G51: キーは**この窓**が共有の割り当て表（`ViewerKeyBindings`）で解決して契約経由で実行する
/// （画像ビューアの `ViewerWindowController.handleKey` / `perform` と同じ作法）。
@MainActor
final class EPUBReaderWindowController: NSWindowController, NSWindowDelegate, ViewerWindowControlling {
    // レビュー申し送り #1: 返ってきた `any EPUBReaderViewing` は窓が強参照で保持する。
    // `.view` だけ持つと Washi の delegate（weak）経由の位置変化通知が消える。
    private var reader: any EPUBReaderViewing
    private var persist: (EPUBLocatorValue) -> Void
    /// G54-S3: 演出・ノンブル・自動送りの間隔などを読む設定。テストは専用の suite を渡す。
    private let settings: ViewerSettings
    private var presentationObserver: NSObjectProtocol?
    // MARK: G54-S3b — 再開シート（画像ビューアの `showResumeDialogIfNeeded` と同じ作法）
    /// 開いた時点の保存位置。シートを出すかどうかの判定だけに使う。
    private var resumeLocator: EPUBLocatorValue?
    /// 巻送り・「続きから」で開いた経路では訊かない（画像ビューアの `suppressResumeDialog` と同じ）。
    /// G54-S3c: 巻送りで差し替えた巻では false（読みかけなら訊く・spec §4.2）。
    private var suppressResumeDialog: Bool
    /// 1 つの窓で 1 回だけ出す。
    private var didShowResumeDialog = false
    /// シートを出す条件（テストから読む）。
    var shouldAskResume: Bool {
        !suppressResumeDialog && !didShowResumeDialog
            && EPUBResumePrompt.shouldAsk(locator: resumeLocator)
    }
    typealias ResumeSheetCompletion = @MainActor (NSApplication.ModalResponse) -> Void
    /// 再開シートを出す処理。テストは記録用に差し替える（画面にシートを出さずに確かめるため）。
    /// G54-S3e: 出したシートを返す。差し替えで閉じるのはこのシートだけ（他のシートには触らない）。
    var resumeSheetPresenter: @MainActor (NSWindow, @escaping ResumeSheetCompletion) -> NSWindow? = { window, completion in
        let alert = NSAlert()
        alert.messageText = "続きから読みますか？"
        alert.addButton(withTitle: "続きから")     // .alertFirstButtonReturn
        alert.addButton(withTitle: "最初から")     // .alertSecondButtonReturn
        alert.beginSheetModal(for: window) { response in completion(response) }
        return alert.window
    }
    /// G54-S3e: 出している再開シート（`dismissResumeSheet` が閉じるのはこれだけ）。
    private var resumeSheet: NSWindow?
    private(set) var book: BookRow
    var onClose: (() -> Void)?

    // MARK: 永続化（G48-2 レビュー修正ラウンド 1・0.4 秒デバウンス）
    private var persistTimer: Timer?
    private var pending: EPUBLocatorValue?
    private let persistDebounceDelay: TimeInterval = 0.4

    // MARK: G51 — キー
    /// 共有の割り当て表。保存通知（`.viewerKeyBindingsChanged`）で読み直す。テストは直接差し替える。
    var bindings: ViewerKeyBindings = ViewerKeyBindings.load()
    private var bindingsObserver: NSObjectProtocol?
    /// EPUB 用の文字倍率の 1 段。⌘+/⌘- 時代と同じ刻み。
    static let fontScaleStep = 0.1

    // MARK: G51 / G54-S3c — 巻送り（各 State が注入。未注入なら「次の巻なし」）
    enum SiblingDirection { case next, prev }

    /// G54-S3c: 所有者が用意した巻。reader は作成済みで、まだ窓には載っていない
    /// （Washi は窓に載って実寸が付いた時点で初めて本を読み込む）。開く経路と巻送りの両方で使う。
    struct PreparedBook {
        let book: BookRow
        let reader: any EPUBReaderViewing
        /// その巻の保存位置。再開シートを出すかの判定だけに使う。
        let resumeLocator: EPUBLocatorValue?
        /// その巻の位置の保存先。
        let persist: (EPUBLocatorValue) -> Void
    }

    /// G54-S3c: 次（前）の巻の解決結果。
    enum SiblingResolution {
        /// テキスト EPUB。この窓の中で差し替える。
        case swapIn(PreparedBook)
        /// テキスト EPUB 以外（zip・画像本 EPUB など）。窓を閉じ、所有者の通常の経路で開き直す。
        case reopen(BookRow)
        /// 次（前）の巻が無い。
        case noSibling
        /// 次の巻はテキスト EPUB だが reader を用意できなかった。今の本のまま。
        case failed

        /// 使わなかった結果の後始末（用意済みの reader を放す）。
        @MainActor func discard() {
            if case .swapIn(let prepared) = self { prepared.reader.tearDown() }
        }
    }

    var resolveSibling: (@MainActor (BookRow, SiblingDirection) async -> SiblingResolution)?
    /// `.reopen` のとき、窓を閉じてから呼ぶ。
    var openSibling: ((BookRow) -> Void)?
    /// G54-S3c: 同じ窓で差し替えた後に呼ぶ。所有者は窓の登録の付け替え・既読化・「最後に開いた本」の記録を行う
    /// （画像ビューアの `onBookSwapped` と同じ役割）。
    var onBookSwapped: ((BookRow) -> Void)?
    private var isResolvingSibling = false
    /// G54-S3c: 解決がこれより長引いたら（リモートのダウンロードなど）「読み込み中…」を出す。テストは短くする。
    var siblingLoadingNoteDelay: Duration = .milliseconds(400)
    /// G54-S3c: 閉じた後に届いた解決結果は捨てる。
    private var isClosed = false
    /// G54-S3cd smoke fix: present() が要求した全画面化の実行主体。1 窓に付き高々 1 個。
    private var fullScreenEntryDriver: FullScreenEntryDriver?
    /// G54-S3c: 差し替えのたびに進める。差し替え前の本の再開シートの結果・保存タイマーを無視するのに使う（テストが読む）。
    private(set) var bookGeneration = 0

    // MARK: G51 — 自動送り
    private var autoAdvanceTimer: Timer?

    // MARK: G51 — オーバーレイ（ヘルプ・HUD ノート）
    private let container = NSView()
    private var helpOverlayHosting: PassthroughHostingView<ViewerHelpOverlayView>?
    private var helpOverlayTimer: Timer?
    /// 直近に出したノート（テスト用）。
    private(set) var lastHUDNote: String?

    // MARK: G54-S3 — 進捗 HUD（画像ビューアと同じ `ViewerHUDView`）
    private var hudHosting: PassthroughHostingView<ViewerHUDView>?
    private var hudVisible = true
    private var hudNoteText: String?
    private var hudNoteTimer: Timer?
    private var idleTimer: Timer?
    private var mouseMovedMonitor: Any?
    private let hudNoteDuration: TimeInterval = 3.0
    private let hudIdleHideDelay: TimeInterval = 2.0
    /// いま HUD に出している中身（テスト用に読める）。
    private(set) var progressDisplay = EPUBProgressDisplay.make(
        globalPageCount: nil, currentGlobalPageRange: nil, spineIndex: nil, spineProgress: nil, spineCount: nil)

    init(book: BookRow, reader: any EPUBReaderViewing, settings: ViewerSettings = .shared,
         resumeLocator: EPUBLocatorValue? = nil, suppressResumeDialog: Bool = false,
         persist: @escaping (EPUBLocatorValue) -> Void) {
        self.book = book
        self.reader = reader
        self.settings = settings
        self.resumeLocator = resumeLocator
        self.suppressResumeDialog = suppressResumeDialog
        self.persist = persist
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 1100),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = book.title
        // G51: 全画面（緑ボタン・toggleFullScreen）を許可する。
        window.collectionBehavior.insert(.fullScreenPrimary)

        // G51: reader.view の上にヘルプ／HUD を重ねるため、容れ物に入れる。
        container.autoresizesSubviews = true
        reader.view.autoresizingMask = [.width, .height]
        reader.view.frame = container.bounds
        container.addSubview(reader.view)
        let help = PassthroughHostingView(rootView: ViewerHelpOverlayView(isVisible: false, including: ViewerAction.epubSupported))
        help.autoresizingMask = [.width, .height]
        help.frame = container.bounds
        container.addSubview(help)
        helpOverlayHosting = help
        // G54-S3: 画像ビューアと同じ HUD（本全体の「N / M」＋進捗バー＋ノート）。
        let hud = PassthroughHostingView(rootView: ViewerHUDView(
            progressText: progressDisplay.text, progressFraction: progressDisplay.fraction,
            isVisible: true, pageDirection: .leftToRight))
        hud.autoresizingMask = [.width, .height]
        hud.frame = container.bounds
        container.addSubview(hud)
        hudHosting = hud
        window.contentView = container
        window.center()
        super.init(window: window)
        // G48-2 最終レビュー E: 本ごとに一意な autosave name（固定名は 2 窓目で false を返す）。
        // G54-S3e: NSWindowController の指定イニシャライザ（super.init(window:)）が、その時点までに
        // 窓へ付けていた autosave 名を消してしまう。付けるのは super.init の**後**でなければならない
        // （前に付けていたため、これまで実質的に常に "" になっていた＝テストが "" 同士の比較で素通りしていた真因）。
        window.setFrameAutosaveName("EPUBReaderWindow-\(book.id)")
        window.delegate = self
        wire(reader)
        bindingsObserver = NotificationCenter.default.addObserver(
            forName: .viewerKeyBindingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.bindings = ViewerKeyBindings.load() }
        }
        // G54-S3: 演出とノンブルを reader に入れ、設定の変更も開いている窓に届ける。
        // 通知は `ViewerSettings`（@MainActor）の didSet から同期に投げられるので、queue: nil で同期に受ける。
        // （最初の適用は `wire` の中で済んでいる）
        presentationObserver = NotificationCenter.default.addObserver(
            forName: .viewerEPUBPresentationChanged, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPresentationSettings() }
        }
        // G54-S3: WebView の上でもマウス移動を拾えるよう、窓単位の local monitor で受ける。
        window.acceptsMouseMovedEvents = true
        mouseMovedMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window === self.window { self.showHUDThenScheduleHide() }
            }
            return event
        }
        refreshProgress()
        // G54-S3: 画像ビューアと同じく、開いた直後に一度出して 2 秒後に隠す。
        showHUDThenScheduleHide()
    }
    /// G54-S3c: 所有者が用意した巻で開く（開く経路と巻送りで同じ `PreparedBook` を使う）。
    convenience init(prepared: PreparedBook, settings: ViewerSettings = .shared, suppressResumeDialog: Bool = false) {
        self.init(book: prepared.book, reader: prepared.reader, settings: settings,
                  resumeLocator: prepared.resumeLocator, suppressResumeDialog: suppressResumeDialog,
                  persist: prepared.persist)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @MainActor
    deinit {
        if let o = bindingsObserver { NotificationCenter.default.removeObserver(o) }
        if let o = presentationObserver { NotificationCenter.default.removeObserver(o) }
        if let m = mouseMovedMonitor { NSEvent.removeMonitor(m) }
        autoAdvanceTimer?.invalidate()
        helpOverlayTimer?.invalidate()
        hudNoteTimer?.invalidate()
        idleTimer?.invalidate()
    }

    /// G51: 表示。`openEPUBFullScreenByDefault` なら、窓が on-screen になった直後（1 runloop 後）に全画面へ
    /// （画像ビューアの T-F1 と同じ作法。`toggleFullScreen` は on-screen になってから呼ぶ必要がある）。
    /// G54-S3b: 再開シートは窓が出た後に 1 回だけ。全画面で開くときは全画面遷移の後に出す
    /// （画像ビューアと同じ理由＝遷移とシートのレースを避ける）。
    func present() {
        showWindow(nil)
        guard settings.openEPUBFullScreenByDefault, let w = window, !w.styleMask.contains(.fullScreen) else {
            showResumeDialogIfNeeded()
            return
        }
        // G54-S3cd smoke fix: 画像ビューアの present() と同じ `FullScreenEntryDriver` を使う。
        // 巻送りで画像ビューア→EPUB に切り替わったとき（旧窓を閉じた直後）も確実に全画面へ入る。
        DispatchQueue.main.async { [weak self, weak w] in
            guard let w else { return }
            let driver = FullScreenEntryDriver(window: w)
            self?.fullScreenEntryDriver = driver
            driver.start()
        }
        // 続きは windowDidEnterFullScreen（resume シートはそこで表示する）。
    }

    /// 全画面遷移の完了後に再開シートを出す（`didShowResumeDialog` があるので手動の全画面では出ない）。
    func windowDidEnterFullScreen(_ notification: Notification) {
        showResumeDialogIfNeeded()
    }

    /// G48-2 最終レビュー D: dedup で既存窓を前面化するとき、アプリが非アクティブだと窓だけ前に出て
    /// キー入力を受け取らないことがある。
    func focus() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - G51 キー解決と実行

    private func chord(from event: NSEvent) -> KeyChord {
        KeyChord(keyCode: event.keyCode, modifiers: UInt(event.modifierFlags.rawValue) & KeyChord.relevantMask)
    }

    /// 戻り値 true = 消費。共有表で解決し、EPUB が扱わないアクションは**消費しない**（上へ流す）。
    /// レビュー指摘 C1: ⌘/⌃/⌥ 付きのキーは `charactersIgnoringModifiers` で解決してはいけない
    /// （修飾を無視するため ⌘1 が「1」に化けてレーティングを破壊する等）。画像ビューアは
    /// keyDown より前にメニューがこれらを消費するので気にしなくてよいが、EPUB の窓は Washi の
    /// local monitor 経由で直接受け取るため、この窓自身で除外する。
    func handleKey(_ event: NSEvent) -> Bool {
        let mods = UInt(event.modifierFlags.rawValue) & KeyChord.relevantMask
        let hasCmdCtrlOpt = (mods & (KeyChord.command | KeyChord.control | KeyChord.option)) != 0
        let resolved = bindings.action(for: chord(from: event))
            ?? (hasCmdCtrlOpt ? nil : event.charactersIgnoringModifiers.flatMap { bindings.action(forCharacter: $0) })
        guard let action = resolved, ViewerAction.epubSupported.contains(action) else { return false }
        perform(action)
        return true
    }

    func perform(_ action: ViewerAction) {
        // スライドショー中はトグル以外のあらゆる手動操作で自動進行を解除する（画像ビューアと同じ）。
        if action != .toggleAutoAdvance { stopAutoAdvance() }
        switch action {
        case .nextPage:        reader.goForward()
        case .previousPage:    reader.goBackward()
        // 空間キー: 読む方向（縦組み RTL / 横組み LTR）は実装側が解決する（Washi の turnPageLeft/Right）。
        case .pageLeftward:    reader.pageLeft()
        case .pageRightward:   reader.pageRight()
        case .firstPage:       reader.goToBookStart()
        case .lastPage:        reader.goToBookEnd()
        case .zoomIn:          reader.adjustFontScale(by: Self.fontScaleStep)
        case .zoomOut:         reader.adjustFontScale(by: -Self.fontScaleStep)
        case .fitToWindow:     reader.resetFontScale()
        case .toggleSpread:
            let next: EPUBColumnModeValue = (reader.columnMode == .double) ? .single : .double
            reader.columnMode = next
            hudNote(next == .double ? "見開き" : "単ページ")
        case .toggleAutoAdvance: toggleAutoAdvance()
        case .nextVolume:      loadSibling(.next)
        case .prevVolume:      loadSibling(.prev)
        case .toggleFullScreen: window?.toggleFullScreen(nil)
        case .close:           window?.close()
        case .showHelp:        showHelpOverlay()
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
        case .toggleCoverOffset, .cyclePageLayout, .cycleEndOfBookBehavior, .togglePageDirection,
             .skipForward, .skipBackward, .toggleLoupe:
            break   // `epubSupported` に無い。handleKey が弾くのでここには来ない
        }
        // G54-S3: 画像ビューアと同じく、送り系のアクションで HUD を出す。
        if action.showsHUD { showHUDThenScheduleHide() }
    }

    /// 本全体に対する割合で飛ぶ。census（全体ページ数）があればページ単位、無ければ章単位で代替し、
    /// G54-S3: 代替したことをノートで示す（計測の前後で飛び先が変わる理由が見えるように）。
    private func jumpToPercent(_ fraction: Double) {
        if let count = reader.globalPageCount, let page = EPUBPercentJump.globalPage(fraction: fraction, pageCount: count) {
            reader.go(toGlobalPage: page)
        } else if let spines = reader.spineItemCount, let spine = EPUBPercentJump.spineIndex(fraction: fraction, spineCount: spines) {
            reader.go(to: EPUBLocatorValue(spine: spine, progress: 0, cfi: nil, engine: nil))
            hudNote("計測中のため章単位で移動")
        }
    }

    // MARK: - G51 自動送り

    private func stopAutoAdvance() {
        autoAdvanceTimer?.invalidate()
        autoAdvanceTimer = nil
    }

    private func toggleAutoAdvance() {
        if autoAdvanceTimer != nil {
            stopAutoAdvance()
            hudNote("スライドショー 停止")
            return
        }
        let interval = max(1.0, settings.autoAdvanceInterval)
        autoAdvanceTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reader.goForward() }
        }
        hudNote("スライドショー ▶ \(Int(interval))秒")
    }

    /// 本の端に達した（手動・自動どちらでも）。末尾では「最後のページの次」の設定に従う（画像ビューアと同じ）。
    private func reachedBookEdge(forward: Bool) {
        guard forward else { return }
        switch settings.endOfBookBehavior {
        case .stop:
            stopAutoAdvance()
            hudNote("最終ページです")
        case .loop:
            reader.goToBookStart()
        case .nextBook:
            stopAutoAdvance()
            loadSibling(.next)
        }
    }

    // MARK: - G51 / G54-S3c 巻送り
    // テキスト EPUB の巻はこの窓の中で差し替える。それ以外は閉じてから所有者の通常の経路で開く。

    private func loadSibling(_ direction: SiblingDirection) {
        guard !isResolvingSibling, !isClosed else { return }
        let noSiblingNote = direction == .next ? "次の巻なし" : "前の巻なし"
        // G54-S3e（spec §2.3 ③）: `openSibling` は `.reopen` のときだけ要る（差し替えだけなら無くてよい）。
        guard let resolveSibling else { hudNote(noSiblingNote); return }
        // 解決から差し替え完了まで立てたまま（連打で二重に走らない）。
        isResolvingSibling = true
        let current = book
        let loadingNote = scheduleSiblingLoadingNote(direction)
        Task { [weak self] in
            let result = await resolveSibling(current, direction)
            loadingNote.cancel()
            guard let self else { result.discard(); return }
            // 解決中に窓が閉じられた: 結果は捨てる（用意した reader も放す）。
            guard !self.isClosed else {
                self.isResolvingSibling = false
                result.discard()
                return
            }
            switch result {
            case .noSibling:
                self.hudNote(noSiblingNote)
            case .failed:
                // reader を用意できなかった: 今の本のまま（窓・保存先・reader を変えない）。
                self.hudNote(direction == .next ? "次の巻を開けません" : "前の巻を開けません")
            case .reopen(let row):
                // G54-S3e: 開き直す手段が無ければ窓を閉じない（画像ビューアの `handOverToEPUBReader` と同じ文言）。
                guard let openSibling = self.openSibling else {
                    self.hudNote("この巻はここでは開けません")
                    break
                }
                // 明示 flushPersist は不要: windowWillClose が close() の中で必ず 1 回 flush する
                // （二重に呼ぶとリモートで位置を 2 回 POST する）。
                self.window?.close()
                openSibling(row)
            case .swapIn(let prepared):
                self.swapIn(prepared, direction: direction)
            }
            self.isResolvingSibling = false
        }
    }

    /// G54-S3c: 用意済みの巻へ、この窓の中で差し替える。**await を挟まない**（途中の状態を作らない）。
    /// 全画面・窓の位置（autosave 名は最初の本のまま）・キー割り当ては触らない。
    private func swapIn(_ next: PreparedBook, direction: SiblingDirection) {
        stopAutoAdvance()
        // 1) 古い本の保存を 1 回だけ流す（窓は閉じないので windowWillClose の flush は走らない）。
        flushPersist()
        // 2) 古い本の再開シート: 世代を進めて完了ハンドラを無効にし、開いていれば閉じる。
        bookGeneration += 1
        dismissResumeSheet()
        // 3) 古い reader を外す。
        detach(reader)
        // 4) 本ごとの状態を入れ替える。
        book = next.book
        reader = next.reader
        persist = next.persist
        resumeLocator = next.resumeLocator
        suppressResumeDialog = false        // 巻送りでも読みかけなら訊く（spec §4.2）
        didShowResumeDialog = false
        // 5) 新しい reader を古いのと同じ位置（ヘルプ・HUD の下）へ入れ、コールバックと表示設定を当てる。
        next.reader.view.autoresizingMask = [.width, .height]
        next.reader.view.frame = container.bounds
        container.addSubview(next.reader.view, positioned: .below, relativeTo: helpOverlayHosting)
        wire(next.reader)
        // 古い WebView ごとファーストレスポンダが消えるので、新しい本へ渡す
        // （渡さないと Washi のネイティブキー監視が「フォーカスが無い」としてキーを流さない）。
        if let responder = Self.firstResponderCandidate(in: next.reader.view) {
            window?.makeFirstResponder(responder)
        }
        window?.title = next.book.title
        refreshProgress()
        onBookSwapped?(next.book)
        hudNote("\(direction == .next ? "次の巻を開きました" : "前の巻を開きました")：\(next.book.title)")
        // 6) 次の巻に読みかけがあれば訊く（画像ビューアの performSwap と同じ）。
        showResumeDialogIfNeeded()
    }

    /// 古い reader を外す。**コールバックを先に外す**（後始末の途中で位置やキーの通知が来ても
    /// 新しい本へ流れないように）→ 後始末（WebView・キー監視の解放）→ ビューを取り除く。
    private func detach(_ old: any EPUBReaderViewing) {
        old.onLocatorChange = nil
        old.onPageCensusChange = nil
        old.onKeyEvent = nil
        old.onReachBookEdge = nil
        old.onFontScaleChange = nil
        old.tearDown()
        old.view.removeFromSuperview()
    }

    /// reader のビューの中で最初にキー入力を受けられるビュー（Washi なら `EPUBReaderView`）。
    static func firstResponderCandidate(in view: NSView) -> NSView? {
        if view.acceptsFirstResponder { return view }
        for sub in view.subviews {
            if let found = firstResponderCandidate(in: sub) { return found }
        }
        return nil
    }

    /// 解決が `siblingLoadingNoteDelay` より長引いたら「読み込み中…」を出したままにする
    /// （リモートのダウンロード中など。今の本は表示したまま）。結果が出たら通常のノートが上書きする。
    private func scheduleSiblingLoadingNote(_ direction: SiblingDirection) -> Task<Void, Never> {
        let delay = siblingLoadingNoteDelay
        return Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.isResolvingSibling, !self.isClosed else { return }
            self.showStickyNote(direction == .next ? "次の巻を読み込み中…" : "前の巻を読み込み中…")
        }
    }

    /// 消えないノート（`hudNote` と違い、タイマーで消さず HUD も隠さない）。
    private func showStickyNote(_ text: String) {
        lastHUDNote = text
        hudNoteText = text
        hudVisible = true
        hudNoteTimer?.invalidate()
        hudNoteTimer = nil
        idleTimer?.invalidate()
        idleTimer = nil
        updateHUD()
    }

    // MARK: - G51 オーバーレイ

    /// ? / h → ヘルプを表示し、約 5 秒後に自動非表示（画像ビューアと同じ）。
    private func showHelpOverlay() {
        helpOverlayHosting?.rootView = ViewerHelpOverlayView(isVisible: true, including: ViewerAction.epubSupported)
        helpOverlayTimer?.invalidate()
        helpOverlayTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.helpOverlayHosting?.rootView = ViewerHelpOverlayView(isVisible: false, including: ViewerAction.epubSupported)
            }
        }
    }

    /// 短いテキストを約 3 秒出す（画像ビューアの `hudNote` と同じく、進捗 HUD のノート枠を使う）。
    private func hudNote(_ text: String) {
        lastHUDNote = text
        hudNoteText = text
        hudVisible = true
        updateHUD()
        hudNoteTimer?.invalidate()
        hudNoteTimer = Timer.scheduledTimer(withTimeInterval: hudNoteDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.hudNoteText = nil
                self.updateHUD()
                self.scheduleHudHide()
            }
        }
        // G54-S3 final review fix (Important #2): キー操作由来の短い非表示タイマーが既に動いている
        // ところへ非同期ノート（最終ページです／次の巻なし等）が来ても、全体が先に隠れてしまわない
        // よう、ノート表示に合わせて非表示タイマーを張り直す（画像ビューアの hudNote と同じ挙動）。
        scheduleHudHide()
    }

    // MARK: - G54-S3b 再開シート

    /// 保存位置が本の先頭でなければ、窓の上に二択のシートを出す（テストから直接呼ぶので internal）。
    func showResumeDialogIfNeeded() {
        guard shouldAskResume, let window else { return }
        markResumeDialogShown()
        let generation = bookGeneration
        resumeSheet = resumeSheetPresenter(window) { [weak self] response in
            // G54-S3c: 差し替え前の本のシートの結果は捨てる（新しい本を「最初から」にしない）。
            guard let self, self.bookGeneration == generation else { return }
            self.resumeSheet = nil
            guard response == .alertSecondButtonReturn else { return }   // 続きから＝復元済みなので何もしない
            self.restartFromBeginning()
        }
    }

    /// G54-S3c: 開いている再開シートを閉じる（結果は世代で無視される）。
    /// G54-S3e: 付いているシートを何でも閉じていた。再開シートが付いているときだけ閉じる。
    private func dismissResumeSheet() {
        guard let sheet = resumeSheet else { return }
        resumeSheet = nil
        guard let window, window.sheets.contains(where: { $0 === sheet }) else { return }
        window.endSheet(sheet, returnCode: .abort)
    }

    /// テストと `showResumeDialogIfNeeded` から使う。2 回目以降は訊かない。
    func markResumeDialogShown() { didShowResumeDialog = true }

    /// 「最初から」。本の先頭へ移動し、**その位置を保存する**（次に開いたときにまた訊かれないように）。
    /// reader がまだ読み込み中でも保存は行う（画像ビューアが `storedLastPage = 0` を書くのと同じ考え方）。
    func restartFromBeginning() {
        reader.goToBookStart()
        let start = EPUBLocatorValue(spine: 0, progress: 0, cfi: nil, engine: nil)
        // レビュー修正（Codex P2）: 保留中の遅延書き込みタイマーは止めるが、`pending` は
        // nil にせず先頭に入れておく。`goToBookStart()` は非同期で、Washi が移動完了を
        // `onLocatorChange` で知らせるまで `reader.locator` は古い位置のままなので、
        // pending が nil だと windowWillClose の flush がその古い `reader.locator` に
        // 落ちて、いま保存した先頭位置を上書きしてしまう。移動が完了すれば
        // `onLocatorChange` → `schedulePersist` が pending を正しい値で上書きする。
        persistTimer?.invalidate()
        persistTimer = nil
        pending = start
        persist(start)
    }

    // MARK: - G54-S3 進捗 HUD

    /// reader に窓のコールバックと表示設定を当てる（init と差し替えで共有）。
    /// 呼ぶ前に `self.reader` をその reader にしておくこと（`applyPresentationSettings` は `self.reader` を見る）。
    private func wire(_ reader: any EPUBReaderViewing) {
        reader.onLocatorChange = { [weak self] loc in
            self?.schedulePersist(loc)
            self?.refreshProgress()
        }
        // G54-S3: 計測の完了・無効化で HUD の「計測中…」と「N / M」を切り替える。
        reader.onPageCensusChange = { [weak self] in self?.refreshProgress() }
        // G51: キーは窓が握る。Washi 側は native monitor で受けた NSEvent をここへ渡すだけ。
        reader.onKeyEvent = { [weak self] event in self?.handleKey(event) ?? false }
        reader.onReachBookEdge = { [weak self] forward in self?.reachedBookEdge(forward: forward) }
        applyTextSettings(to: reader)
        applyPresentationSettings()
    }

    /// G54-S3c: 文字倍率と配色を reader に当てる（以前は所有者 3 か所が同じことを書いていた）。
    /// 復元の代入を先にし、変更ハンドラの設置を後にする（復元自体が保存を起こさないように・G48-2 smoke fix と同じ）。
    /// 配色は当てた時点の設定を 1 回だけ渡す（開いている窓には反映しない・G54-S2b）。
    private func applyTextSettings(to reader: any EPUBReaderViewing) {
        reader.fontScale = settings.epubFontScale
        reader.onFontScaleChange = { [weak self] scale in self?.settings.epubFontScale = scale }
        reader.setTheme(settings.epubTheme)
    }

    /// 演出とノンブルを reader に入れる（init と設定変更の通知から）。
    private func applyPresentationSettings() {
        reader.pageTurnStyle = settings.pageTurnStyle
        reader.showsFolio = settings.showsEPUBFolio
    }

    /// 位置の変化・計測の完了で HUD の中身を作り直す。
    private func refreshProgress() {
        progressDisplay = EPUBProgressDisplay.make(
            globalPageCount: reader.globalPageCount,
            currentGlobalPageRange: reader.currentGlobalPageRange,
            spineIndex: reader.locator?.spine,
            spineProgress: reader.locator?.progress,
            spineCount: reader.spineItemCount)
        updateHUD()
    }

    private func updateHUD() {
        hudHosting?.rootView = ViewerHUDView(
            progressText: progressDisplay.text,
            progressFraction: progressDisplay.fraction,
            isVisible: hudVisible,
            pageDirection: reader.isRightToLeft ? .rightToLeft : .leftToRight,
            noteText: hudNoteText)
    }

    private func showHUDThenScheduleHide() {
        hudVisible = true
        updateHUD()
        scheduleHudHide()
    }

    /// 画像ビューアと同じ: ノート表示中はノートが消えるまで隠さない。
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

    // MARK: - 永続化（既存）

    private func schedulePersist(_ loc: EPUBLocatorValue) {
        pending = loc
        persistTimer?.invalidate()
        let generation = bookGeneration
        persistTimer = Timer.scheduledTimer(withTimeInterval: persistDebounceDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.persistTimerFired(generation: generation) }
        }
    }

    /// G54-S3e（spec §2.3 ①）: 保存タイマーの発火。タイマーが Task を積んだ後に差し替えが走ると、その Task は
    /// 新しい本に対して早すぎる保存をする。世代が変わっていたら何もしない（テストから直接呼ぶので internal）。
    func persistTimerFired(generation: Int) {
        guard generation == bookGeneration else { return }
        flushPersist()
    }

    private func flushPersist() {
        persistTimer?.invalidate()
        persistTimer = nil
        if let loc = pending ?? reader.locator {
            persist(loc)
        }
        pending = nil
    }

    func windowWillClose(_ notification: Notification) {
        isClosed = true   // G54-S3c: 以後に届いた巻送りの結果は捨てる
        fullScreenEntryDriver?.stop()   // G54-S3cd smoke fix: 窓を閉じたら以後のリトライを止める
        fullScreenEntryDriver = nil
        stopAutoAdvance()
        helpOverlayTimer?.invalidate()
        hudNoteTimer?.invalidate()
        idleTimer?.invalidate()
        if let m = mouseMovedMonitor { NSEvent.removeMonitor(m); mouseMovedMonitor = nil }
        // レビュー申し送り #2: pending も reader.locator も nil のときは何も書かない(既存値を残す)。
        flushPersist()
        onClose?()
    }
}
