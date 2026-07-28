// SPDX-License-Identifier: MIT

/// ⌘⇧O（最後に開いたページを開く）の分岐判定。AppKit 非依存の純ロジック。
///
/// #7（`05fffc3`）以前、ローカル経路は「施錠庫なら一律フォーカスのみ」という粗い判定で、
/// リモート経路だけが「認証済みなら開く」を見ていた。この非対称性が
/// 「施錠庫の窓が開いていて解錠済みのとき ⌘⇧O が完全に無反応」というバグを生んだ。
/// 両経路をこの 1 関数に通すことで、規則のずれが再発しないようにする。
public enum ResumeGate {
    public enum Decision: Equatable, Sendable {
        /// 本を直接開く（未施錠、または既にこのセッションで解錠済み）。
        case openBook
        /// 窓を前面化し、解錠成功後に開くため意図を保留する（施錠かつ未解錠）。
        case deferUntilUnlock
    }

    /// - Parameters:
    ///   - isLocked: 庫にパスワードが設定されているか。
    ///   - isUnlocked: 現在のセッションで解錠に成功済みか。
    /// - Returns: 本を開いてよいのは「未施錠」または「解錠済み」の場合のみ。
    public static func decide(isLocked: Bool, isUnlocked: Bool) -> Decision {
        (!isLocked || isUnlocked) ? .openBook : .deferUntilUnlock
    }
}
