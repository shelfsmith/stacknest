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
/// **検出力は実証済み（G25e・巻き戻しを再現して確認）**:
/// - 自己再帰を戻すと `exit=65` / `** TEST FAILED **` /
///   `Restarting after unexpected exit, crash, or test timeout`。スタックオーバーフローなので
///   綺麗な assertion 失敗ではなく**テストプロセスのクラッシュ**として現れる点に注意。
/// - 表紙キャッシュの注入を無視する形に戻すと、`s.coverCache === injected` が失敗する。
///
/// **テストを足すときは「わざと壊して落ちること」まで確認すること。** 通ることは
/// 「テストが動く」証拠にすぎず、「目的の欠陥を捕まえる」証拠ではない
/// （G25e では、実パスの有無を観察する初版が**通るのに検出力ゼロ**だった）。
@MainActor
@Suite("RemoteLibraryState のエラー提示")
struct RemoteErrorPresentationTests {
    /// G25e: **ディスクを持たない表紙キャッシュ**（L2 を通さず NSCache のみ）。
    /// 既定の `RemotePageCache.shared` のままだと、テストを走らせるだけで
    /// `~/Library/Application Support/StackNest/RemoteCache/` に blobs / index.sqlite が作られる。
    private func makeMemoryOnlyCache() -> RemoteCoverCache {
        RemoteCoverCache(cache: nil, serverID: nil, libraryUUID: nil)
    }

    private func makeState(libraryToken: String?,
                           coverCache: RemoteCoverCache? = nil) -> RemoteLibraryState {
        RemoteLibraryState(
            client: RemoteLibraryClient(baseURL: URL(string: "http://127.0.0.1:1/")!, deviceToken: "device"),
            serverID: UUID(), libraryUUID: "LIB-\(UUID().uuidString)",
            libraryName: "テスト", locked: true, libraryToken: libraryToken,
            coverCache: coverCache ?? makeMemoryOnlyCache())
    }

    /// G25e: **注入した表紙キャッシュがそのまま使われる**ことを固定する。
    ///
    /// これが崩れると `RemotePageCache.shared` が使われ、テストを走らせるだけで
    /// 開発者・利用者の `~/Library/Application Support/StackNest/RemoteCache/` を作成／更新してしまう。
    ///
    /// **実パス（ディレクトリの有無）を観察する形は採らない** — 既にキャッシュがある環境や
    /// 並列実行では巻き戻しが起きても通ってしまい、検出力が無いため（Codex レビュー指摘）。
    /// 配線そのものを見れば、引数を消す巻き戻しはコンパイルが落ち、
    /// 引数を残して無視する巻き戻しはこの identity 検証が落ちる。
    @Test("注入した表紙キャッシュがそのまま使われる（実利用領域を汚さない）")
    func usesTheInjectedCoverCache() {
        let injected = makeMemoryOnlyCache()
        let s = makeState(libraryToken: "TOKEN", coverCache: injected)
        #expect(s.coverCache === injected)
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
