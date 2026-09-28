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
}
