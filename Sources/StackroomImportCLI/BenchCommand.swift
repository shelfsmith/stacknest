// SPDX-License-Identifier: MIT
import AppCore
import ArgumentParser
import Darwin
import Foundation
import LibraryStore

public struct BenchCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "bench",
        abstract: "Measure data-layer performance on synthetic libraries (B9)."
    )

    @Option(help: "Comma-separated book counts.")
    public var counts: String = "1000,10000,50000"

    @Option(help: "Repetitions per metric (median reported).")
    public var runs: Int = 5

    @Flag(help: "Use in-memory DB instead of a temp file.")
    public var inMemory: Bool = false

    @Option(help: "Query for the LIKE path (1-2 chars). Default 'KA' = broad short-query (worst case).")
    public var likeQuery: String = "KA"

    @Option(help: "Query for the FTS path (3+ chars). Default '第1巻' = selective (~2% of rows).")
    public var ftsQuery: String = "第1巻"

    public init() {}

    public func run() throws {
        let ns = counts.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        for n in ns {
            try benchOne(count: n)
        }
    }

    private func benchOne(count: Int) throws {
        // --- setup: 合成 DB ---
        let db: Database
        var fileURL: URL?
        if inMemory {
            db = try Database.openInMemory()
        } else {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("bench_\(count).sqlite")
            db = try Database.openFile(at: url, mode: .createOrReplace)
            fileURL = url
        }
        defer { db.close(); if let u = fileURL { try? FileManager.default.removeItem(at: u) } }
        try db.migrate()
        let genStart = ContinuousClock().now
        try SyntheticLibrary.generate(into: db, count: count)
        let gen = genStart.duration(to: .now)

        // --- memory: 最初の books 配列確保による RSS 増分（books はこの後 sort で再利用）。
        // open 計測より前に測ることで、open の反復確保による RSS high-water の影響を避ける。
        let before = residentBytes()
        let books = try db.fetchAllBooks()
        let after = residentBytes()
        let memMB = Double(max(0, after - before)) / (1024 * 1024)

        // --- timing metrics (median of `runs`) ---
        let open = try median(runs) { _ = try db.fetchAllBooks() }
        let sortCol = median(runs) { _ = books.sortedByColumn(ColumnSort(column: .title, ascending: true)) }
        let sortSV  = median(runs) { _ = books.sortedBySeriesAndVolume() }
        // like: 短クエリ（LIKE フルスキャン経路）。fts: 3+ 文字（FTS5 trigram 経路・選択的）。
        let like = try median(runs) { _ = try db.searchBooks(query: likeQuery, sidebarScope: .library) }
        let fts  = try median(runs) { _ = try db.searchBooks(query: ftsQuery, sidebarScope: .library) }
        let facet = try median(runs) { _ = try db.distinctValues(forColumn: "series", query: "", sidebarScope: .library) }
        _ = books.count   // keep books alive across the timing metrics above

        print(String(format: "N=%-6d gen:%5dms | open:%5dms sort.col:%5dms sort.sv:%5dms like:%5dms fts:%5dms facet:%5dms | mem:+%.1fMB",
                     count, ms(gen), ms(open), ms(sortCol), ms(sortSV), ms(like), ms(fts), ms(facet), memMB))
    }

    // MARK: helpers
    private func ms(_ d: Duration) -> Int {
        let c = d.components
        return Int(c.seconds) * 1000 + Int(c.attoseconds / 1_000_000_000_000_000)
    }

    /// throwing 版 median（ウォームアップ 1 回を捨て、runs 回の median）。
    private func median(_ runs: Int, _ body: () throws -> Void) rethrows -> Duration {
        try body()  // warmup
        var samples: [Duration] = []
        for _ in 0..<max(1, runs) {
            let s = ContinuousClock().now
            try body()
            samples.append(s.duration(to: .now))
        }
        samples.sort()
        return samples[samples.count / 2]
    }

    private func residentBytes() -> Int {
        var info = mach_task_basic_info()
        var cnt = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(cnt)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &cnt)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.resident_size) : 0
    }
}
