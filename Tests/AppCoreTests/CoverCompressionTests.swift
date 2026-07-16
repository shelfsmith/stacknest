// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
@testable import LibraryStore
import StackroomFormat

@Suite("CoverCompression")
struct CoverCompressionTests {
    @Test func skipsExternalCovers() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cc_\(UUID().uuidString)")
        let bundle = dir.appendingPathComponent("lib.stacknest")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let db = try Database.openFile(at: bundle.appendingPathComponent("library.sqlite"), mode: .createOrReplace)
        try db.migrate()
        // 外部表紙の本（source も存在しない）＋ source missing の内部表紙本 → いずれも更新 0
        _ = try db.insertBookReturningID(BookRecord(
            id: 0, title: "ext", path: "/nonexistent/a.zip", coverImageName: CoverSource.externalSentinel,
            dateAdded: Date()))
        _ = try db.insertBookReturningID(BookRecord(
            id: 0, title: "missing-source", path: "/nonexistent/b.zip", coverImageName: nil,
            dateAdded: Date()))
        var progressCalls = 0
        let updated = try await CoverCompression.compressOversizedCovers(
            db: db, bundleURL: bundle, progress: { _, _ in progressCalls += 1 }, isCancelled: { false })
        #expect(updated == 0)          // 外部表紙 or source 不在は圧縮しない
        #expect(progressCalls == 2)    // progress は全件走査で呼ばれる
    }
}
