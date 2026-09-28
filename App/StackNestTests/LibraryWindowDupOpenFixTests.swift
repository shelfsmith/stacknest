// SPDX-License-Identifier: MIT
import Testing
import AppKit
@testable import StackNest

/// dup-window fix (2026-09-29) の純関数テスト。
///
/// バグの実体は2つ:
/// 1. 庫 `WindowGroup` の `.handlesExternalEvents(matching:)` が `Set(["library"])` を
///    渡しており、SwiftUI はこれを URL 文字列の**部分一致**として扱うため、パスに
///    "library" を含む `.stacknest`（例: `…/g48-epub-library/EPUBTest.stacknest`）を
///    Finder ドラッグ&ドロップ／ダブルクリック／`open` で開くと、正規の
///    AppDelegate → URLOpener → openWindow(value:) 経路に加えて SwiftUI 自身が
///    もう1つ同じ WindowGroup のウィンドウを生成していた。
/// 2. 重複ウィンドウ側は登録に失敗して `dismiss()` を呼ぶが、この WindowGroup の
///    `dismiss()` は必ずしも窓を閉じず、スピナーを表示したまま残っていた。
///
/// ここでは実 `NSWindow`/`WindowGroup` を作る App テストの制約（`IntegrityWindowLogicTests`
/// 冒頭コメント参照）に合わせ、「どちらを選ぶか」の純粋な判定・定数だけを検証する。
@MainActor
@Suite("LibraryWindow dup-open fix (2026-09-29)")
struct LibraryWindowDupOpenFixTests {
    // FullScreenEntryDriverTests と同じ「テスト専用オフスクリーン窓」パターン。
    // autosave 名なし・一度も画面に出さない・ユーザーの環境（prefs・ウィンドウ配置）には触れない。
    private func makeTestWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    // MARK: - handlesExternalEvents の一致集合

    @Test("庫ウィンドウの外部イベント一致集合は空である（URL スキーム未登録・部分一致による重複生成を防ぐ）")
    func libraryWindowExternalEventMatchersIsEmpty() {
        #expect(StackNestApp.libraryWindowExternalEventMatchers.isEmpty)
    }

    // MARK: - LibraryWindowCloseLogic

    @Test("hostWindow を捕捉済みなら直接 close() する側を選ぶ")
    func choosesDirectCloseWhenHostWindowCaptured() {
        let window = makeTestWindow()
        #expect(LibraryWindowCloseLogic.shouldCloseHostWindowDirectly(hostWindow: window) == true)
    }

    @Test("hostWindow が nil なら dismiss() へフォールバックする側を選ぶ")
    func fallsBackToDismissWhenHostWindowIsNil() {
        #expect(LibraryWindowCloseLogic.shouldCloseHostWindowDirectly(hostWindow: nil) == false)
    }

    // MARK: - shouldDetachBundleURLBeforeClose（Critical regression fix, 2026-09-29 follow-up）
    //
    // 背景: `hostWindow.close()` は `NSWindow.willCloseNotification` → `handleWindowWillClose` を
    // 確実に発火させる（`dismiss()` と違い、これが今回の主眼）。`handleWindowWillClose` は
    // `w.stacknestBundleURL` が非 nil なら、同じ path を持つ**全ての** `AppState.activeInstances`
    // を再施錠し（`markUnlocked(hash: nil)`）、`UserDefaultsKeys.removeOpenLibrary` も呼ぶ。
    // 一度も庫を開けていない窓（重複登録で弾かれた窓・ロック競合キャンセルの窓）がこれをやると、
    // **同じ path を本当に開いている別の窓**を巻き込んで誤って再施錠・open-library 除去してしまう。

    @Test("庫を開けていない窓（openedBundle: false）は close 前に stacknestBundleURL を外すべき")
    func detachesWhenBundleWasNeverOpened() {
        #expect(LibraryWindowCloseLogic.shouldDetachBundleURLBeforeClose(openedBundle: false) == true)
    }

    @Test("庫を開けていた窓（openedBundle: true）は stacknestBundleURL をそのまま残してよい")
    func doesNotDetachWhenBundleWasOpened() {
        #expect(LibraryWindowCloseLogic.shouldDetachBundleURLBeforeClose(openedBundle: true) == false)
    }

    /// `closeThisWindow(openedBundle:)` 自体は実 `NSWindow`/`dismiss()` に依存するため
    /// App テストで直接呼べないが、その中身（判定 → `stacknestBundleURL` を外す）は
    /// 実 `NSWindow` の associated object（`stacknestBundleURL`）に対してここで再現できる。
    /// これにより「別の本物の窓を誤って再施錠する」不具合の再発を、実際に効く配線の形で縛る。
    @Test("openedBundle: false の決定に従うと、実際に stacknestBundleURL が nil になる（他の窓を巻き込まない）")
    func detachDecisionActuallyClearsAssociatedBundleURL() {
        let window = makeTestWindow()
        window.stacknestBundleURL = URL(fileURLWithPath: "/tmp/dup-window-regression/Test.stacknest")
        if LibraryWindowCloseLogic.shouldDetachBundleURLBeforeClose(openedBundle: false) {
            window.stacknestBundleURL = nil
        }
        #expect(window.stacknestBundleURL == nil, "detach しないと handleWindowWillClose が他の本物の窓を再施錠しうる")
    }

    @Test("openedBundle: true の決定に従うと、stacknestBundleURL は保持される（自分の解錠状態を正しく落とす）")
    func openedBundleDecisionKeepsAssociatedBundleURL() {
        let window = makeTestWindow()
        let url = URL(fileURLWithPath: "/tmp/dup-window-regression/Test.stacknest")
        window.stacknestBundleURL = url
        if LibraryWindowCloseLogic.shouldDetachBundleURLBeforeClose(openedBundle: true) {
            window.stacknestBundleURL = nil
        }
        #expect(window.stacknestBundleURL == url)
    }
}
