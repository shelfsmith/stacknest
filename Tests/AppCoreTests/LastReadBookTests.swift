import Testing
import Foundation
@testable import AppCore

@MainActor
@Suite struct LastReadBookTests {
    private func fresh(_ n: String) -> UserDefaults {
        let d = UserDefaults(suiteName: n)!; d.removePersistentDomain(forName: n); return d
    }
    @Test func roundTripAllKinds() throws {
        let cases: [LastReadBook] = [
            .local(bundlePath: "/x.snlib", bookID: 3, title: "L"),
            .remote(serverID: UUID(), serverURL: "http://h:1/", libraryUUID: "u", libraryName: "R", bookID: 5, title: "RR", locked: true),
            .offline(bookID: 7, title: "O"),
        ]
        for c in cases {
            let data = try JSONEncoder().encode(c)
            #expect(try JSONDecoder().decode(LastReadBook.self, from: data) == c)
        }
    }
    @Test func trackerPersistsAndLoads() {
        let d = fresh("lrb.persist")
        let t = LastReadTracker(defaults: d)
        #expect(t.last == nil)
        let ref = LastReadBook.offline(bookID: 9, title: "Z")
        t.record(ref)
        #expect(t.last == ref)
        #expect(LastReadTracker(defaults: d).last == ref)
    }
    @Test func titleAccessor() {
        #expect(LastReadBook.offline(bookID: 1, title: "T").title == "T")
    }
}
