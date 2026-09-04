// SPDX-License-Identifier: MIT
import Testing
import Foundation
import EPUBAdapter
@testable import AppCore

/// `EPUBAdapter.reader` グローバルには触れない、純粋な `EPUBImageBookContent(handle:)` のテスト。
/// グローバルを差し替えるテストは `EPUBReaderGlobalTests` の `.serialized` 親 suite に置くこと。
@Suite("EPUBImageBookContent")
struct EPUBImageBookContentTests {
    final class FakeImageBook: EPUBImageBookReading, @unchecked Sendable {
        let pageCount: Int = 3
        let readingDirection: EPUBReadingDirection = .ltr
        let spreads: [EPUBPageSpread] = [.none, .none, .none]
        func imageData(at index: Int) async throws -> Data {
            Data([UInt8(index)])
        }
    }

    @Test("pageCount は handle に委譲")
    func pageCountDelegates() async throws {
        let content = EPUBImageBookContent(handle: FakeImageBook())
        let count = try await content.pageCount
        #expect(count == 3)
    }

    @Test("imageData(at:) は handle に委譲")
    func imageDataDelegates() async throws {
        let content = EPUBImageBookContent(handle: FakeImageBook())
        let data = try await content.imageData(at: 1)
        #expect(data == Data([1]))
    }

    @Test("範囲外は pageOutOfRange")
    func outOfRangeThrows() async throws {
        let content = EPUBImageBookContent(handle: FakeImageBook())
        await #expect(throws: BookContentError.pageOutOfRange(3)) {
            _ = try await content.imageData(at: 3)
        }
    }
}
