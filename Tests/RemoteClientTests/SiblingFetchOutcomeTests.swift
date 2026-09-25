// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import RemoteClient

/// G54-S3e 最終レビュー: `adjacentVolume` が投げたエラーの分類（巻送りの事前確認）。
@Suite("RemoteClientError.siblingFetchOutcome")
struct SiblingFetchOutcomeTests {
    @Test func lockedIsLocked() {
        #expect(RemoteClientError.libraryLocked.siblingFetchOutcome == .locked)
    }
    @Test func cancelledIsNoSibling() {
        #expect(RemoteClientError.cancelled.siblingFetchOutcome == .noSibling)
    }
    @Test func notFoundIsNoSibling() {
        #expect(RemoteClientError.notFound.siblingFetchOutcome == .noSibling)
    }
    @Test func offlineIsUnavailable() {
        #expect(RemoteClientError.offline.siblingFetchOutcome == .unavailable)
    }
    @Test func timeoutIsUnavailable() {
        #expect(RemoteClientError.timeout.siblingFetchOutcome == .unavailable)
    }
    @Test func serverIsUnavailable() {
        #expect(RemoteClientError.server(500).siblingFetchOutcome == .unavailable)
    }
    @Test func decodingIsUnavailable() {
        #expect(RemoteClientError.decoding.siblingFetchOutcome == .unavailable)
    }
    @Test func badRequestIsUnavailable() {
        #expect(RemoteClientError.badRequest(nil).siblingFetchOutcome == .unavailable)
    }
}
