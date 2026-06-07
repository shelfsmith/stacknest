// SPDX-License-Identifier: MIT
import Foundation

/// ライブラリバンドル内 `Backups/` の世代バックアップ運用（Phase 2.8 B22）。
/// SQLite 操作は `Database` に委譲し、ここはファイル運用と編集検知（純 Foundation）を担う。
public enum BackupManager {
    /// SQLite ファイルヘッダの file change counter（offset 24、4 バイト big-endian）を読む。
    /// journal_mode=delete ではトランザクションコミットごとに増加するため、
    /// 「前回から編集があったか」の安価な判定に使える。ファイルが無ければ nil。
    public static func changeCounter(of sqliteURL: URL) -> UInt32? {
        guard let handle = try? FileHandle(forReadingFrom: sqliteURL) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 28), data.count >= 28 else { return nil }
        let b = [UInt8](data[24..<28])
        return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
    }
}
