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

    init(book: BookRow, reader: any EPUBReaderViewing, persist: @escaping (EPUBLocatorValue) -> Void) {
        self.reader = reader
        self.persist = persist
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 1100),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = book.title
        window.contentView = reader.view
        window.center()
        window.setFrameAutosaveName("EPUBReaderWindow")
        super.init(window: window)
        window.delegate = self
        reader.onLocatorChange = { [weak self] loc in self?.persist(loc) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func focus() { window?.makeKeyAndOrderFront(nil) }
    func windowWillClose(_ notification: Notification) {
        // レビュー申し送り #2: reader.locator は最初のページ変化まで nil。
        // nil のまま保存すると既存値を消してしまうので、非 nil のときだけ保存する。
        if let loc = reader.locator { persist(loc) }
        onClose?()
    }
}
