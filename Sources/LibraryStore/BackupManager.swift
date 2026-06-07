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

    private static let prefix = "library-"
    private static let suffix = ".sqlite"

    /// バンドル内の世代ディレクトリ `<bundle>/Backups`。
    public static func backupsDir(for bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent("Backups")
    }

    /// `db` の一貫スナップショットを `<bundle>/Backups/library-<timestamp>.sqlite` に取得する。
    /// ディレクトリが無ければ作成。timestamp は呼び出し側が "yyyyMMdd-HHmmss" で渡す。
    @discardableResult
    public static func makeBackup(from db: Database, bundleURL: URL, timestamp: String) throws -> URL {
        let dir = backupsDir(for: bundleURL)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("\(prefix)\(timestamp)\(suffix)")
        try db.backup(to: out)
        return out
    }

    /// `Backups/` 内の `library-*.sqlite` を新しい順（名前降順 = 時系列降順）で返す。
    public static func list(in backupsDir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: backupsDir, includingPropertiesForKeys: nil)) ?? []
        return items
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// 新しい `keep` 個を残し、それより古い世代を削除する。`library-*.sqlite` 以外は触らない。
    public static func prune(in backupsDir: URL, keep: Int) throws {
        let all = list(in: backupsDir)
        guard all.count > keep else { return }
        for url in all[keep...] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 最新世代から復元する。破損本体は削除せず `library.corrupt-<timestamp>.sqlite` に退避し、
    /// stale な sidecar（-journal / -wal / -shm）を除去してから最新バックアップを本体名にコピーする。
    /// バックアップが 1 つも無ければ何もせず false を返す（本体は触らない）。
    @discardableResult
    public static func restoreLatest(bundleURL: URL, databaseFileName: String, timestamp: String) throws -> Bool {
        let fm = FileManager.default
        let dir = backupsDir(for: bundleURL)
        guard let latest = list(in: dir).first else { return false }

        let live = bundleURL.appendingPathComponent(databaseFileName)
        // 破損本体を退避（拡張子の前に .corrupt-<ts> を挿入）。
        if fm.fileExists(atPath: live.path) {
            let base = (databaseFileName as NSString).deletingPathExtension   // "library"
            let ext = (databaseFileName as NSString).pathExtension            // "sqlite"
            let corrupt = bundleURL.appendingPathComponent("\(base).corrupt-\(timestamp).\(ext)")
            try fm.moveItem(at: live, to: corrupt)
        }
        // stale sidecars を除去（退避した本体には付随させない）。
        for sidecar in ["\(databaseFileName)-journal", "\(databaseFileName)-wal", "\(databaseFileName)-shm"] {
            let s = bundleURL.appendingPathComponent(sidecar)
            if fm.fileExists(atPath: s.path) { try? fm.removeItem(at: s) }
        }
        try fm.copyItem(at: latest, to: live)
        return true
    }
}
