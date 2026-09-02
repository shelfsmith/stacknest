// SPDX-License-Identifier: MIT
import AppKit
import EPUBAdapter
import LibraryStore

/// G48-2: EPUB 用の 2 つ目の窓。契約 `EPUBReaderViewing` の view を載せるだけで、Washi は知らない。
@MainActor
final class EPUBReaderWindowController: NSWindowController, NSWindowDelegate, ViewerWindowControlling {
    // レビュー申し送り #1: 返ってきた `any EPUBReaderViewing` は窓が強参照で保持する。
    // `.view` だけ持つと Washi の delegate（weak）経由の位置変化通知が消える。
    private let reader: any EPUBReaderViewing
    private let persist: (EPUBLocatorValue) -> Void
    var onClose: (() -> Void)?

    /// G48-2 レビュー修正ラウンド 1: `ViewerWindowController` の `persistDebounceTimer` /
    /// `flushPersistNow`（`ViewerWindowController.swift:156, 838-853, 1301`）と同じ作法で、
    /// Washi の `onLocatorChange`（ページ確定ごとに発火）を 0.4 秒デバウンスして DB 書き込みを
    /// まとめる。キーリピートでの連続ページ送り時に同期 UPSERT が連発するのを避ける。
    private var persistTimer: Timer?
    /// デバウンス待ちの直近の位置。タイマー発火時／close 時 flush でこれを書き込む。
    private var pending: EPUBLocatorValue?
    /// 永続化デバウンス遅延（秒）。画像本（`persistDebounceDelay`）と同じ値。
    private let persistDebounceDelay: TimeInterval = 0.4

    init(book: BookRow, reader: any EPUBReaderViewing, persist: @escaping (EPUBLocatorValue) -> Void) {
        self.reader = reader
        self.persist = persist
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 1100),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = book.title
        window.contentView = reader.view
        window.center()
        // G48-2 最終レビュー E: 本ごとに一意な autosave name にする。固定名のままだと 2 冊目の窓で
        // AppKit が「同名の autosave は 1 窓しか保持できない」ため false を返す
        // （`NSWindow.setFrameAutosaveName(_:)` のドキュメント挙動）。
        window.setFrameAutosaveName("EPUBReaderWindow-\(book.id)")
        super.init(window: window)
        window.delegate = self
        reader.onLocatorChange = { [weak self] loc in self?.schedulePersist(loc) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// G48-2 最終レビュー D: `ViewerWindowController.focus()`（画像ビューア、
    /// `ViewerWindowController.swift:387-390`）と同型。dedup で既存窓を前面化するとき
    /// アプリ自体が非アクティブだと窓だけ前に出てキー入力を受け取らないことがある。
    func focus() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 位置変化を即座には書かず、0.4 秒後に 1 回だけ書き込むよう予約する（画像本の
    /// `persistCurrent()` と同じ作法）。連続発火時は前のタイマーを無効化して張り直す。
    private func schedulePersist(_ loc: EPUBLocatorValue) {
        pending = loc
        persistTimer?.invalidate()
        persistTimer = Timer.scheduledTimer(withTimeInterval: persistDebounceDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flushPersist() }
        }
    }

    /// デバウンス待ちを取り消し、直近の位置（無ければ `reader.locator`）を即時書き込む。
    private func flushPersist() {
        persistTimer?.invalidate()
        persistTimer = nil
        if let loc = pending ?? reader.locator {
            persist(loc)
        }
        pending = nil
    }

    func windowWillClose(_ notification: Notification) {
        // レビュー申し送り #2: reader.locator は最初のページ変化まで nil。
        // pending も reader.locator も nil のときは何も書かない（既存値を残す）ことを
        // flushPersist() 内の if let で保証する。
        flushPersist()
        onClose?()
    }
}
