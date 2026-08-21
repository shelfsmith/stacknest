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
        // 実 I/O はここまで。判定そのものは `parseIndexingState` に切り出してテストで固定する。
        guard let out = try? run("/usr/bin/mdutil", ["-s", volume.path]) else { return false }
        // "Indexing enabled." / "Indexing and searching disabled." / "Indexing disabled."
        return parseIndexingState(out)
    }

    /// タグの付いた項目のパス一覧。
    public static func taggedPaths(in volume: URL) throws -> [String] {
        let out = try run("/usr/bin/mdfind", ["-onlyin", volume.path, "kMDItemUserTags == \"*\""])
        return parsePaths(out)
    }

    /// `mdutil -s` の出力から索引の有効・無効を読む。
    ///
    /// **ここが誤ると被害が大きい。**索引が無効なのに「有効」と判定すると、`mdfind` は何も
    /// 返さないので**全ての本が「Finder 側にタグ無し」に見え**、3 方向マージが
    /// 「ユーザーが全部消した」と解釈して**庫じゅうのタグを消しかねない**（spec §4.5 の
    /// 対策がこれも救う設計になっている）。実機で確認した 3 表現をテストで固定する。
    static func parseIndexingState(_ output: String) -> Bool {
        // "Indexing and searching disabled." が "Indexing" で始まるため、
        // **無効の表現を先に弾いてから**有効を見ること。
        if output.contains("disabled") { return false }
        return output.contains("Indexing enabled")
    }

    /// `mdfind` の出力（1 行 1 パス）を配列にする。
    static func parsePaths(_ output: String) -> [String] {
        output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
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
