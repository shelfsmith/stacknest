// SPDX-License-Identifier: MIT
import Testing
import Foundation
import StackroomFormat
@testable import AppCore

@Suite("改名の計画")
struct BookRenamePlannerTests {
    private func book(_ id: Int, path: String?, title: String = "本",
                      series: String? = nil, volume: Double? = nil) -> BookRecord {
        BookRecord(id: id, title: title, path: path, dateAdded: Date(),
                   series: series, volume: volume)
    }

    private func plan(_ books: [BookRecord], raw: String = "@title",
                      widths: [String: Int] = [:],
                      exists: @escaping (String) -> Bool = { _ in false }) throws -> [RenamePlanRow] {
        BookRenamePlanner.plan(books: books, format: try FilenameFormat(raw: raw),
                               bookTypeLabels: [:], volumeWidths: widths, fileExists: exists)
    }

    @Test("path が無ければ noPath（他の判定より先）")
    func noPath() throws {
        let rows = try plan([book(1, path: nil), book(2, path: "")])
        #expect(rows.map(\.status) == [.noPath, .noPath])
    }

    @Test("普通に改名できる")
    func ok() throws {
        let rows = try plan([book(1, path: "/x/old.zip", title: "新しい名前")])
        #expect(rows[0].status == .ok)
        #expect(rows[0].newPath == "/x/新しい名前.zip")
        #expect(rows[0].newName == "新しい名前.zip")
    }

    @Test("既に同じ名前なら unchanged")
    func unchanged() throws {
        let rows = try plan([book(1, path: "/x/本.zip")])
        #expect(rows[0].status == .unchanged)
    }

    @Test("同名のファイルが実在すれば conflictExisting")
    func conflictExisting() throws {
        let rows = try plan([book(1, path: "/x/old.zip", title: "先客")],
                            exists: { $0 == "/x/先客.zip" })
        #expect(rows[0].status == .conflictExisting)
    }

    @Test("★ 大文字小文字だけの違いは衝突ではない")
    func caseOnlyIsNotConflict() throws {
        // macOS 既定のファイルシステムは大文字小文字を区別しないので
        // fileExists は true を返す ―― それは自分自身であって先客ではない。
        let rows = try plan([book(1, path: "/x/abc.zip", title: "ABC")],
                            exists: { _ in true })
        #expect(rows[0].status == .ok)
        #expect(rows[0].newPath == "/x/ABC.zip")
    }

    @Test("同じ回の中でぶつかったら後の行が conflictInBatch")
    func conflictInBatch() throws {
        let rows = try plan([book(1, path: "/x/a.zip", title: "同じ"),
                             book(2, path: "/x/b.zip", title: "同じ")])
        #expect(rows[0].status == .ok)
        #expect(rows[1].status == .conflictInBatch)
    }

    @Test("大文字小文字だけ違う新名も同じ回の中では衝突")
    func conflictInBatchCaseInsensitive() throws {
        let rows = try plan([book(1, path: "/x/a.zip", title: "Name"),
                             book(2, path: "/x/b.zip", title: "NAME")])
        #expect(rows[1].status == .conflictInBatch)
    }

    @Test("★ 全トークンが空なら emptyName（.zip だけのファイルを作らない）")
    func emptyName() throws {
        let rows = try plan([book(1, path: "/x/a.zip")], raw: "@series")
        #expect(rows[0].status == .emptyName)
        #expect(rows[0].newPath == "")
    }

    @Test("先頭のドットは落とす。落として空なら emptyName")
    func leadingDot() throws {
        let rows = try plan([book(1, path: "/x/a.zip", title: ".hidden")])
        #expect(rows[0].status == .ok)
        #expect(rows[0].newName == "hidden.zip")
        let only = try plan([book(1, path: "/x/a.zip", title: "..")])
        #expect(only[0].status == .emptyName)
    }

    @Test("255 バイトを超えたら tooLong（日本語は 1 文字 3 バイト）")
    func tooLong() throws {
        let long = String(repeating: "あ", count: 85)   // 255 バイト + ".zip" で超える
        let rows = try plan([book(1, path: "/x/a.zip", title: long)])
        #expect(rows[0].status == .tooLong)
    }

    @Test("巻数の桁はシリーズごとの指定に従う")
    func volumeWidthPerSeries() throws {
        let rows = try plan([book(1, path: "/x/a.zip", series: "長い", volume: 7),
                             book(2, path: "/x/b.zip", series: "短い", volume: 7)],
                            raw: "@series v@volume",
                            widths: ["長い": 3, "短い": 2])
        #expect(rows[0].newName == "長い v007.zip")
        #expect(rows[1].newName == "短い v07.zip")
    }

    @Test("桁の指定が無いシリーズは 2 桁")
    func volumeWidthDefault() throws {
        let rows = try plan([book(1, path: "/x/a.zip", series: "未知", volume: 7)],
                            raw: "@series v@volume")
        #expect(rows[0].newName == "未知 v07.zip")
    }

    @Test("★ apply が false なら実行対象は空")
    func nothingToApplyWhenNotApplying() throws {
        let rows = try plan([book(1, path: "/x/a.zip", title: "新")])
        #expect(rows[0].status == .ok)
        #expect(BookRenamePlanner.rowsToApply(plan: rows, apply: false).isEmpty)
        #expect(BookRenamePlanner.rowsToApply(plan: rows, apply: true).count == 1)
    }

    @Test("拡張子が無いファイルでも壊れない")
    func noExtension() throws {
        let rows = try plan([book(1, path: "/x/old", title: "新")])
        #expect(rows[0].newName == "新")
        #expect(rows[0].newPath == "/x/新")
    }
}
