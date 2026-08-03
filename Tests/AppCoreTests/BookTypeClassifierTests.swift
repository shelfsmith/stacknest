// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("BookTypeClassifier")
struct BookTypeClassifierTests {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @Test func videoMapsTo5() {
        #expect(BookTypeClassifier.autoClassify(url: url("/x/a.mp4"), pageCount: 0, thickThreshold: 20) == 5)
        #expect(BookTypeClassifier.autoClassify(url: url("/x/a.mov"), pageCount: 999, thickThreshold: 20) == 5)
    }
    @Test func textMapsTo4() {
        #expect(BookTypeClassifier.autoClassify(url: url("/x/a.pdf"), pageCount: 0, thickThreshold: 20) == 4)
        #expect(BookTypeClassifier.autoClassify(url: url("/x/a.txt"), pageCount: 0, thickThreshold: 20) == 4)
        #expect(BookTypeClassifier.autoClassify(url: url("/x/a.epub"), pageCount: 50, thickThreshold: 20) == 4)
    }
    @Test func folderMapsTo3() throws {
        // 実フォルダで test するため一時ディレクトリを作る
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("folder-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(BookTypeClassifier.autoClassify(url: tmp, pageCount: 0, thickThreshold: 20) == 3)
    }
    @Test func imageMapsTo3() {
        #expect(BookTypeClassifier.autoClassify(url: url("/x/a.jpg"), pageCount: 0, thickThreshold: 20) == 3)
        #expect(BookTypeClassifier.autoClassify(url: url("/x/a.png"), pageCount: 0, thickThreshold: 20) == 3)
    }
    @Test func archiveBelowThresholdMapsTo1() {
        #expect(BookTypeClassifier.autoClassify(url: url("/x/a.zip"), pageCount: 19, thickThreshold: 20) == 1)
        #expect(BookTypeClassifier.autoClassify(url: url("/x/a.zip"), pageCount: 0, thickThreshold: 20) == 1)
    }
    @Test func archiveAtThresholdMapsTo0() {
        #expect(BookTypeClassifier.autoClassify(url: url("/x/a.zip"), pageCount: 20, thickThreshold: 20) == 0)
        #expect(BookTypeClassifier.autoClassify(url: url("/x/a.zip"), pageCount: 999, thickThreshold: 20) == 0)
    }
    @Test func customThresholdRespected() {
        #expect(BookTypeClassifier.autoClassify(url: url("/x/a.zip"), pageCount: 30, thickThreshold: 50) == 1)
        #expect(BookTypeClassifier.autoClassify(url: url("/x/a.zip"), pageCount: 50, thickThreshold: 50) == 0)
    }

    /// G26 Codex Minor #2: ページ数が信用できない（打ち切り読み）とき、archive は閾値判定を
    /// **行わず** 自動分類 OFF 時と同じ既定値 0 を返す。打ち切りの 2 ページで「薄い本」と決めると
    /// その分類が永続化され、ファイルを直しても見直されない。
    @Test func archiveWithUnknownPageCountFallsBackToTheDefaultInsteadOfThin() {
        #expect(BookTypeClassifier.autoClassify(url: url("/x/a.zip"), pageCount: nil, thickThreshold: 50) == 0)
    }

    /// ページ数に依存しない分類は pageCount が nil でも従来どおり働く。
    @Test func pageCountIndependentCategoriesAreUnaffectedByUnknownPageCount() {
        #expect(BookTypeClassifier.autoClassify(url: url("/x/a.mp4"), pageCount: nil, thickThreshold: 20) == 5)
        #expect(BookTypeClassifier.autoClassify(url: url("/x/a.txt"), pageCount: nil, thickThreshold: 20) == 4)
        #expect(BookTypeClassifier.autoClassify(url: url("/x/a.jpg"), pageCount: nil, thickThreshold: 20) == 3)
    }
}
