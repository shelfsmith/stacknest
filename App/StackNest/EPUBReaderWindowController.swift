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
    private let reader: any EPUBReaderViewing
    private let persist: (EPUBLocatorValue) -> Void
    /// G54-S3: 演出・ノンブル・自動送りの間隔などを読む設定。テストは専用の suite を渡す。
    private let settings: ViewerSettings
    private var presentationObserver: NSObjectProtocol?
    // MARK: G54-S3b — 再開シート（画像ビューアの `showResumeDialogIfNeeded` と同じ作法）
    /// 開いた時点の保存位置。シートを出すかどうかの判定だけに使う。
    private let resumeLocator: EPUBLocatorValue?
    /// 巻送り・「続きから」で開いた経路では訊かない（画像ビューアの `suppressResumeDialog` と同じ）。
    private let suppressResumeDialog: Bool
    /// 1 つの窓で 1 回だけ出す。
    private var didShowResumeDialog = false
    /// シートを出す条件（テストから読む）。
    var shouldAskResume: Bool {
        !suppressResumeDialog && !didShowResumeDialog
            && EPUBResumePrompt.shouldAsk(locator: resumeLocator)
    }
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

    // MARK: G51 — 巻送り（各 State が注入。未注入なら「次の巻なし」）
    enum SiblingDirection { case next, prev }
    var resolveSibling: ((BookRow, SiblingDirection) async -> BookRow?)?
    var openSibling: ((BookRow) -> Void)?
    private var isResolvingSibling = false

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
        // G48-2 最終レビュー E: 本ごとに一意な autosave name（固定名は 2 窓目で false を返す）。
        window.setFrameAutosaveName("EPUBReaderWindow-\(book.id)")
        super.init(window: window)
        window.delegate = self
        reader.onLocatorChange = { [weak self] loc in
            self?.schedulePersist(loc)
            self?.refreshProgress()
        }
        // G54-S3: 計測の完了・無効化で HUD の「計測中…」と「N / M」を切り替える。
        reader.onPageCensusChange = { [weak self] in self?.refreshProgress() }
        // G51: キーは窓が握る。Washi 側は native monitor で受けた NSEvent をここへ渡すだけ。
        reader.onKeyEvent = { [weak self] event in self?.handleKey(event) ?? false }
        reader.onReachBookEdge = { [weak self] forward in self?.reachedBookEdge(forward: forward) }
        bindingsObserver = NotificationCenter.default.addObserver(
            forName: .viewerKeyBindingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.bindings = ViewerKeyBindings.load() }
        }
        // G54-S3: 演出とノンブルを reader に入れ、設定の変更も開いている窓に届ける。
        // 通知は `ViewerSettings`（@MainActor）の didSet から同期に投げられるので、queue: nil で同期に受ける。
        applyPresentationSettings()
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
        if settings.openEPUBFullScreenByDefault, let w = window, !w.styleMask.contains(.fullScreen) {
            DispatchQueue.main.async { [weak w] in w?.toggleFullScreen(nil) }
            return   // 続きは windowDidEnterFullScreen
        }
        showResumeDialogIfNeeded()
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

    // MARK: - G51 巻送り（同一窓でのスワップはしない: 閉じてから兄弟を通常の経路で開く）

    private func loadSibling(_ direction: SiblingDirection) {
        guard !isResolvingSibling else { return }
        guard let resolveSibling, let openSibling else { hudNote(direction == .next ? "次の巻なし" : "前の巻なし"); return }
        isResolvingSibling = true
        let current = book
        Task { [weak self] in
            let sibling = await resolveSibling(current, direction)
            guard let self else { return }
            self.isResolvingSibling = false
            guard let sibling else {
                self.hudNote(direction == .next ? "次の巻なし" : "前の巻なし")
                return
            }
            // 先に閉じる（registry から外れる）→ 兄弟を各 State の通常経路で開く（EPUB でも画像本でも正しいビューアが選ばれる）。
            // 明示 flushPersist は不要: windowWillClose が close() の中で必ず flush する（二重呼びは
            // リモートで progress を 2 回 POST してしまうので避ける）。
            self.window?.close()
            openSibling(sibling)
        }
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

    /// 保存位置が本の先頭でなければ、窓の上に二択のシートを出す。
    private func showResumeDialogIfNeeded() {
        guard shouldAskResume, let window else { return }
        markResumeDialogShown()
        let alert = NSAlert()
        alert.messageText = "続きから読みますか？"
        alert.addButton(withTitle: "続きから")     // .alertFirstButtonReturn
        alert.addButton(withTitle: "最初から")     // .alertSecondButtonReturn
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }   // 続きから＝復元済みなので何もしない
            self?.restartFromBeginning()
        }
    }

    /// テストと `showResumeDialogIfNeeded` から使う。2 回目以降は訊かない。
    func markResumeDialogShown() { didShowResumeDialog = true }

    /// 「最初から」。本の先頭へ移動し、**その位置を保存する**（次に開いたときにまた訊かれないように）。
    /// reader がまだ読み込み中でも保存は行う（画像ビューアが `storedLastPage = 0` を書くのと同じ考え方）。
    func restartFromBeginning() {
        reader.goToBookStart()
        // レビュー修正: デバウンス中の古い位置がこの後に書き戻らないよう、保留分を先に捨てる
        // （そのままだと直後のデバウンス発火や windowWillClose の flush が、いま保存した
        // 先頭位置を古い locator で上書きしてしまう）。
        persistTimer?.invalidate()
        persistTimer = nil
        pending = nil
        persist(EPUBLocatorValue(spine: 0, progress: 0, cfi: nil, engine: nil))
    }

    // MARK: - G54-S3 進捗 HUD

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
        persistTimer = Timer.scheduledTimer(withTimeInterval: persistDebounceDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flushPersist() }
        }
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
