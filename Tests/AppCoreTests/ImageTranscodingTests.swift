// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("ImageTranscoding")
struct ImageTranscodingTests {
    @Test func passthroughReturnsIdenticalBytes() {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        let t = PassthroughTranscoder()
        #expect(t.scaled(data, maxWidth: 320) == data)
    }
}
