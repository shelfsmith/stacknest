// SPDX-License-Identifier: MIT
import AppKit
import EPUBAdapter
import LibraryStore

/// G51: 契約 `EPUBReaderViewing` の記録型ダブル。窓のキー解決・実行を Washi 抜きで検証する。
@MainActor
final class FakeEPUBReader: EPUBReaderViewing {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    var locator: EPUBLocatorValue?
    var onLocatorChange: ((EPUBLocatorValue) -> Void)?
    var onFontScaleChange: ((Double) -> Void)?
    var onKeyEvent: ((NSEvent) -> Bool)?
    var onReachBookEdge: ((Bool) -> Void)?
    var fontScale: Double = 1.0
    var columnMode: EPUBColumnModeValue = .auto
    var globalPageCount: Int?
    var spineItemCount: Int?
    // G54-S3: 初期値はアプリの既定（off / false）と逆にしておく。窓が設定を入れたことをテストで検出するため。
    var pageTurnStyle: PageTurnStyleValue = .slide
    var showsFolio: Bool = true
    var isRightToLeft: Bool = false
    var currentGlobalPageRange: ClosedRange<Int>?
    var onPageCensusChange: (() -> Void)?
    /// G54-S3c: 当てられた配色（窓が倍率と配色をまとめて当てるようになったため、`calls` とは分けて記録する。
    /// `calls` に積むと、キー操作の順序を照合する既存テストが全部ずれる）。
    var themes: [EPUBReaderThemeValue] = []

    /// 呼ばれた順に記録。テストは文字列で照合する。
    var calls: [String] = []

    func go(to locator: EPUBLocatorValue) { calls.append("go(spine:\(locator.spine),progress:\(locator.progress))") }
    func goForward() { calls.append("goForward") }
    func goBackward() { calls.append("goBackward") }
    func setTheme(_ theme: EPUBReaderThemeValue) { themes.append(theme) }
    func tearDown() { calls.append("tearDown") }
    func goToBookStart() { calls.append("goToBookStart") }
    func goToBookEnd() { calls.append("goToBookEnd") }
    func pageLeft() { calls.append("pageLeft") }
    func pageRight() { calls.append("pageRight") }
    func go(toGlobalPage page: Int) { calls.append("go(toGlobalPage:\(page))") }
    func adjustFontScale(by delta: Double) { fontScale += delta; calls.append("adjustFontScale(\(delta))") }
    func resetFontScale() { fontScale = 1.0; calls.append("resetFontScale") }
}

extension BookRow {
    /// G51 テスト用の最小 BookRow（`Tests/AppCoreTests/BookSortTests.swift` の生成例と同じ引数）。
    static func g51Fixture(id: Int, title: String, series: String? = nil, volume: Double? = nil) -> BookRow {
        BookRow(id: id, title: title, author: nil, genre: nil, path: nil,
                dateAdded: Date(timeIntervalSince1970: 0), playDate: nil,
                bookType: 0, fileType: 0, pages: nil, rating: 0, unseen: true,
                keywordA: nil, keywordB: nil, keywordC: nil, neta: nil, memo: nil,
                series: series, volume: volume, coverImageName: nil, coverCropRect: nil,
                pageDirection: nil, contentHash: nil, fileSize: nil, fileMtime: nil)
    }
}
