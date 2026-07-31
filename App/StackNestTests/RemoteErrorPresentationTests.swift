// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import StackNest
import RemoteClient  // RemoteClientError は public なので @testable 不要

/// G25e: App 層（`RemoteLibraryState`）のユニットテスト。
///
/// **このターゲットが存在する理由**: G25d の実装中、`errorText = Self.message(for: e)` を
/// スクリプトで一括置換した際に `presentRemoteError` の本体まで置換され、**自己再帰**になった。
/// 失効以外のすべての通信エラーで無限再帰＝クラッシュする欠陥だったが、
/// コンパイラは自己再帰を警告せず、SPM の全テストは App ターゲットを見ないため素通りし、
/// 実機 smoke でもたまたま該当経路を踏まなかった。**レビューだけが検出できた。**
/// 同じ誤置換が再発しても気づけるよう、実際の `presentRemoteError` を呼ぶテストを置く。
///
/// **実行方法**: `cd App && xcodebuild test -scheme StackNest -destination 'platform=macOS' -derivedDataPath build`
///
/// **検出力は実証済み（G25e）**: 意図的に自己再帰を戻すと `exit=65` / `** TEST FAILED **` /
/// `Restarting after unexpected exit, crash, or test timeout` となる。スタックオーバーフローなので
/// 綺麗な assertion 失敗ではなく**テストプロセスのクラッシュ**として現れる点に注意。
@MainActor
@Suite("RemoteLibraryState のエラー提示")
struct RemoteErrorPresentationTests {
    private func makeState(libraryToken: String?) -> RemoteLibraryState {
        RemoteLibraryState(
            client: RemoteLibraryClient(baseURL: URL(string: "http://127.0.0.1:1/")!, deviceToken: "device"),
            serverID: UUID(), libraryUUID: "LIB-\(UUID().uuidString)",
            libraryName: "テスト", locked: true, libraryToken: libraryToken,
            // G25e: **ディスクキャッシュを注入して実利用領域を汚さない。**
            // 既定（`RemotePageCache.shared`）のままだと、テストを走らせるだけで
            // `~/Library/Application Support/StackNest/RemoteCache/` に blobs / index.sqlite が作られる。
            coverCache: RemoteCoverCache(cache: nil, serverID: nil, libraryUUID: nil))
    }

    /// G25e: 上の注入が効いていること＝テストが実利用のキャッシュ領域に触れないことを固定する。
    /// これが崩れると、テストを走らせるだけで開発者・利用者のキャッシュ DB を作成／更新してしまう。
    @Test("テストは実利用のディスクキャッシュを作らない")
    func doesNotTouchRealDiskCache() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let cacheDir = appSupport.appendingPathComponent("StackNest/RemoteCache", isDirectory: true)
        let existedBefore = FileManager.default.fileExists(atPath: cacheDir.path)

        _ = makeState(libraryToken: "TOKEN")

        // 元から在る環境では「増えないこと」を、無い環境では「作られないこと」を主張する。
        #expect(FileManager.default.fileExists(atPath: cacheDir.path) == existedBefore)
    }

    @Test("★通常のエラーは赤字表示になり、トークンを失効させない（自己再帰の回帰検出）")
    func normalErrorShowsMessageAndKeepsToken() {
        let s = makeState(libraryToken: "TOKEN")
        // 自己再帰が復活していると、この呼び出しがスタックオーバーフローでクラッシュする。
        s.presentRemoteError(.offline)
        #expect(s.errorText != nil)
        #expect(s.libraryToken == "TOKEN")
    }

    @Test("種別ごとに固有の文言が出る（message(for:) を通っていること）")
    func messagesDifferPerError() {
        let s = makeState(libraryToken: "TOKEN")
        s.presentRemoteError(.offline)
        let offlineText = s.errorText
        s.presentRemoteError(.timeout)
        #expect(s.errorText != offlineText)
        #expect(s.libraryToken == "TOKEN")
    }

    @Test("権限不足の 403 ではトークンを捨てない（解錠フォームへ飛ばさない）")
    func plainForbiddenKeepsToken() {
        let s = makeState(libraryToken: "TOKEN")
        s.presentRemoteError(.forbidden)
        #expect(s.libraryToken == "TOKEN")
        #expect(s.errorText != nil)
    }

    @Test("★施錠ゲートの 403 はトークンを捨てて解錠フォームを復帰させる")
    func libraryLockedInvalidatesToken() {
        let s = makeState(libraryToken: "TOKEN")
        s.presentRemoteError(.libraryLocked)
        #expect(s.libraryToken == nil)   // これで isUnlockFormShown が真になる
        #expect(s.locked == true)
        #expect(s.errorText != nil)
    }

    @Test("既にトークンが無ければ失効処理は何もしない")
    func invalidateIsNoOpWithoutToken() {
        let s = makeState(libraryToken: nil)
        s.errorText = nil
        s.presentRemoteError(.libraryLocked)
        #expect(s.libraryToken == nil)
        #expect(s.errorText == nil)      // 余計なエラー表示を出さない
    }
}
