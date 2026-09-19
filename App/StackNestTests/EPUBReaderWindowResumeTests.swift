// SPDX-License-Identifier: MIT
import AppKit
import Testing
import AppCore
import EPUBAdapter
import LibraryStore
@testable import StackNest

@MainActor
@Suite("G54-S3b: EPUB の窓の再開シート")
struct EPUBReaderWindowResumeTests {
    private func freshSettings() -> ViewerSettings {
        let name = "g54s3b-epub-resume-\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: name)!
        ud.removePersistentDomain(forName: name)
        return ViewerSettings(defaults: ud)
    }

    private func make(resume: EPUBLocatorValue?, suppressed: Bool = false)
        -> (EPUBReaderWindowController, FakeEPUBReader, Box) {
        let reader = FakeEPUBReader()
        let box = Box()
        let c = EPUBReaderWindowController(
            book: .g51Fixture(id: 1, title: "t"), reader: reader,
            settings: freshSettings(), resumeLocator: resume,
            suppressResumeDialog: suppressed,
            persist: { box.persisted.append($0) })
        c.bindings = .defaults
        return (c, reader, box)
    }

    final class Box { var persisted: [EPUBLocatorValue] = [] }

    @Test func asksWhenTheSavedPositionIsNotTheBeginning() {
        let (c, _, _) = make(resume: EPUBLocatorValue(spine: 2, progress: 0, cfi: nil, engine: nil))
        #expect(c.shouldAskResume == true)
    }

    @Test func doesNotAskAtTheBeginningOrWithoutAPosition() {
        let (a, _, _) = make(resume: EPUBLocatorValue(spine: 0, progress: 0, cfi: nil, engine: nil))
        #expect(a.shouldAskResume == false)
        let (b, _, _) = make(resume: nil)
        #expect(b.shouldAskResume == false)
    }

    @Test func doesNotAskWhenSuppressed() {
        let (c, _, _) = make(resume: EPUBLocatorValue(spine: 3, progress: 0.5, cfi: nil, engine: nil),
                             suppressed: true)
        #expect(c.shouldAskResume == false)
    }

    @Test func restartingGoesToTheBookStartAndSavesIt() {
        let (c, r, box) = make(resume: EPUBLocatorValue(spine: 3, progress: 0.5, cfi: nil, engine: nil))
        c.restartFromBeginning()
        #expect(r.calls == ["goToBookStart"])
        #expect(box.persisted.count == 1)
        #expect(box.persisted.first?.spine == 0)
        #expect(box.persisted.first?.progress == 0)
    }

    /// 一度出したら、同じ窓では二度と訊かない。
    @Test func onlyAsksOnce() {
        let (c, _, _) = make(resume: EPUBLocatorValue(spine: 1, progress: 0, cfi: nil, engine: nil))
        c.markResumeDialogShown()
        #expect(c.shouldAskResume == false)
    }

    /// レビュー修正 Minor 1: 「最初から」を押す直前にデバウンス中の書き込みが積まれていても、
    /// その後の flush（本来は 0.4 秒後のタイマーだが、ここでは windowWillClose の flush 経路で確認する）が
    /// 先頭位置を古い locator で上書きしない。
    @Test func restartingDropsAPendingDebouncedWrite() {
        let (c, r, box) = make(resume: EPUBLocatorValue(spine: 3, progress: 0.5, cfi: nil, engine: nil))
        // 章の途中まで読んだ位置がデバウンス待ちで pending に積まれている状態を再現する。
        r.onLocatorChange?(EPUBLocatorValue(spine: 5, progress: 0.7, cfi: nil, engine: nil))
        c.restartFromBeginning()
        // flush 経路（窓を閉じるとき）を走らせても、上の pending が生き残って書き戻されないこと。
        c.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(box.persisted.count == 1)
        #expect(box.persisted.first?.spine == 0)
        #expect(box.persisted.first?.progress == 0)
    }
}
