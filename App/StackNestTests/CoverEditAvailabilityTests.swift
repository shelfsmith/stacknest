// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import StackNest

/// G54-S4: 「表紙を編集」の可否は分類ではなく**表紙候補を取り出せるか**で決まる。
@MainActor
@Suite("G54-S4: 表紙を編集できる形式")
struct CoverEditAvailabilityTests {
    @Test("候補を取れる形式は押せる", arguments: ["/tmp/a.zip", "/tmp/a.cbz", "/tmp/a.rar", "/tmp/a.7z",
                                                  "/tmp/a.epub", "/tmp/a.pdf"])
    func editable(path: String) {
        #expect(DetailPaneView.canEditCover(path: path) == true)
    }

    @Test("候補を取れない形式は押せない", arguments: ["/tmp/a.mp4", "/tmp/a.mov", "/tmp/a.txt",
                                                      "/tmp/a.md", "/tmp/a.rtf"])
    func notEditable(path: String) {
        #expect(DetailPaneView.canEditCover(path: path) == false)
    }

    // 修正ラウンド2: 旧テストは「パスが無い・空なら押せない」を無条件に固定しており、リモート
    // （サーバが本の場所を秘匿するため path が常に nil）の入口をまるごと塞いでいた。
    // 「場所も拡張子も無ければ押せない」と「場所は無いが拡張子があれば拡張子で判定する」は
    // 別の主張なので分ける。

    @Test("場所も拡張子も無ければ押せない")
    func noPathAndNoExtension() {
        #expect(DetailPaneView.canEditCover(path: nil) == false)
        #expect(DetailPaneView.canEditCover(path: "") == false)
        #expect(DetailPaneView.canEditCover(path: nil, remoteFileExtension: nil) == false)
        #expect(DetailPaneView.canEditCover(path: "", remoteFileExtension: nil) == false)
    }

    @Test("リモート（path なし）で候補を取れる拡張子は押せる", arguments: ["zip", "epub", "pdf", ""])
    func remoteExtensionEditable(ext: String) {
        #expect(DetailPaneView.canEditCover(path: nil, remoteFileExtension: ext) == true)
    }

    @Test("リモート（path なし）で候補を取れない拡張子は押せない", arguments: ["mp4", "txt"])
    func remoteExtensionNotEditable(ext: String) {
        #expect(DetailPaneView.canEditCover(path: nil, remoteFileExtension: ext) == false)
    }

    @Test("ディレクトリは押せる")
    func directoryIsEditable() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("g54s4-dir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(DetailPaneView.canEditCover(path: dir.path) == true)
    }
}
