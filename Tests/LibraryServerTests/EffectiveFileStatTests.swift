// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryServer
@testable import LibraryStore

@Suite("effectiveFileStat live stat (G27a ③)")
struct EffectiveFileStatTests {
    private func book(path: String?, fileSize: Int64?, fileMtime: Double?) -> BookRow {
        BookRow(id: 1, title: "t", author: nil, genre: nil, path: path,
                dateAdded: Date(), playDate: nil, bookType: 0, fileType: 0, pages: nil,
                rating: 0, unseen: false, keywordA: nil, keywordB: nil,
                keywordC: nil, neta: nil, memo: nil,
                fileSize: fileSize, fileMtime: fileMtime)
    }

    private func tempFile(bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("efs-\(UUID().uuidString).zip")
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    @Test("DB 値が NULL でも実ファイルを stat して返す")
    func fileWithNullStoredStatUsesLiveStat() throws {
        let url = try tempFile(bytes: 100)
        defer { try? FileManager.default.removeItem(at: url) }

        let (mtime, size) = effectiveFileStat(for: book(path: url.path, fileSize: nil, fileMtime: nil))
        #expect(size == 100, "実ファイルの size を返していない")
        #expect(mtime != nil, "実ファイルの mtime を返していない")
    }

    @Test("差し替えでサイズが変われば返る値も変わる（＝ETag が動く）")
    func statReflectsFileReplacement() throws {
        let url = try tempFile(bytes: 100)
        defer { try? FileManager.default.removeItem(at: url) }
        let row = book(path: url.path, fileSize: 100, fileMtime: 1.0)

        let before = effectiveFileStat(for: row)
        try Data(repeating: 0x42, count: 250).write(to: url)
        let after = effectiveFileStat(for: row)

        #expect(before.size == 100)
        #expect(after.size == 250, "差し替え後も古い値を返している")
    }

    @Test("ファイルが無ければ従来どおり DB 値へフォールバックする")
    func missingFileFallsBackToStoredValues() throws {
        let (mtime, size) = effectiveFileStat(
            for: book(path: "/nonexistent/never-here.zip", fileSize: 777, fileMtime: 42.0))
        #expect(size == 777)
        #expect(mtime == 42.0)
    }

    @Test("path が nil なら (nil, nil)")
    func nilPathReturnsNils() throws {
        let (mtime, size) = effectiveFileStat(for: book(path: nil, fileSize: nil, fileMtime: nil))
        #expect(size == nil)
        #expect(mtime == nil)
    }

    @Test("ディレクトリは従来どおり live stat される（回帰防止）")
    func directoryStillLiveStats() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("efs-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let (mtime, size) = effectiveFileStat(for: book(path: dir.path, fileSize: nil, fileMtime: nil))
        #expect(mtime != nil)
        #expect(size != nil)
    }
}
