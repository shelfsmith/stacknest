// SPDX-License-Identifier: MIT
import Foundation

/// Phase 2.6c: 初回起動ウィザードのステップ識別子。
public enum FirstRunWizardStep: Equatable, Sendable {
    case welcome
    case viewerChoice
    case builtInSettings
    case firstLibrary
}

/// ウィザードでのビューワ選択。
public enum WizardViewerChoice: Equatable, Sendable {
    case builtIn
    case external
}

/// ウィザードの可視ステップ列とナビゲーションを状態から算出する純粋型。
/// `builtInSettings` は `viewerChoice == .builtIn` のときのみ可視。
public struct FirstRunWizardFlow: Equatable, Sendable {
    public var viewerChoice: WizardViewerChoice

    public init(viewerChoice: WizardViewerChoice = .builtIn) {
        self.viewerChoice = viewerChoice
    }

    /// 表示すべきステップ順序。
    public var steps: [FirstRunWizardStep] {
        var result: [FirstRunWizardStep] = [.welcome, .viewerChoice]
        if viewerChoice == .builtIn {
            result.append(.builtInSettings)
        }
        result.append(.firstLibrary)
        return result
    }

    /// ドット総数（= 可視ステップ数）。
    public var count: Int { steps.count }

    /// 指定ステップの可視列内インデックス（ドット位置）。可視でなければ nil。
    public func index(of step: FirstRunWizardStep) -> Int? {
        steps.firstIndex(of: step)
    }

    /// 指定ステップの次の可視ステップ。終端なら nil。
    public func next(after step: FirstRunWizardStep) -> FirstRunWizardStep? {
        guard let i = index(of: step), i + 1 < steps.count else { return nil }
        return steps[i + 1]
    }

    /// 指定ステップの前の可視ステップ。先頭なら nil。
    public func previous(before step: FirstRunWizardStep) -> FirstRunWizardStep? {
        guard let i = index(of: step), i > 0 else { return nil }
        return steps[i - 1]
    }
}
