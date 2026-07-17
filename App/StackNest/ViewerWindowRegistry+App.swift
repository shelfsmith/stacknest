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

    /// G16 C1 fix: owner の `onClose` は生成時に `let identity = ...` を capture するため、
    /// `reidentify` で登録済みキーが張り替わった後は stale になる（unregister(identity) が
    /// 旧キーの no-op になり、新キーの entry が residual リークする）。close 時は常に
    /// controller から現在のキーを逆引きして除去することで、reidentify の有無に関わらず
    /// 「controller ごとにちょうど1キー」の不変条件を保つ。
    func unregister(controller: ViewerWindowController) {
        guard let currentKey = controllers.first(where: { $0.value === controller })?.key else { return }
        core.remove(currentKey)
        controllers[currentKey] = nil
    }

    /// G16 C1: 巻スワップ等で表示中の本が変わったとき、登録済み identity を新しい本のものへ
    /// 張り替える。owner に旧 identity を追跡させないよう、controller から逆引きする。
    func reidentify(to newID: ViewerIdentity, controller: ViewerWindowController) {
        guard let oldKey = controllers.first(where: { $0.value === controller })?.key, oldKey != newID else { return }
        // Important #2: newID が既に「別の」controller の下で開いている稀な ON-mode ケース
        // （dedup 許容設定で複数窓が同時に開ける状態のとき、スワップ先が他窓と同じ本に
        // 着地する）では張り替えを丸ごとスキップする。ここで re-key すると、その別窓の
        // registry entry を上書きして孤児化させてしまう（以後 dedup の前面化が効かなくなる）。
        // この本に対する dedup がこのスワップ後の窓を対象にしなくなるだけで、実害は軽微。
        if let existing = controllers[newID], existing !== controller { return }
        core.reidentify(from: oldKey, to: newID)
        controllers[oldKey] = nil
        controllers[newID] = controller
    }
}
