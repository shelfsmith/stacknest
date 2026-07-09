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
}
