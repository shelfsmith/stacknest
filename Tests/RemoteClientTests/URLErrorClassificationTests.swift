// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import RemoteClient

@Suite("URLError classification")
struct URLErrorClassificationTests {
    @Test func cancelledMapsToCancelledNotServerMinus1() {
        #expect(RemoteLibraryClient.classify(URLError(.cancelled)) == .cancelled)
    }
    @Test func timeoutStillMapsToTimeout() {
        #expect(RemoteLibraryClient.classify(URLError(.timedOut)) == .timeout)
    }
    @Test func offlineStillMapsToOffline() {
        #expect(RemoteLibraryClient.classify(URLError(.notConnectedToInternet)) == .offline)
    }
    @Test func genuinelyUnknownStillMapsToServerMinus1() {
        #expect(RemoteLibraryClient.classify(URLError(.badServerResponse)) == .server(-1))
    }
}
