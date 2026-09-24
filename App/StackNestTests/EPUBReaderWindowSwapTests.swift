// SPDX-License-Identifier: MIT
import AppKit
import Testing
import AppCore
import EPUBAdapter
import LibraryStore
@testable import StackNest

/// キー入力を受けられるビュー（ファーストレスポンダの受け渡しのテスト用）。
private final class FocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// G54-S3c: EPUB の巻送りを同じ窓の中で差し替える（spec §4.1）。
/// 次の巻の解決と reader の用意は所有者、窓は受け取って同期で差し替えるだけ（画像ビューアの performSwap と同じ形）。
@MainActor
@Suite("G54-S3c: EPUB の巻送りを同じ窓で", .serialized)
struct EPUBReaderWindowSwapTests {
    final class Box { var persisted: [EPUBLocatorValue] = [] }
    final class Sheets { var completions: [EPUBReaderWindowController.ResumeSheetCompletion] = [] }
    final class Gate { var open = false }

    private func freshSettings() -> ViewerSettings {
        let name = "g54s3c-epub-swap-\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: name)!
        ud.removePersistentDomain(forName: name)
        return ViewerSettings(defaults: ud)
    }

    private func loc(_ spine: Int, _ progress: Double) -> EPUBLocatorValue {
        EPUBLocatorValue(spine: spine, progress: progress, cfi: nil, engine: nil)
    }

    private func make(settings: ViewerSettings? = nil, resume: EPUBLocatorValue? = nil)
        -> (EPUBReaderWindowController, FakeEPUBReader, Box, Sheets) {
        let reader = FakeEPUBReader()
        let box = Box()
        let c = EPUBReaderWindowController(
            book: .g51Fixture(id: 1, title: "一巻"), reader: reader,
            settings: settings ?? freshSettings(), resumeLocator: resume,
            persist: { box.persisted.append($0) })
        c.bindings = .defaults
        let sheets = Sheets()
        c.resumeSheetPresenter = { _, completion in sheets.completions.append(completion) }
        c.openSibling = { _ in Issue.record("開き直してはいけない") }
        return (c, reader, box, sheets)
    }

    private func prepared(id: Int = 2, title: String = "二巻", resume: EPUBLocatorValue? = nil)
        -> (EPUBReaderWindowController.PreparedBook, FakeEPUBReader, Box) {
        let reader = FakeEPUBReader()
        let box = Box()
        let p = EPUBReaderWindowController.PreparedBook(
            book: .g51Fixture(id: id, title: title), reader: reader, resumeLocator: resume,
            persist: { box.persisted.append($0) })
        return (p, reader, box)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func swapReplacesTheReaderInTheSameWindow() async {
        let (c, old, oldBox, _) = make()
        old.locator = loc(3, 0.5)
        let (next, new, newBox) = prepared()
        var swapped: [Int] = []
        c.onBookSwapped = { swapped.append($0.id) }
        c.resolveSibling = { _, _ in .swapIn(next) }
        let window = c.window
        // 同じ id の窓が他のテストで生きていると AppKit は autosave 名を拒否して "" になるので、前後で比べる。
        let autosaveName = window?.frameAutosaveName
        c.perform(.nextVolume)
        await waitUntil { c.book.id == 2 }
        #expect(c.book.id == 2)
        #expect(swapped == [2])
        #expect(c.window === window)
        #expect(window?.title == "二巻")
        #expect(window?.frameAutosaveName == autosaveName)   // 窓の位置の保存名は付け替えない
        // 古い reader: コールバックが外れ、後始末され、ビューが取り除かれている
        #expect(old.onLocatorChange == nil)
        #expect(old.onKeyEvent == nil)
        #expect(old.onReachBookEdge == nil)
        #expect(old.onPageCensusChange == nil)
        #expect(old.onFontScaleChange == nil)
        #expect(old.calls.contains("tearDown"))
        #expect(old.view.superview == nil)
        // 新しい reader: 同じ容れ物の一番下（ヘルプ・HUD の下）に入り、コールバックが付いている
        #expect(window?.contentView?.subviews.first === new.view)
        #expect(new.onLocatorChange != nil)
        #expect(new.onKeyEvent != nil)
        // 古い本の保存は 1 回だけ（窓は閉じていないので windowWillClose の flush は走っていない）
        #expect(oldBox.persisted.map(\.spine) == [3])
        #expect(newBox.persisted.isEmpty)
        #expect(c.lastHUDNote == "次の巻を開きました：二巻")
    }

    @Test func afterSwapSavesGoToTheNewBookOnly() async {
        let (c, old, oldBox, _) = make()
        old.locator = loc(3, 0.5)
        let (next, new, newBox) = prepared()
        c.resolveSibling = { _, _ in .swapIn(next) }
        c.perform(.nextVolume)
        await waitUntil { c.book.id == 2 }
        old.onLocatorChange?(loc(9, 0.9))     // 外れているので何も起きない
        new.onLocatorChange?(loc(1, 0.25))
        c.window?.close()                      // 閉じるときの flush は新しい本へ
        #expect(oldBox.persisted.count == 1)
        #expect(newBox.persisted.map(\.spine) == [1])
    }

    @Test func swapAppliesFontScaleThemeAndPresentation() async {
        let s = freshSettings()
        s.epubFontScale = 1.4
        s.epubTheme = .dark
        let (c, _, _, _) = make(settings: s)
        let (next, new, _) = prepared()
        c.resolveSibling = { _, _ in .swapIn(next) }
        c.perform(.nextVolume)
        await waitUntil { c.book.id == 2 }
        #expect(new.fontScale == 1.4)
        #expect(new.themes == [.dark])
        #expect(new.pageTurnStyle == .off)     // 偽物の初期値は .slide / true。窓が設定を入れたことを見る
        #expect(new.showsFolio == false)
    }

    @Test func failureKeepsTheCurrentBook() async {
        let (c, old, oldBox, _) = make()
        old.locator = loc(3, 0.5)
        c.resolveSibling = { _, _ in .failed }
        c.perform(.nextVolume)
        await waitUntil { c.lastHUDNote == "次の巻を開けません" }
        #expect(c.lastHUDNote == "次の巻を開けません")
        #expect(c.book.id == 1)
        #expect(!old.calls.contains("tearDown"))
        #expect(old.onLocatorChange != nil)
        #expect(old.view.superview != nil)
        #expect(oldBox.persisted.isEmpty)
    }

    @Test func missingSiblingShowsNote() async {
        let (c, _, _, _) = make()
        c.resolveSibling = { _, _ in .noSibling }
        c.perform(.prevVolume)
        await waitUntil { c.lastHUDNote == "前の巻なし" }
        #expect(c.lastHUDNote == "前の巻なし")
        #expect(c.book.id == 1)
    }

    @Test func nonTextSiblingClosesAndReopensThroughTheOwner() async {
        let (c, old, oldBox, _) = make()
        old.locator = loc(3, 0.5)
        var opened: [Int] = []
        c.openSibling = { opened.append($0.id) }
        c.resolveSibling = { _, _ in .reopen(.g51Fixture(id: 5, title: "zip")) }
        c.perform(.nextVolume)
        await waitUntil { opened == [5] }
        #expect(opened == [5])
        #expect(oldBox.persisted.count == 1)   // close() の中の 1 回だけ
    }

    @Test func asksAfterSwapWhenTheNextBookHasProgress() async {
        let (c, _, _, sheets) = make()
        let (next, _, _) = prepared(resume: loc(2, 0))
        c.resolveSibling = { _, _ in .swapIn(next) }
        c.perform(.nextVolume)
        await waitUntil { c.book.id == 2 }
        #expect(sheets.completions.count == 1)
    }

    @Test func doesNotAskAfterSwapAtTheBeginningOrWithoutAPosition() async {
        for resume in [nil, loc(0, 0)] as [EPUBLocatorValue?] {
            let (c, _, _, sheets) = make()
            let (next, _, _) = prepared(resume: resume)
            c.resolveSibling = { _, _ in .swapIn(next) }
            c.perform(.nextVolume)
            await waitUntil { c.book.id == 2 }
            #expect(sheets.completions.isEmpty)
        }
    }

    /// 古い本のシートが開いたまま差し替わっても、その「最初から」は新しい本に効かない。
    @Test func oldSheetResultDoesNotRestartTheNewBook() async {
        let (c, old, _, sheets) = make(resume: loc(3, 0.5))
        c.showResumeDialogIfNeeded()
        #expect(sheets.completions.count == 1)
        let (next, new, newBox) = prepared()
        c.resolveSibling = { _, _ in .swapIn(next) }
        c.perform(.nextVolume)
        await waitUntil { c.book.id == 2 }
        sheets.completions[0](.alertSecondButtonReturn)
        #expect(!new.calls.contains("goToBookStart"))
        #expect(!old.calls.contains("goToBookStart"))
        #expect(newBox.persisted.isEmpty)
    }

    /// G54-S3cd 最終レビュー Minor #2: 2 回続けて差し替えても、保存先・onBookSwapped の順序・
    /// 古い reader それぞれの後始末が正しく積み重なることを確かめる。
    @Test func twoBackToBackSwapsLandOnTheThirdBook() async {
        let (c, one, oneBox, _) = make()
        one.locator = loc(3, 0.5)
        let (secondPrepared, two, twoBox) = prepared(id: 2, title: "二巻")
        let (thirdPrepared, three, threeBox) = prepared(id: 3, title: "三巻")
        var swapped: [Int] = []
        c.onBookSwapped = { swapped.append($0.id) }
        var call = 0
        c.resolveSibling = { _, _ in
            call += 1
            return .swapIn(call == 1 ? secondPrepared : thirdPrepared)
        }
        c.perform(.nextVolume)
        await waitUntil { c.book.id == 2 }
        two.locator = loc(5, 0.2)
        c.perform(.nextVolume)
        await waitUntil { c.book.id == 3 }
        #expect(c.book.id == 3)
        #expect(swapped == [2, 3])
        // 1 冊目・2 冊目の reader はそれぞれちょうど 1 回だけ tearDown される。
        #expect(one.calls.filter { $0 == "tearDown" }.count == 1)
        #expect(two.calls.filter { $0 == "tearDown" }.count == 1)
        #expect(!three.calls.contains("tearDown"))
        // 保存先は常に「差し替え直前の本」だけ（1 冊目→2 冊目の差し替えで 1 冊目を 1 回、
        // 2 冊目→3 冊目の差し替えで 2 冊目を 1 回。3 冊目はまだ保存していない）。
        #expect(oneBox.persisted.map(\.spine) == [3])
        #expect(twoBox.persisted.map(\.spine) == [5])
        #expect(threeBox.persisted.isEmpty)
        // 3 冊目の保存先は、窓を閉じたときの flush で確かめる（他のテストと同じ手筋）。
        three.onLocatorChange?(loc(2, 0.75))
        c.window?.close()
        #expect(threeBox.persisted.map(\.spine) == [2])
    }

    @Test func closingWhileResolvingDiscardsTheResult() async {
        let (c, _, _, _) = make()
        let (next, new, newBox) = prepared()
        let gate = Gate()
        c.resolveSibling = { _, _ in
            while !gate.open { try? await Task.sleep(for: .milliseconds(5)) }
            return .swapIn(next)
        }
        c.perform(.nextVolume)
        c.window?.close()
        gate.open = true
        await waitUntil { new.calls.contains("tearDown") }
        #expect(new.calls.contains("tearDown"))
        #expect(c.book.id == 1)
        #expect(new.view.superview == nil)
        #expect(newBox.persisted.isEmpty)
    }

    @Test func repeatedPressesResolveOnlyOnce() async {
        let (c, _, _, _) = make()
        let gate = Gate()
        var count = 0
        c.resolveSibling = { _, _ in
            count += 1
            while !gate.open { try? await Task.sleep(for: .milliseconds(5)) }
            return .noSibling
        }
        c.perform(.nextVolume)
        c.perform(.nextVolume)
        c.perform(.nextVolume)
        gate.open = true
        await waitUntil { c.lastHUDNote == "次の巻なし" }
        #expect(count == 1)
    }

    /// リモートのダウンロードなど解決が長引くときは、今の本を出したまま「読み込み中…」を出す。
    @Test func slowResolutionShowsLoadingNoteWhileKeepingTheBook() async {
        let (c, old, _, _) = make()
        c.siblingLoadingNoteDelay = .milliseconds(1)
        let (next, _, _) = prepared()
        let gate = Gate()
        c.resolveSibling = { _, _ in
            while !gate.open { try? await Task.sleep(for: .milliseconds(5)) }
            return .swapIn(next)
        }
        c.perform(.nextVolume)
        await waitUntil { c.lastHUDNote == "次の巻を読み込み中…" }
        #expect(c.lastHUDNote == "次の巻を読み込み中…")
        #expect(c.book.id == 1)
        #expect(old.view.superview != nil)
        gate.open = true
        await waitUntil { c.book.id == 2 }
        #expect(c.lastHUDNote == "次の巻を開きました：二巻")
    }

    @Test func oldReaderIsReleased() async {
        weak var weakOld: FakeEPUBReader?
        let c: EPUBReaderWindowController
        do {
            let old = FakeEPUBReader()
            weakOld = old
            c = EPUBReaderWindowController(book: .g51Fixture(id: 1, title: "一巻"), reader: old,
                                           settings: freshSettings(), persist: { _ in })
        }
        c.resumeSheetPresenter = { _, _ in }
        c.openSibling = { _ in }   // 未設定だと loadSibling が「次の巻なし」で止まる
        let (next, _, _) = prepared()
        c.resolveSibling = { _, _ in .swapIn(next) }
        c.perform(.nextVolume)
        await waitUntil { c.book.id == 2 }
        await waitUntil { weakOld == nil }
        #expect(weakOld == nil)
    }

    /// 古い WebView ごとファーストレスポンダが消えるので、差し替え後は新しい本の中のビューへ渡す。
    @Test func swapHandsFocusToTheNewReader() async {
        let (c, _, _, _) = make()
        let (next, new, _) = prepared()
        let leaf = FocusableView()
        new.view.addSubview(leaf)
        c.resolveSibling = { _, _ in .swapIn(next) }
        c.perform(.nextVolume)
        await waitUntil { c.book.id == 2 }
        #expect(c.window?.firstResponder === leaf)
    }

    @Test func firstResponderCandidateFindsTheFocusableDescendant() {
        let root = NSView()
        let middle = NSView()
        let leaf = FocusableView()
        root.addSubview(middle)
        middle.addSubview(leaf)
        #expect(EPUBReaderWindowController.firstResponderCandidate(in: root) === leaf)
        #expect(EPUBReaderWindowController.firstResponderCandidate(in: NSView()) == nil)
    }
}
