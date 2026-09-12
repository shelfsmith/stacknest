// SPDX-License-Identifier: MIT
import AppKit
import Testing
@testable import StackNest

/// G54-S1（Codex 指摘）: 設定窓の高さ制約は **content 高さ**で計算し、
/// `NSWindow.minSize` / `maxSize` へ渡すときだけ **frame 座標**へ写す。
/// 両者を混ぜると `setContentSize` が maxSize に引き戻され、viewport が
/// タイトルバー 1 本分低くなって余計なスクロールが出る。
@MainActor
@Suite("G54-S1: 設定窓の高さ制約の座標系")
struct SettingsWindowSizingTests {
    private func makeWindow(contentHeight: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: contentHeight),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered,
                              defer: false)
        return window
    }

    @Test("chromeHeight は frame と content の差を返す")
    func chromeHeightIsTheDifference() {
        let window = makeWindow(contentHeight: 400)
        let chrome = SettingsWindowFixedSize.chromeHeight(of: window)
        #expect(chrome > 0, "タイトルバーのある窓なので chrome は正")
        let contentHeight = window.contentView?.frame.height ?? 0
        #expect(abs(window.frame.height - contentHeight - chrome) < 0.5)
    }

    @Test("frameSizeLimits は content 高さに chrome を足して frame 座標へ写す")
    func limitsAddChrome() {
        let limits = SettingsWindowFixedSize.frameSizeLimits(contentMin: 240, contentMax: 700, width: 600, chrome: 28)
        #expect(limits.min.height == 268)
        #expect(limits.max.height == 728)
        #expect(limits.min.width == 600)
        #expect(limits.max.width == 600)
    }

    @Test("上限が下限を下回るときは下限で底上げする")
    func limitsNeverInvert() {
        let limits = SettingsWindowFixedSize.frameSizeLimits(contentMin: 240, contentMax: 100, width: 600, chrome: 28)
        #expect(limits.max.height >= limits.min.height)
        #expect(limits.max.height == 268)
    }

    /// 回帰の本体。`setContentSize` は実測では `maxSize` に引き戻されないので（Codex が述べた
    /// 「viewport が chrome 分低くなる」症状はここでは起きない）、効くのは**ユーザーのドラッグ**の方。
    /// `windowWillResize` は content 座標で `maxHeight` まで許すのに、`maxSize` が content 高さのままだと
    /// AppKit 側の枠の上限がそれより chrome 分きつくなり、**最後の chrome 分が引き出せない**。
    /// 2 つの上限が同じ content 高さを指すこと（＝座標系が揃っていること）を見る。
    @Test("枠の上限とドラッグの上限が同じ content 高さを指す")
    func frameMaximumAgreesWithDragMaximum() {
        let allowedContentHeight: CGFloat = 520
        let window = makeWindow(contentHeight: 300)
        let chrome = SettingsWindowFixedSize.chromeHeight(of: window)
        #expect(chrome > 0)

        let limits = SettingsWindowFixedSize.frameSizeLimits(contentMin: 240, contentMax: allowedContentHeight,
                                                            width: 600, chrome: chrome)
        window.minSize = limits.min
        window.maxSize = limits.max

        let delegate = SettingsWindowFixedSize.ResizeDelegate(fixedWidth: 600, minHeight: 240)
        delegate.maxHeight = allowedContentHeight
        let huge = NSSize(width: 600, height: 5000)
        let dragged = delegate.windowWillResize(window, to: huge)

        #expect(abs(dragged.height - window.maxSize.height) < 0.5,
                "ドラッグの上限（content 座標）と枠の上限（frame 座標）が同じ高さを指す")
        #expect(window.maxSize.height - chrome >= allowedContentHeight - 0.5,
                "枠の上限は許した content 高さを収められる")

        // 修正前の形（content 高さをそのまま maxSize に入れる）は chrome 分きつい。
        let oldMaxFrameHeight = allowedContentHeight
        #expect(oldMaxFrameHeight - chrome < allowedContentHeight,
                "content 高さのまま入れると、引き出せる content が chrome 分足りない")
    }
}
