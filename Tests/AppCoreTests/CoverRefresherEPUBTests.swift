// SPDX-License-Identifier: MIT
import Testing
import Foundation
import EPUBAdapter
@testable import AppCore

/// `CoverRefresher` が EPUB を `EPUBAdapter.reader` に回すことを、Washi に触れずに確かめる。
@Suite("CoverRefresher の EPUB 分岐", .serialized)
struct CoverRefresherEPUBTests {
    struct StubReader: EPUBReading {
        let cover: Data?
        func open(url: URL) async throws -> EPUBBookInfo {
            EPUBBookInfo(title: "t", author: nil, language: nil, readingDirection: .unknown)
        }
        func coverImageData(url: URL, maxPixelSize: Int) async throws -> Data? { cover }
    }

    private func tmpEPUB() throws -> URL {
        let u = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("x-\(UUID().uuidString).epub")
        try Data("zz".utf8).write(to: u)
        return u
    }

    @Test("登録された reader の表紙をそのまま返す")
    func usesRegisteredReader() async throws {
        let saved = EPUBAdapter.reader; defer { EPUBAdapter.reader = saved }
        EPUBAdapter.reader = StubReader(cover: Data([0xFF, 0xD8, 0x01]))
        let data = try await CoverRefresher.extractCoverData(sourceURL: try tmpEPUB(), preferredName: nil)
        #expect(data == Data([0xFF, 0xD8, 0x01]))
    }

    @Test("表紙の無い EPUB は unsupportedFormat（既存の『作れない』経路）")
    func noCoverFallsToUnsupported() async throws {
        let saved = EPUBAdapter.reader; defer { EPUBAdapter.reader = saved }
        EPUBAdapter.reader = StubReader(cover: nil)
        await #expect(throws: CoverRefreshError.unsupportedFormat) {
            _ = try await CoverRefresher.extractCoverData(sourceURL: try tmpEPUB(), preferredName: nil)
        }
    }

    @Test("未登録でもクラッシュせず unsupportedFormat")
    func unregisteredIsSafe() async throws {
        let saved = EPUBAdapter.reader; defer { EPUBAdapter.reader = saved }
        EPUBAdapter.reader = nil
        await #expect(throws: CoverRefreshError.unsupportedFormat) {
            _ = try await CoverRefresher.extractCoverData(sourceURL: try tmpEPUB(), preferredName: nil)
        }
    }
}
