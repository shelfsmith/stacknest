// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

@Suite("G48-3: リモートの EPUB 振り分け")
struct RemoteEPUBRoutingTests {
    @Test func textEPUBOnlyWhenBothAgree() {
        #expect(RemoteEPUBRouting.route(filename: "a.epub", manifestFormat: "epub") == .textEPUB)
        #expect(RemoteEPUBRouting.route(filename: "A.EPUB", manifestFormat: "epub") == .textEPUB)
        #expect(RemoteEPUBRouting.route(filename: "a.epub", manifestFormat: "text") == .pages)     // 画像本
        #expect(RemoteEPUBRouting.route(filename: "a.zip", manifestFormat: "epub") == .pages)      // 拡張子が違えば信じない
        #expect(RemoteEPUBRouting.route(filename: nil, manifestFormat: "epub") == .pages)
    }
}
