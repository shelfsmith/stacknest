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

@Suite("LiveEvent maintenance events (G12b-3b)")
struct LiveEventMaintenanceTests {
    private func roundTrip(_ e: LiveEvent) -> LiveEvent? {
        let frame = e.sseFrame()  // "event: X\ndata: {...}\n\n"
        let lines = frame.split(separator: "\n", omittingEmptySubsequences: true)
        let ev = String(lines[0].dropFirst("event: ".count))
        let data = String(lines[1].dropFirst("data: ".count))
        return LiveEvent.decode(event: ev, data: data)
    }

    @Test func progressRoundTrips() {
        let e = LiveEvent.maintenanceProgress(library: "L1", job: "compress-covers", done: 3, total: 10)
        #expect(roundTrip(e) == e)
        #expect(e.library == "L1")
    }
    @Test func finishedRoundTrips() {
        let e = LiveEvent.maintenanceFinished(library: "L1", job: "complete-metadata", outcome: "done", count: 42)
        #expect(roundTrip(e) == e)
    }
    @Test func existingEventsUnaffected() {
        let e = LiveEvent.bookChanged(library: "L1", bookID: 7)
        #expect(roundTrip(e) == e)
    }
}
