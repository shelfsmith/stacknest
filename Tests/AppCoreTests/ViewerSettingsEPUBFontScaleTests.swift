// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

/// G48-2 smoke fix: EPUB 内蔵リーダーのフォント倍率設定。`ViewerSettingsLoupeTests`
/// （`loupeMagnification`）と同じ作法 — clamp・永続化・キー不在時の既定値。
@Suite("ViewerSettings の EPUB フォント倍率（G48-2 smoke fix）")
@MainActor
struct ViewerSettingsEPUBFontScaleTests {
    private func freshDefaults() -> (UserDefaults, String) {
        let name = "test.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func firstRunUsesTheDefault() {
        let (ud, name) = freshDefaults(); defer { ud.removePersistentDomain(forName: name) }
        #expect(ViewerSettings(defaults: ud).epubFontScale == EPUBFontScale.defaultValue)
    }

    /// 範囲外を代入したら即座に畳まれること。同一値を往復（永続化）で保持できること。
    @Test func assigningOutOfRangeClampsAndValuesSurviveARoundTrip() {
        let (ud, name) = freshDefaults(); defer { ud.removePersistentDomain(forName: name) }
        let s = ViewerSettings(defaults: ud)

        s.epubFontScale = 99
        #expect(s.epubFontScale == EPUBFontScale.range.upperBound)
        s.epubFontScale = 0.1
        #expect(s.epubFontScale == EPUBFontScale.range.lowerBound)

        s.epubFontScale = 1.4
        let reloaded = ViewerSettings(defaults: ud)
        #expect(reloaded.epubFontScale == 1.4)
    }

    /// 保存済みの値が壊れていても（範囲外・別アプリが書いた等）、読み出しで畳む。
    @Test func loadingAStoredOutOfRangeValueClampsIt() {
        let (ud, name) = freshDefaults(); defer { ud.removePersistentDomain(forName: name) }
        ud.set(42.0, forKey: "epubFontScale")
        #expect(ViewerSettings(defaults: ud).epubFontScale == EPUBFontScale.range.upperBound)
    }
}
