// SPDX-License-Identifier: MIT
import AppKit
import Testing
import AppCore
import EPUBAdapter
import LibraryStore
@testable import StackNest

@MainActor
@Suite("G54-S3: EPUB 窓の演出・ノンブル・進捗")
struct EPUBReaderWindowPresentationTests {
    private func freshSettings() -> ViewerSettings {
        let name = "g54s3-epub-window-\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: name)!
        ud.removePersistentDomain(forName: name)
        return ViewerSettings(defaults: ud)
    }

    private func make(settings: ViewerSettings) -> (EPUBReaderWindowController, FakeEPUBReader) {
        let reader = FakeEPUBReader()
        let c = EPUBReaderWindowController(book: .g51Fixture(id: EPUBTestWindowID.fresh(), title: "t"), reader: reader,
                                           settings: settings, persist: { _ in })
        c.bindings = .defaults
        return (c, reader)
    }

    @Test func initAppliesSettingsToReader() {
        let (c, r) = make(settings: freshSettings())   // 既定 off / false。偽物の初期値は slide / true
        defer { EPUBTestWindowID.clearFrame(c.book.id) }
        #expect(r.pageTurnStyle == .off)
        #expect(r.showsFolio == false)
    }

    /// G54-S3c: 文字倍率と配色は窓が当てる（以前は所有者 3 か所が同じことを書いていた）。
    /// 倍率の変更は設定へ書き戻す。
    @Test func initAppliesFontScaleAndThemeFromSettings() {
        let s = freshSettings()
        s.epubFontScale = 1.4
        s.epubTheme = .dark
        let (c, r) = make(settings: s)
        defer { EPUBTestWindowID.clearFrame(c.book.id) }
        #expect(r.fontScale == 1.4)
        #expect(r.themes == [.dark])
        r.onFontScaleChange?(1.7)
        #expect(s.epubFontScale == 1.7)
        withExtendedLifetime(c) {}
    }

    @Test func settingsChangeReachesOpenWindow() {
        let s = freshSettings()
        let (c, r) = make(settings: s)
        defer { EPUBTestWindowID.clearFrame(c.book.id) }
        s.pageTurnStyle = .fade
        #expect(r.pageTurnStyle == .fade)
        s.showsEPUBFolio = true
        #expect(r.showsFolio == true)
        withExtendedLifetime(c) {}
    }

    @Test func progressShowsMeasuringUntilCensusThenPages() {
        let (c, r) = make(settings: freshSettings())
        defer { EPUBTestWindowID.clearFrame(c.book.id) }
        r.spineItemCount = 4
        let loc = EPUBLocatorValue(spine: 1, progress: 0.5, cfi: nil, engine: nil)
        r.locator = loc
        r.onLocatorChange?(loc)
        #expect(c.progressDisplay == EPUBProgressDisplay(text: "計測中…", fraction: 0.375))

        r.globalPageCount = 340
        r.currentGlobalPageRange = 11...12
        r.onPageCensusChange?()
        #expect(c.progressDisplay.text == "12–13 / 340")
    }

    @Test func percentJumpWithoutCensusShowsNote() {
        let (c, r) = make(settings: freshSettings())
        defer { EPUBTestWindowID.clearFrame(c.book.id) }
        r.spineItemCount = 10
        c.perform(.jumpToPercent50)
        #expect(r.calls == ["go(spine:5,progress:0.0)"])
        #expect(c.lastHUDNote == "計測中のため章単位で移動")
    }

    @Test func percentJumpWithCensusHasNoNote() {
        let (c, r) = make(settings: freshSettings())
        defer { EPUBTestWindowID.clearFrame(c.book.id) }
        r.globalPageCount = 100
        c.perform(.jumpToPercent50)
        #expect(r.calls == ["go(toGlobalPage:50)"])
        #expect(c.lastHUDNote == nil)
    }
}
