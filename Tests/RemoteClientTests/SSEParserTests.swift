// SPDX-License-Identifier: MIT
import Testing
@testable import RemoteClient
import LibraryServerAPI

@Suite("SSEParser")
struct SSEParserTests {
    @Test func parsesFramesAcrossChunks() {
        var p = SSEParser()
        // 1 フレームが 2 チャンクに割れても復元する
        var out = p.consume("event: bookChanged\nda")
        #expect(out.isEmpty)
        out = p.consume("ta: {\"library\":\"u1\",\"bookId\":5}\n\n")
        #expect(out == [.bookChanged(library: "u1", bookID: 5)])
    }
    @Test func ignoresCommentsAndUnknown() {
        var p = SSEParser()
        #expect(p.consume(": ping\n\n").isEmpty)                                  // heartbeat
        #expect(p.consume("event: nope\ndata: {}\n\n").isEmpty)                    // 未知
        #expect(p.consume("event: structureChanged\ndata: {\"library\":\"u2\"}\n\n") == [.structureChanged(library: "u2")])
    }

    /// Regression（実機バグ）: `events()` は生バイトストリームを `forEachEvent(inRawBytes:)` で
    /// 復号する。`URLSession.AsyncBytes.lines` は**空行を落とす**ため、以前は SSE のフレーム区切り
    /// （空行）が失われ、SSEParser が 1 件も emit せず全イベントを取り落としていた。
    /// 本テストは生バイト供給（空行保持・byte 単位＝チャンク跨ぎ相当・コメント/未知混在）で
    /// 正しく LiveEvent 列が出ることを保証する。
    @Test func forEachEventDecodesRawByteStreamPreservingBlankLines() async throws {
        let raw = "event: bookChanged\ndata: {\"library\":\"u1\",\"bookId\":5}\n\n"
                + ": ping\n\n"                                                     // heartbeat（無視）
                + "event: nope\ndata: {}\n\n"                                      // 未知（無視）
                + "event: structureChanged\ndata: {\"library\":\"u2\"}\n\n"
        let bytes = AsyncStream<UInt8> { c in for b in raw.utf8 { c.yield(b) }; c.finish() }
        var events: [LiveEvent] = []
        try await SSEParser.forEachEvent(inRawBytes: bytes) { events.append($0) }
        #expect(events == [.bookChanged(library: "u1", bookID: 5), .structureChanged(library: "u2")])
    }

    /// Guard: 旧実装（`.lines` 相当＝空行を供給しない）ではフレームが確定せず 0 件になる。
    /// この不変条件を明文化し、再び `.lines` へ戻す退行を検知する。
    @Test func lineFeedWithoutBlankLinesNeverFinalizesFrame() {
        var p = SSEParser()
        var events: [LiveEvent] = []
        for line in ["event: bookChanged", "data: {\"library\":\"u1\",\"bookId\":5}"] {
            events += p.consume(line + "\n")   // 空行を一度も渡さない＝旧 events() の供給
        }
        #expect(events.isEmpty)
    }
}
