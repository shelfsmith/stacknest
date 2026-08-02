// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

struct BookContentDamageNoteTests {
    /// 破損していない本は注意文を出さない。
    @Test func intactContentHasNoDamageNote() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("g26-intact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        // フォルダ本は打ち切りが起こらない経路。damageNote は既定の nil のまま。
        let content = FolderBookContent(url: url)
        #expect(await content.damageNote == nil)
    }

    /// 破損アーカイブは「読めた枚数」を含む注意文を返す。
    @Test func damagedArchiveReportsHowManyPagesItCouldRead() async throws {
        // Task 1 の DamagedArchiveTests.makeDamagedZip と同じ構造の zip をここでも作る。
        // （テストターゲットが別なのでヘルパは共有しない。重複は意図的。）
        let url = try DamagedZipFixture.write()
        defer { try? FileManager.default.removeItem(at: url) }

        let content = ArchiveBookContent(url: url)
        let note = await content.damageNote
        #expect(note != nil)
        #expect(note?.contains("破損") == true)
        #expect(note?.contains("ページまで読み込みました") == true)
    }
}
