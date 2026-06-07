// SPDX-License-Identifier: MIT
import Foundation

/// 破損 DB からの救出（Phase 2.9 B23）。システム `/usr/bin/sqlite3` の `.recover`
/// （破損 B-tree から可能な範囲を救出）を `sqlite3 <broken> ".recover" | sqlite3 <out>`
/// 相当で実行する。救出結果の検証・差し替えは呼び出し側の責務。
public enum DatabaseRecovery {
    private static let sqlite3Path = "/usr/bin/sqlite3"

    /// `brokenURL` を入力に `.recover` を実行し、救出 DB を `outURL` に生成する。
    /// 両プロセスが正常終了し out が生成されれば true。入力欠如・sqlite3 不在・
    /// プロセス失敗時は false（呼び出し側は live を変更しない）。
    public static func recover(from brokenURL: URL, to outURL: URL) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: brokenURL.path) else { return false }
        guard fm.isExecutableFile(atPath: sqlite3Path) else { return false }
        // 既存 out は消す（sqlite3 は追記し得るため、まっさらに作る）。
        if fm.fileExists(atPath: outURL.path) { try? fm.removeItem(at: outURL) }

        let pipe = Pipe()

        let dumper = Process()
        dumper.executableURL = URL(fileURLWithPath: sqlite3Path)
        dumper.arguments = [brokenURL.path, ".recover"]
        dumper.standardOutput = pipe

        let loader = Process()
        loader.executableURL = URL(fileURLWithPath: sqlite3Path)
        loader.arguments = [outURL.path]
        loader.standardInput = pipe

        do {
            try dumper.run()
            try loader.run()
        } catch {
            return false
        }
        dumper.waitUntilExit()
        loader.waitUntilExit()

        return dumper.terminationStatus == 0
            && loader.terminationStatus == 0
            && fm.fileExists(atPath: outURL.path)
    }
}
