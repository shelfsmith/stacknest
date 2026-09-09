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
    private var hudNoteHosting: PassthroughHostingView<EPUBHUDNoteView>?
    private var hudNoteTimer: Timer?
    /// 直近に出したノート（テスト用）。
    private(set) var lastHUDNote: String?

    init(book: BookRow, reader: any EPUBReaderViewing, persist: @escaping (EPUBLocatorValue) -> Void) {
        self.book = book
        self.reader = reader
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
        let note = PassthroughHostingView(rootView: EPUBHUDNoteView(text: nil))
        note.autoresizingMask = [.width, .height]
        note.frame = container.bounds
        container.addSubview(note)
        hudNoteHosting = note
        window.contentView = container
        window.center()
        // G48-2 最終レビュー E: 本ごとに一意な autosave name（固定名は 2 窓目で false を返す）。
        window.setFrameAutosaveName("EPUBReaderWindow-\(book.id)")
        super.init(window: window)
        window.delegate = self
        reader.onLocatorChange = { [weak self] loc in self?.schedulePersist(loc) }
        // G51: キーは窓が握る。Washi 側は native monitor で受けた NSEvent をここへ渡すだけ。
        reader.onKeyEvent = { [weak self] event in self?.handleKey(event) ?? false }
        reader.onReachBookEdge = { [weak self] forward in self?.reachedBookEdge(forward: forward) }
        bindingsObserver = NotificationCenter.default.addObserver(
            forName: .viewerKeyBindingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.bindings = ViewerKeyBindings.load() }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @MainActor
    deinit {
        if let o = bindingsObserver { NotificationCenter.default.removeObserver(o) }
    }

    /// G51: 表示。`openEPUBFullScreenByDefault` なら、窓が on-screen になった直後（1 runloop 後）に全画面へ
    /// （画像ビューアの T-F1 と同じ作法。`toggleFullScreen` は on-screen になってから呼ぶ必要がある）。
    func present() {
        showWindow(nil)
        if ViewerSettings.shared.openEPUBFullScreenByDefault, let w = window, !w.styleMask.contains(.fullScreen) {
            DispatchQueue.main.async { [weak w] in w?.toggleFullScreen(nil) }
        }
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
    func handleKey(_ event: NSEvent) -> Bool {
        let resolved = bindings.action(for: chord(from: event))
            ?? event.charactersIgnoringModifiers.flatMap { bindings.action(forCharacter: $0) }
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
        case .zoomOut:          reader.adjustFontScale(by: -Self.fontScaleStep)
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
    }

    /// 本全体に対する割合で飛ぶ。census（全体ページ数）があればページ単位、無ければ spine 単位で代替。
    private func jumpToPercent(_ fraction: Double) {
        if let count = reader.globalPageCount, let page = EPUBPercentJump.globalPage(fraction: fraction, pageCount: count) {
            reader.go(toGlobalPage: page)
        } else if let spines = reader.spineItemCount, let spine = EPUBPercentJump.spineIndex(fraction: fraction, spineCount: spines) {
            reader.go(to: EPUBLocatorValue(spine: spine, progress: 0, cfi: nil, engine: nil))
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
        let interval = max(1.0, ViewerSettings.shared.autoAdvanceInterval)
        autoAdvanceTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reader.goForward() }
        }
        hudNote("スライドショー ▶ \(Int(interval))秒")
    }

    /// 本の端に達した。自動送り中の末尾では `endOfBookBehavior` に従う（画像ビューアの autoAdvanceTick と同じ意味）。
    private func reachedBookEdge(forward: Bool) {
        guard forward, autoAdvanceTimer != nil else { return }
        switch ViewerSettings.shared.endOfBookBehavior {
        case .stop:
            stopAutoAdvance()
            hudNote("最後のページ")
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
            self.flushPersist()
            // 先に閉じる（registry から外れる）→ 兄弟を各 State の通常経路で開く（EPUB でも画像本でも正しいビューアが選ばれる）。
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

    /// 短いテキストを約 3 秒出す（画像ビューアの `hudNote` 相当。進捗 HUD は持ち込まない）。
    private func hudNote(_ text: String) {
        lastHUDNote = text
        hudNoteHosting?.rootView = EPUBHUDNoteView(text: text)
        hudNoteTimer?.invalidate()
        hudNoteTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hudNoteHosting?.rootView = EPUBHUDNoteView(text: nil) }
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
        // レビュー申し送り #2: pending も reader.locator も nil のときは何も書かない(既存値を残す)。
        flushPersist()
        onClose?()
    }
}

/// G51: EPUB 窓の一時ノート（「見開き」「次の巻なし」など）。画像ビューアの HUD ノートと同じ見た目の最小版。
struct EPUBHUDNoteView: View {
    var text: String?
    var body: some View {
        VStack {
            Spacer()
            if let text {
                Text(text)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.white)
                    .padding(.bottom, 28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.15), value: text)
    }
}
