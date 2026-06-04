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
}
