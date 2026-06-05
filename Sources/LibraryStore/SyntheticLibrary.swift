// SPDX-License-Identifier: MIT
import Foundation

/// 決定論的な合成ライブラリ生成（B9 計測ハーネス用・DB のみ）。
/// 1 トランザクションで N 件を一括 INSERT（FTS5 trigger も走る）。実ファイルは作らない。
public enum SyntheticLibrary {
    public static func generate(into db: Database, count: Int, seed: UInt64 = 42) throws {
        var rng = SplitMix64(seed: seed)
        let authors = (0..<30).map { "作者\($0)" }
        let genres  = (0..<12).map { "ジャンル\($0)" }
        let kwA     = (0..<40).map { "KA\($0)" }
        let kwB     = (0..<40).map { "KB\($0)" }
        let seriesCount = max(1, count / 20)
        let base = Date(timeIntervalSince1970: 1_600_000_000).timeIntervalSince1970
        try db.write { gdb in
            for i in 0..<count {
                let series  = "シリーズ\(Int(rng.next() % UInt64(seriesCount)))"
                let volume  = Double((i % 50) + 1)
                let title   = "\(series) 第\(Int(volume))巻"
                let author  = authors[Int(rng.next() % UInt64(authors.count))]
                let genre   = genres[Int(rng.next() % UInt64(genres.count))]
                let ka      = kwA[Int(rng.next() % UInt64(kwA.count))]
                let kb      = kwB[Int(rng.next() % UInt64(kwB.count))]
                let bookType = Int(rng.next() % 6)
                let rating   = Int(rng.next() % 6)
                let pages    = Int(rng.next() % 400) + 1
                let dateAdded = base + Double(i)
                // Tables.insertBookSQL の 20 列順:
                // id, title, author, genre, path, date_added, play_date, book_type, file_type,
                // pages, rating, unseen, keyword_a, keyword_b, keyword_c, neta, memo, series, volume, cover_image_name
                try gdb.execute(sql: Tables.insertBookSQL, arguments: [
                    i + 1, title, author, genre, "/synthetic/\(i + 1).zip", dateAdded, nil,
                    bookType, 2, pages, rating, 1, ka, kb, nil, nil, nil, series, volume, nil
                ])
            }
        }
    }
}

/// 決定論 PRNG（再現可能。Math.random 非使用）。
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
