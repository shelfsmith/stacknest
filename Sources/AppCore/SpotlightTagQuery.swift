// SPDX-License-Identifier: MIT
import Foundation

/// Spotlight でタグの付いた項目だけを引く。
///
/// **Finder タグの変更は mtime を動かさない**（spec §3.1・実測）ので、監視フォルダの仕組みでは
/// 検出できない。全件の xattr を読むのは 12,000 冊規模で割に合わない。
/// `kMDItemUserTags` は索引対象なので、**タグの付いた項目だけ**を規模非依存で引ける
/// （実測: 10,786 冊の庫で 8 件を 0.13 秒）。
public enum SpotlightTagQuery {
    /// そのボリュームの Spotlight 索引が有効か。
    /// **索引が無効なボリュームは実在する**（実測: `DATA04` / `download`）。
    public static func isIndexingEnabled(volume: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: volume.path) else { return false }
        guard let out = try? run("/usr/bin/mdutil", ["-s", volume.path]) else { return false }
        // "Indexing enabled." / "Indexing and searching disabled." / "Indexing disabled."
        return out.contains("Indexing enabled")
    }

    /// タグの付いた項目のパス一覧。
    public static func taggedPaths(in volume: URL) throws -> [String] {
        let out = try run("/usr/bin/mdfind", ["-onlyin", volume.path, "kMDItemUserTags == \"*\""])
        return out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    private static func run(_ launchPath: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        // 出力が大きくても詰まらないよう、waitUntilExit の前に読み切る
        // （パイプのバッファが満杯になると子プロセスが write でブロックし、
        // 先に wait すると親子で永久待ちになる）。
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
