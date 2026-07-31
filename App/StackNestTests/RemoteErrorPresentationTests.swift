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
/// **⚠️ 現時点でこのファイルはビルドに組み込まれていない。** App ターゲットは SPM パッケージ
/// （C ターゲット `Carchive` を含む）に依存しており、Xcode のユニットテストバンドルを足すと
/// 製品の静的／動的の扱いが食い違ってビルドが壊れる。4 通り試して解決できなかったため、
/// テストターゲットの整備は **G25e** に切り出した。このファイルはそのときに使う準備物。
/// 経緯は `analysis/decisions.md`（2026-07-31）。
@MainActor
@Suite("RemoteLibraryState のエラー提示")
struct RemoteErrorPresentationTests {
    private func makeState(libraryToken: String?) -> RemoteLibraryState {
        RemoteLibraryState(
            client: RemoteLibraryClient(baseURL: URL(string: "http://127.0.0.1:1/")!, deviceToken: "device"),
            serverID: UUID(), libraryUUID: "LIB-\(UUID().uuidString)",
            libraryName: "テスト", locked: true, libraryToken: libraryToken)
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
