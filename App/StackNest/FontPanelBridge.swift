// SPDX-License-Identifier: MIT
import AppKit

/// G57: macOS 標準のフォントパネル（`NSFontPanel`）への橋渡し。書体 Picker の「その他…」から開き、
/// 選ばれたファミリー名だけを呼び出し元へ返す（太さ・サイズは使わない）。
@MainActor
final class FontPanelBridge: NSObject, NSFontChanging {
    static let shared = FontPanelBridge()

    private var onPick: ((String) -> Void)?
    /// パネルが閉じたことの監視（初めて開くときに 1 回だけ張る）。
    private var closeObserver: NSObjectProtocol?

    private override init() {}

    /// テスト用: onPick が張られているか。
    var hasPickHandler: Bool { onPick != nil }

    /// フォントパネルを開き、選ばれたファミリー名を 1 回ずつ onPick に渡す（パネルを閉じるまで何度でも）。
    func open(current family: String?, onPick: @escaping (String) -> Void) {
        self.onPick = onPick
        observePanelCloseOnce()
        let manager = NSFontManager.shared
        manager.target = self
        let current = family.flatMap { NSFont(name: $0, size: 14) } ?? NSFont.systemFont(ofSize: 14)
        manager.setSelectedFont(current, isMultiple: false)
        manager.orderFrontFontPanel(self)
    }

    /// NSFontChanging: フォントパネルでの選択が変わるたびに呼ばれる。
    func changeFont(_ sender: NSFontManager?) {
        guard let sender, let familyName = familyName(from: sender) else { return }
        onPick?(familyName)
    }

    func validModesForFontPanel(_ fontPanel: NSFontPanel) -> NSFontPanel.ModeMask {
        [.collection, .face]
    }

    /// パネルが閉じたら宛先と onPick を外す。閉じた後にほかの窓からフォントの変更が届いても、
    /// 閉じた設定へ書き込まない。宛先が既に別の物へ替わっていれば、それには触らない。
    func panelDidClose() {
        if NSFontManager.shared.target === self { NSFontManager.shared.target = nil }
        onPick = nil
    }

    private func observePanelCloseOnce() {
        guard closeObserver == nil else { return }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: NSFontPanel.shared, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelDidClose() }
        }
    }

    /// テスト用の分離（convert した NSFont の familyName）。
    func familyName(from manager: NSFontManager) -> String? {
        manager.convert(.systemFont(ofSize: 14)).familyName
    }
}
