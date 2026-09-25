// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import StackNest
import AppCore
import LibraryServerAPI
import RemoteClient

/// G54-S3e fix round 1（レビュー Important）: `openViewer` が `beginOpen` の早期 return（前面化／
/// 開き中の無視）を通っても、巻送りの判定で預けた manifest（`manifestHandoff`）を片付けること。
///
/// **背景**: 以前は `manifestHandoff.take(...)` を Task の中・分岐の奥（`manifestForOpening`）でしか
/// 呼んでおらず、`beginOpen` が false を返す呼び出しは Task 自体を作らないため take が一度も走らなかった。
/// 預かりは `maxAge`（30 秒）以内なら残り続け、後から来る無関係な `openViewer` 呼び出し（同じ本 ID）が
/// それを「取ったばかりの manifest」として拾ってしまう ―― サーバの最新位置より古い
/// `epubLocator`/`etag` を、永続化ゲート off（`holdPersistUntilMoved: m == nil` が false になる）のまま
/// 使うことになる。
///
/// 修正は `openViewer` の先頭・どの早期 return よりも前で `take` するよう変更した。この関数自体は
/// `private` の `manifestHandoff` を直接操作できないので、`RemoteLibraryState.testPutManifestHandoff` /
/// `testTakeManifestHandoff`（本体では使わない・テスト専用の注入点。`LocalControlController.testOpenWindowHook`
/// と同じ趣旨）を通す。
@MainActor
@Suite("G54-S3e fix round 1: openViewer の早期 return でも manifest の預かりを片付ける")
struct RemoteManifestHandoffTests {
    private func makeMemoryOnlyCache() -> RemoteCoverCache {
        RemoteCoverCache(cache: nil, serverID: nil, libraryUUID: nil)
    }

    private func makeState() -> RemoteLibraryState {
        RemoteLibraryState(
            client: RemoteLibraryClient(baseURL: URL(string: "http://127.0.0.1:1/")!, deviceToken: "device"),
            serverID: UUID(), libraryUUID: "LIB-\(UUID().uuidString)",
            libraryName: "テスト", locked: false, libraryToken: "TOKEN",
            coverCache: makeMemoryOnlyCache())
    }

    private func makeBook(id: Int) -> BookListItemDTO {
        BookListItemDTO(
            id: id, title: "t", author: nil, series: nil, volume: nil,
            rating: 0, unseen: false, bookType: 0, pages: nil, lastPage: nil,
            lastReadAt: nil, dateAdded: Date(), hasCover: false, coverVersion: nil,
            filename: nil)   // filename なし＝ BookCategory の弾きを経由せず beginOpen まで進む
    }

    /// **わざと壊して落ちることを確認済み**（`openViewer` 先頭の `take` を Task の中に戻すと、この
    /// テストは `testTakeManifestHandoff` が非 nil を返して落ちる）。
    @Test func openViewerThatDefersToAnExistingOpenStillClearsTheHandoff() {
        let s = makeState()
        let bookID = 909_001
        let identity = ViewerIdentity.remote(serverID: s.serverID.uuidString, libraryUUID: s.libraryUUID, bookID: bookID)

        // 「開き中」を模擬する: 1 回 beginOpen して opening 集合へ入れておく。以後の beginOpen は
        // `.ignore` → false を返し、openViewer は Task を作らずに早期 return する。
        #expect(ViewerWindowRegistry.shared.beginOpen(identity) == true)
        defer { ViewerWindowRegistry.shared.cancelOpen(identity) }   // シングルトンなので必ず後始末する

        // 巻送りの判定が置いたはずの預かり（本来は resolveRemoteVolume/resolveRemoteEPUBSibling が put する）。
        let manifest = ManifestDTO(pageCount: 10, direction: "ltr", format: "epub", etag: "etag-1")
        s.testPutManifestHandoff(bookID: bookID, value: manifest)

        s.openViewer(book: makeBook(id: bookID))   // beginOpen が false → 早期 return（Task 無し）

        // 早期 return でも先頭の take で消費済み。残っていれば、後の無関係な open がこれを拾ってしまう。
        #expect(s.testTakeManifestHandoff(bookID: bookID) == nil)
    }

    /// 対照: 預かりが無い本を同じ経路（開き中を無視）で呼んでも、何も起きず nil のまま。
    @Test func openViewerThatDefersWithNoHandoffStaysEmpty() {
        let s = makeState()
        let bookID = 909_002
        let identity = ViewerIdentity.remote(serverID: s.serverID.uuidString, libraryUUID: s.libraryUUID, bookID: bookID)

        #expect(ViewerWindowRegistry.shared.beginOpen(identity) == true)
        defer { ViewerWindowRegistry.shared.cancelOpen(identity) }

        s.openViewer(book: makeBook(id: bookID))

        #expect(s.testTakeManifestHandoff(bookID: bookID) == nil)
    }
}
