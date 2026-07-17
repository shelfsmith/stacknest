// SPDX-License-Identifier: MIT
import AppKit
import AppCore

/// G15 V1: 内蔵ビューア窓を app-global に管理する glue。純ロジックは AppCore.ViewerRegistryCore。
/// 3 open 経路（ローカル/オフライン/リモート）が本 registry 経由で開く。
@MainActor
final class ViewerWindowRegistry {
    static let shared = ViewerWindowRegistry()
    private var core = ViewerRegistryCore()
    private var controllers: [ViewerIdentity: ViewerWindowController] = [:]

    /// 開くべきなら true。既存窓ありは前面化して false、開き中は無視して false。
    func beginOpen(_ id: ViewerIdentity) -> Bool {
        switch core.begin(id) {
        case .focusExisting: controllers[id]?.focus(); return false
        case .ignore: return false
        case .proceed: return true
        }
    }

    /// 生成完了。設定 OFF なら他窓を閉じる。
    func finishOpen(_ id: ViewerIdentity, controller: ViewerWindowController) {
        let toClose = core.finish(id, allowMultiple: ViewerSettings.shared.allowMultipleViewerWindows)
        controllers[id] = controller
        for cid in toClose {
            controllers[cid]?.close()
            controllers[cid] = nil
        }
    }

    func cancelOpen(_ id: ViewerIdentity) { core.cancel(id) }

    func unregister(_ id: ViewerIdentity) {
        core.remove(id)
        controllers[id] = nil
    }
}
