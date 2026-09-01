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

/// 一時名への退避はできたが、目的地への 2 歩目にも、元の名前への巻き戻しにも失敗した。
/// **人が一時名のファイルを探しに行けるようにする**ため、呼び出し側は
/// `BookRenameExecutor.orphanReason(stagingPath:underlying:)` で報告文を組み立てること。
private struct StagingRollbackFailure: Error {
    let stagingPath: String
    let underlying: Error
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
            let from = URL(fileURLWithPath: row.oldPath)
            let to = URL(fileURLWithPath: row.newPath)
            do {
                try Self.caseAwareMove(from: from, to: to, using: fileManager)
            } catch let e as StagingRollbackFailure {
                failed.append(RenameFailure(
                    id: row.id, reason: Self.orphanReason(stagingPath: e.stagingPath, underlying: e.underlying)))
                continue
            } catch {
                failed.append(RenameFailure(id: row.id, reason: error.localizedDescription))
                continue
            }
            // ここから先はファイルが動いている。DB の更新に失敗したら**ファイルを戻す**
            // （DB が正。パスが合わない本は開けなくなる）。
            do {
                try updatePath(row.id, row.newPath)
                applied += 1
            } catch {
                do {
                    // Codex P1: 大文字小文字だけの改名の巻き戻しも、前方向の改名と同じ理由
                    // （大文字小文字を区別しないファイルシステムでの「既に存在する」）で失敗しうる。
                    // 前方向と同じ一時名経由の move を使う。
                    try Self.caseAwareMove(from: to, to: from, using: fileManager)
                    failed.append(RenameFailure(id: row.id, reason: error.localizedDescription))
                } catch let e as StagingRollbackFailure {
                    failed.append(RenameFailure(
                        id: row.id, reason: Self.orphanReason(stagingPath: e.stagingPath, underlying: e.underlying)))
                } catch {
                    failed.append(RenameFailure(
                        id: row.id,
                        reason: Self.orphanReason(stagingPath: to.path, underlying: error)))
                }
            }
        }
        return RenameApplyResult(applied: applied, failed: failed)
    }

    /// 大文字小文字だけが違う移動は、一時名を経由しないと
    /// 「既に存在する」で落ちる（macOS 既定のファイルシステムは大文字小文字を区別しない）。
    /// **前方向の改名と、その巻き戻しの両方がこれを必要とする**
    /// （Codex P1: 巻き戻しだけ直接 move にしていたため、大文字小文字だけの改名で
    /// `updatePath` が投げると「ファイルは新名のまま・DB は旧名のまま」の食い違いが残っていた）。
    ///
    /// 2 歩目（一時名 → 目的地）が失敗したら一時名から `from` へ戻すことを試みる。
    /// 戻せたら元の失敗を投げ直す。戻せなければ `StagingRollbackFailure` を投げ、
    /// 呼び出し側が「一時名のまま残っている」ことを報告できるようにする。
    private static func caseAwareMove(from: URL, to: URL, using fileManager: FileManager) throws {
        guard from.path != to.path, from.path.lowercased() == to.path.lowercased() else {
            try fileManager.moveItem(at: from, to: to)
            return
        }
        let staging = to.deletingLastPathComponent()
            .appendingPathComponent(to.lastPathComponent + ".stacknest-rename-\(UUID().uuidString)")
        try fileManager.moveItem(at: from, to: staging)
        do {
            try fileManager.moveItem(at: staging, to: to)
        } catch {
            do {
                try fileManager.moveItem(at: staging, to: from)
            } catch let rollbackError {
                throw StagingRollbackFailure(stagingPath: staging.path, underlying: rollbackError)
            }
            throw error
        }
    }

    /// 巻き戻しに失敗したときの理由。**人が探しに行けるようにパスを必ず含める。**
    static func orphanReason(stagingPath: String, underlying: Error) -> String {
        "手動確認が必要: ファイルが \(stagingPath) のまま残っている可能性があります"
            + "（\(underlying.localizedDescription)）"
    }
}
