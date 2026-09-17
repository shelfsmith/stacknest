// Tests/WashiEPUBAdapterTests/WashiKeyRoutingTests.swift
// SPDX-License-Identifier: MIT
import AppKit
import Testing
import Washi
@testable import WashiEPUBAdapter

/// G51: キーの通り道（spec §3.1）。JS 既定ナビは止め、native monitor で受けた NSEvent を窓へ渡し、
/// 扱わなかったキーは responder チェーンへ返す。
@MainActor
@Suite("G51: Washi 実装のキー経路")
struct WashiKeyRoutingTests {
    private func keyEvent(keyCode: UInt16, chars: String = " ") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: 0, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)!
    }

    @Test func jsNavigationIsOffAndNativeForwardingIsOn() {
        let host = WashiReaderHost()
        #expect(host.reader.settings.handlesKeyboardNavigation == false)
        #expect(host.reader.settings.forwardsKeyEventsNatively == true)
    }

    @Test func nativeKeyGoesToWindowAndConsumptionIsHonored() {
        let host = WashiReaderHost()
        var seen: [UInt16] = []
        host.onKeyEvent = { e in seen.append(e.keyCode); return e.keyCode == 49 }
        #expect(host.readerView(host.reader, didReceiveNativeKey: keyEvent(keyCode: 49)) == true)   // Space: 消費
        #expect(host.readerView(host.reader, didReceiveNativeKey: keyEvent(keyCode: 27, chars: "-")) == false) // 未処理: 流す
        #expect(seen == [49, 27])
    }

    @Test func withoutWindowHandlerNothingIsConsumed() {
        let host = WashiReaderHost()
        host.onKeyEvent = nil
        #expect(host.readerView(host.reader, didReceiveNativeKey: keyEvent(keyCode: 49)) == false)
    }

    @Test func columnModeMapsBothWays() {
        let host = WashiReaderHost()
        host.columnMode = .double
        #expect(host.reader.settings.columnMode == .double)
        #expect(host.columnMode == .double)
        host.columnMode = .single
        #expect(host.reader.settings.columnMode == .single)
        host.columnMode = .auto
        #expect(host.columnMode == .auto)
    }

    @Test func fontScaleResetNotifiesOnlyWhenChanged() {
        let host = WashiReaderHost()
        var notified: [Double] = []
        host.onFontScaleChange = { notified.append($0) }
        host.fontScale = 1.4
        host.resetFontScale()
        #expect(host.fontScale == 1.0)
        host.resetFontScale()          // 既に 1.0: 通知しない
        #expect(notified == [1.0])
    }

    @Test func censusAccessorsAreNilBeforeLoad() {
        let host = WashiReaderHost()
        #expect(host.globalPageCount == nil)
        #expect(host.currentGlobalPageRange == nil)
        #expect(host.spineItemCount == nil)
        host.go(toGlobalPage: 3)       // 落ちない・何もしない
        host.goToBookStart()           // publication 無し: 落ちない
        host.goToBookEnd()
    }
}
