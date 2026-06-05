// SPDX-License-Identifier: MIT
import Foundation
import LibraryStore

public enum DuplicateKind: Sendable, Equatable { case exact, possibleSeriesVolume }

public struct DuplicateGroup: Sendable, Equatable, Identifiable {
    public let kind: DuplicateKind
    public let key: String
    public let members: [BookRow]
    public var id: String { key }
    public init(kind: DuplicateKind, key: String, members: [BookRow]) {
        self.kind = kind; self.key = key; self.members = members
    }
}

public enum DuplicateFinder {
    /// volume(Double) を決定論的に文字列化（整数値は小数点なし）。
    /// 非有限値 (inf/nan) や Int 範囲外の巨大値は `Int(v)` が trap するため、
    /// その場合は `String(v)` に決定論的にフォールバックする（クラッシュ回避）。
    /// 上限は strict `<` で比較する: `Double(Int.max)` は 2^63（= Int.max+1）に丸まるため、
    /// `<=` だと境界値 2^63 が通過して `Int(v)` が trap してしまう。
    static func canonicalVolume(_ v: Double) -> String {
        guard v.isFinite, v >= Double(Int.min), v < Double(Int.max), v == v.rounded() else {
            return String(v)
        }
        return String(Int(v))
    }

    /// 同一サイズが 2 件以上衝突する本の id 集合（= バイト一致しうる＝ハッシュ要）。
    /// サイズが一意の単一ファイルはバイト双子になり得ないのでハッシュ不要。
    public static func idsNeedingHash(sizes: [(id: Int, size: Int64)]) -> Set<Int> {
        var bySize: [Int64: [Int]] = [:]
        for s in sizes { bySize[s.size, default: []].append(s.id) }
        var result: Set<Int> = []
        for (_, ids) in bySize where ids.count >= 2 { result.formUnion(ids) }
        return result
    }

    /// 完全一致: content_hash が非 nil・非空の本を hash でグループ化（2 件以上）。members は id 昇順。
    public static func findExact(_ books: [BookRow]) -> [DuplicateGroup] {
        var byHash: [String: [BookRow]] = [:]
        for b in books {
            guard let h = b.contentHash, !h.isEmpty else { continue }
            byHash[h, default: []].append(b)
        }
        return byHash.filter { $0.value.count >= 2 }
            .map { DuplicateGroup(kind: .exact, key: "exact:\($0.key)",
                                  members: $0.value.sorted { $0.id < $1.id }) }
            .sorted { $0.key < $1.key }
    }

    /// 同一の可能性: series&volume が両方非空一致でグループ化（2 件以上）。
    public static func findPossible(_ books: [BookRow]) -> [DuplicateGroup] {
        var byKey: [String: [BookRow]] = [:]
        for b in books {
            let s = (b.series ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty, let v = b.volume else { continue }
            let key = "possible:\(s)\u{0}\(canonicalVolume(v))"
            byKey[key, default: []].append(b)
        }
        return byKey.filter { $0.value.count >= 2 }
            .map { DuplicateGroup(kind: .possibleSeriesVolume, key: $0.key,
                                  members: $0.value.sorted { $0.id < $1.id }) }
            .sorted { $0.key < $1.key }
    }

    /// 無視キー除外 + overlap 抑制（possible の members 全員が単一 exact グループに含まれるものを除外）。
    public static func groups(_ books: [BookRow], ignoring ignored: Set<String>)
        -> (exact: [DuplicateGroup], possible: [DuplicateGroup]) {
        let exact = findExact(books).filter { !ignored.contains($0.key) }
        let exactMemberSets = exact.map { Set($0.members.map(\.id)) }
        let possible = findPossible(books)
            .filter { !ignored.contains($0.key) }
            .filter { g in
                let ids = Set(g.members.map(\.id))
                return !exactMemberSets.contains { ids.isSubset(of: $0) }
            }
        return (exact, possible)
    }
}
