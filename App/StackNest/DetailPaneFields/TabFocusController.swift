// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit
import OSLog

/// Detail Pane root に 1 個だけ配置される透明 view。NSEvent.addLocalMonitorForEvents で
/// Tab / Shift+Tab を AppKit key-view loop の前に intercept し、currentEditingField を
/// read して advance / retreat callback に dispatch する。
///
/// 各 field component に分散していた Tab handling (`.onKeyPress(.tab)`, `\u{19}` 系,
/// per-field NSEvent monitor) を撤去する代わりに、ここで一元管理する。SwiftUI TextField /
/// TextEditor 本体 / @FocusState には一切触らないので、df99499 (revert 済) で問題になった
/// focus race と同型の問題は起きない。
///
/// Hackintosh (Intel macOS) でランダム NG だった原因 (closure capture stale, 複数 field 同時
/// monitor の race, install タイミング遅延) は次の仕組みで構造的に解消:
/// - monitor は view 1 instance につき 1 個だけ存在 (`MonitorHolder` の deinit 保証で、
///   SwiftUI が view struct を re-identity しても古い monitor は確実に removeMonitor される)
/// - `@Binding currentEditingField` 経由で SwiftUI runtime が都度参照 (copy stale 不可)
/// - DetailPaneView の onAppear で install 完了 → 各 field の `.task` 遅延の影響なし
struct TabFocusController: View {
    /// 現在編集中の field。nil なら誰も編集していないので Tab を消費しない (pass-through)。
    @Binding var currentEditingField: DetailField?
    /// Tab 押下時の callback。引数は「現在編集中の field (= advance の起点)」。
    let onTabNext: (DetailField) -> Void
    /// Shift+Tab 押下時の callback。
    let onShiftTabPrev: (DetailField) -> Void

    /// MonitorHolder を @State で保持することで、SwiftUI が view を re-identity しても
    /// 旧 holder の deinit で古い monitor が removeMonitor される (leak 防止)。
    @State private var holder = MonitorHolder()

    /// Hackintosh での Tab ランダム NG 観察用 logger。
    /// Console.app で `subsystem == "app.shelfsmith.stacknest" AND category == "TabNav"` を tail して
    /// install / fire / consume / pass-through の判定を時系列に追える。
    static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "TabNav")

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                Self.logger.info("TabFocusController.onAppear: install monitor")
                installMonitor()
            }
            .onDisappear {
                Self.logger.info("TabFocusController.onDisappear: uninstall monitor")
                holder.uninstall()
            }
    }

    private func installMonitor() {
        holder.install { [currentEditingField = $currentEditingField, onTabNext, onShiftTabPrev] event in
            // 全 keyDown を Tab 関連だけに絞ってログ (頻度抑制のため keyCode 48 のみ)
            let isTab = event.keyCode == 48
            let field = currentEditingField.wrappedValue
            // 誰も編集していない → AppKit key-view loop に委ねる
            guard let activeField = field else {
                if isTab {
                    Self.logger.info("monitor: Tab event but currentEditingField=nil → pass-through")
                }
                return event
            }
            // keyCode 48 = Tab。Shift+Tab も同じ keyCode + modifierFlags で来る
            guard isTab else { return event }
            // Cmd+Tab / Ctrl+Tab / Opt+Tab はシステム / 他 app shortcut なので pass-through
            let blockedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
            let blocked = event.modifierFlags.intersection(blockedModifiers)
            guard blocked.isEmpty else {
                Self.logger.info("monitor: Tab with blocked modifiers (\(blocked.rawValue, privacy: .public)) field=\(String(describing: activeField), privacy: .public) → pass-through")
                return event
            }
            let isShift = event.modifierFlags.contains(.shift)
            Self.logger.info("monitor: \(isShift ? "Shift+Tab" : "Tab", privacy: .public) field=\(String(describing: activeField), privacy: .public) → CONSUME, dispatch \(isShift ? "retreat" : "advance", privacy: .public)")
            if isShift {
                onShiftTabPrev(activeField)
            } else {
                onTabNext(activeField)
            }
            return nil // consume — AppKit key-view loop に届かせない
        }
    }
}

/// `NSEvent.addLocalMonitorForEvents` の token を class で握り、deinit で
/// `NSEvent.removeMonitor` を確実に呼ぶ。`@State` が SwiftUI view re-identity で
/// 別 instance を作っても、旧 instance は ARC で deinit されて monitor が外れる。
private final class MonitorHolder {
    private var token: Any?

    func install(handler: @escaping (NSEvent) -> NSEvent?) {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handler)
    }

    func uninstall() {
        if let t = token {
            NSEvent.removeMonitor(t)
            token = nil
        }
    }

    deinit {
        if let t = token {
            NSEvent.removeMonitor(t)
        }
    }
}
