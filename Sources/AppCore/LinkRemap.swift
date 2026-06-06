// SPDX-License-Identifier: MIT
import Foundation

/// リンク切れ復旧のための純粋なパス操作（FileManager 非依存・実在判定は呼び出し側）。
public enum LinkRemap {
    /// 親ディレクトリ（最後のコンポーネントを除いた部分）でグループ化。安定順。
    public static func groupByParentDirectory(_ paths: [String]) -> [(directory: String, paths: [String])] {
        var order: [String] = []
        var map: [String: [String]] = [:]
        for p in paths {
            let dir = (p as NSString).deletingLastPathComponent
            if map[dir] == nil { order.append(dir) }
            map[dir, default: []].append(p)
        }
        return order.map { (directory: $0, paths: map[$0]!) }
    }

    /// `oldDir` 配下の path を `newDir + 相対残り` へ。配下でない path は結果に含めない。
    /// コンポーネント境界を尊重（"/a/b" は "/a/bc" を含まない）。絶対パスの先頭スラッシュを保持。
    public static func remap(paths: [String], oldDir: String, newDir: String) -> [(old: String, new: String)] {
        let oldComps = components(oldDir)
        var out: [(old: String, new: String)] = []
        for p in paths {
            let comps = components(p)
            guard comps.count >= oldComps.count, Array(comps.prefix(oldComps.count)) == oldComps else { continue }
            let rel = comps.suffix(comps.count - oldComps.count)
            // newDir の末尾スラッシュを除き、相対コンポーネントを付加（newDir の先頭スラッシュは保持）。
            var newPath = newDir
            if newPath.count > 1, newPath.hasSuffix("/") { newPath.removeLast() }
            for c in rel { newPath += "/" + c }
            out.append((old: p, new: newPath))
        }
        return out
    }

    private static func components(_ s: String) -> [String] {
        s.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
}
