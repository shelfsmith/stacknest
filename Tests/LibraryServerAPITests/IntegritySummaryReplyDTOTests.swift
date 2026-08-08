// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryServerAPI

/// `IntegritySummaryReply.lastScanAt`/`lastScanAtKnown` の Codable テスト（2026-08-08 smoke フィードバック）。
///
/// この DTO は「フィールドが JSON に無い」（旧サーバ）と「フィールドはあるが値が null」
/// （新サーバの『未検査』）を区別するために独自の `init(from:)`/`encode(to:)` を持つ。
/// `Optional<Int64>` の既定の `decodeIfPresent`/`encodeIfPresent` はこの 2 つを区別しない
/// （どちらも `nil`/キー省略になる）ため、ここでその区別が実際に効くことを直接確認する。
@Suite("IntegritySummaryReply.lastScanAt (G29 smoke fix)")
struct IntegritySummaryReplyDTOTests {
    @Test("旧サーバ（lastScanAt キー自体が無い JSON）はエラーにならず lastScanAtKnown=false で decode できる")
    func decodesOldServerResponseWithoutThrowing() throws {
        let json = #"{"checked":10,"unchecked":2,"damaged":1,"degraded":0}"#
        let reply = try JSONDecoder().decode(IntegritySummaryReply.self, from: Data(json.utf8))
        #expect(reply.checked == 10)
        #expect(reply.lastScanAt == nil)
        #expect(reply.lastScanAtKnown == false, "キーが無いのは旧サーバ ―― 『未検査』と混同してはいけない")
    }

    @Test("新サーバ・未検査（明示的に null）は lastScanAtKnown=true・lastScanAt=nil")
    func decodesNewServerExplicitNull() throws {
        let json = #"{"checked":0,"unchecked":5,"damaged":0,"degraded":0,"lastScanAt":null}"#
        let reply = try JSONDecoder().decode(IntegritySummaryReply.self, from: Data(json.utf8))
        #expect(reply.lastScanAt == nil)
        #expect(reply.lastScanAtKnown == true, "キーは存在する（値が null）ので『答えは得た』扱いになる")
    }

    @Test("新サーバ・検査済みは epoch 秒がそのまま入る")
    func decodesNewServerWithValue() throws {
        let json = #"{"checked":3,"unchecked":0,"damaged":1,"degraded":0,"lastScanAt":1700000000}"#
        let reply = try JSONDecoder().decode(IntegritySummaryReply.self, from: Data(json.utf8))
        #expect(reply.lastScanAt == 1_700_000_000)
        #expect(reply.lastScanAtKnown == true)
    }

    @Test("encode は lastScanAt が nil でもキー自体を省略しない（null を明示する）")
    func encodeAlwaysIncludesTheKeyEvenWhenNil() throws {
        // `encodeIfPresent` を使っていたら nil のときキーごと消え、旧サーバの沈黙と
        // 区別できなくなる ―― ここはそれを防ぐための最重要契約なので、生 JSON を直接見る。
        let reply = IntegritySummaryReply(checked: 0, unchecked: 5, damaged: 0, degraded: 0, lastScanAt: nil)
        let data = try JSONEncoder().encode(reply)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains(#""lastScanAt":null"#), "nil でもキーを省略してはいけない: \(json)")
    }

    @Test("encode → decode のラウンドトリップで lastScanAtKnown が true として往復する")
    func roundTripsAsKnownEvenWhenValueIsNil() throws {
        let original = IntegritySummaryReply(checked: 1, unchecked: 1, damaged: 0, degraded: 0, lastScanAt: nil)
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(IntegritySummaryReply.self, from: data)
        #expect(back.lastScanAt == nil)
        #expect(back.lastScanAtKnown == true, "自分自身が明示的に null を送った場合はキーが存在するので known のまま")
    }

    @Test("値ありのラウンドトリップも往復する")
    func roundTripsWithValue() throws {
        let original = IntegritySummaryReply(checked: 1, unchecked: 1, damaged: 0, degraded: 0, lastScanAt: 42)
        let back = try JSONDecoder().decode(IntegritySummaryReply.self, from: try JSONEncoder().encode(original))
        #expect(back.lastScanAt == 42)
        #expect(back.lastScanAtKnown == true)
    }
}
