// SPDX-License-Identifier: MIT
import Foundation

public struct RenameFailure: Equatable, Sendable {
    public let id: Int
    public let reason: String
    public init(id: Int, reason: String) { self.id = id; self.reason = reason }
}

public struct RenameApplyResult: Equatable, Sendable {
    public let applied: Int
    public let failed: [RenameFailure]
    public init(applied: Int, failed: [RenameFailure]) {
        self.applied = applied; self.failed = failed
    }
}

/// 計画のうち `ok` の行だけを実行する。
///
/// **1 件の失敗で全体を止めない。**残りの行は続ける（止めると、どこまで進んだかが
/// 呼び出し側から分からなくなる）。パスの更新は呼び出し側から渡す
/// （`AppCore` は `Database` を知らないため、また試験でクロージャに差し替えるため）。
public enum BookRenameExecutor {
    public static func apply(
        rows: [RenamePlanRow],
        fileManager: FileManager = .default,
        updatePath: (Int, String) throws -> Void
    ) -> RenameApplyResult {
        var applied = 0
        var failed: [RenameFailure] = []

        for row in rows where row.status == .ok {
            do {
                let from = URL(fileURLWithPath: row.oldPath)
                let to = URL(fileURLWithPath: row.newPath)
                if row.isCaseOnlyRename {
                    // 大文字小文字を区別しないファイルシステムでは from → to の
                    // 直接 move が「既に存在する」で落ちる。一時名を経由する。
                    let staging = to.deletingLastPathComponent()
                        .appendingPathComponent(to.lastPathComponent + ".stacknest-rename-\(UUID().uuidString)")
                    try fileManager.moveItem(at: from, to: staging)
                    do {
                        try fileManager.moveItem(at: staging, to: to)
                    } catch {
                        // 2 歩目で落ちたら元に戻す（一時名のまま残さない）。
                        try? fileManager.moveItem(at: staging, to: from)
                        throw error
                    }
                } else {
                    try fileManager.moveItem(at: from, to: to)
                }
                try updatePath(row.id, row.newPath)
                applied += 1
            } catch {
                failed.append(RenameFailure(id: row.id, reason: error.localizedDescription))
            }
        }
        return RenameApplyResult(applied: applied, failed: failed)
    }
}
