// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryServer
import LibraryServerAPI

@Suite("EventHub")
struct EventHubTests {
    @Test func publishReachesInScopeSubscriberOnly() async throws {
        let hub = EventHub()
        let a = await hub.subscribe(scope: .all)
        let b = await hub.subscribe(scope: .libraries(["other"]))   // "u1" を含まない scope
        await hub.publish(.bookChanged(library: "u1", bookID: 7))
        // a（.all）は受信
        var itA = a.stream.makeAsyncIterator()
        #expect(await itA.next() == .bookChanged(library: "u1", bookID: 7))
        // b（scope 外）へは届かない → unsubscribe で finish させ nil を確認
        await hub.unsubscribe(b.id)
        var itB = b.stream.makeAsyncIterator()
        #expect(await itB.next() == nil)
    }

    @Test func unsubscribeStopsDelivery() async throws {
        let hub = EventHub()
        let s = await hub.subscribe(scope: .all)
        await hub.unsubscribe(s.id)
        await hub.publish(.structureChanged(library: "u1"))
        var it = s.stream.makeAsyncIterator()
        #expect(await it.next() == nil)   // 解除後は finish 済みで nil
    }
}
