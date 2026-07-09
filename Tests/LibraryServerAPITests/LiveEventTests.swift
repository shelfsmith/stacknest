// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryServerAPI

@Suite("LiveEvent SSE encode/decode")
struct LiveEventTests {
    @Test func bookChangedRoundTrips() {
        let e = LiveEvent.bookChanged(library: "u1", bookID: 42)
        #expect(e.library == "u1")
        let frame = e.sseFrame()
        #expect(frame.contains("event: bookChanged\n"))
        #expect(frame.hasSuffix("\n\n"))
        // data 行の JSON を取り出して decode
        let dataLine = frame.split(separator: "\n").first { $0.hasPrefix("data: ") }!.dropFirst(6)
        #expect(LiveEvent.decode(event: "bookChanged", data: String(dataLine)) == .bookChanged(library: "u1", bookID: 42))
    }
    @Test func structureAndSettingsDecode() {
        #expect(LiveEvent.decode(event: "structureChanged", data: #"{"library":"u2"}"#) == .structureChanged(library: "u2"))
        #expect(LiveEvent.decode(event: "settingsChanged", data: #"{"library":"u3"}"#) == .settingsChanged(library: "u3"))
    }
    @Test func unknownEventIsNil() {
        #expect(LiveEvent.decode(event: "nope", data: "{}") == nil)
    }
}
