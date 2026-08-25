// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
@testable import LibraryStore
import StackroomFormat

/// spec §4 の同期本体。**ユーザーのタグとメタデータを非可逆に壊しうる**ので、
/// 「消える」経路を重点的に固定する。
///
/// 実 I/O（xattr）は一時ディレクトリの実ファイルで行う。Spotlight だけは注入して差し替える
/// —— 索引が無効なボリュームも、`mdfind` の反映遅れも、テストからは作れないため。
@Suite("Finder タグ同期（G39）")
struct FinderTagSyncTests {
    private static let field = "keyword_a"

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("g39-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeDB() throws -> Database {
        let d = try Database.openInMemory()
        try d.migrate()
        return d
    }

    private func makeFile(_ dir: URL, _ name: String) throws -> URL {
        let f = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: f)
        return f
    }

    @discardableResult
    private func addBook(_ db: Database, path: URL, keywordA: String? = nil) throws -> Int {
        try db.insertBookReturningID(BookRecord(
            id: 0, title: path.lastPathComponent, path: path.path,
            dateAdded: Date(), keywordA: keywordA))
    }

    private func libraryValue(_ db: Database, _ id: Int) throws -> String? {
        try db.fetchAllBooks().first { $0.id == id }?.keywordA
    }

    private func tagNames(_ f: URL) throws -> [String] {
        try FinderTagStore.read(at: f).map(\.name)
    }

    /// 有効な plist だが文字列配列ではない = 壊れたタグ属性。
    private func writeCorruptedTags(_ f: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: [1, 2, 3], format: .binary, options: 0)
        _ = data.withUnsafeBytes {
            setxattr(f.path, FinderTagStore.attributeName, $0.baseAddress, data.count, 0, 0)
        }
    }

    // MARK: - 1. Finder → StackNest

    @Test func aTagThatOnlyExistsInFinderEntersTheLibrary() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let db = try makeDB()
        let f = try makeFile(dir, "a.zip")
        try FinderTagStore.write([FinderTagEntry(name: "SF", colorIndex: nil)], to: f)
        let id = try addBook(db, path: f)

        let r = try FinderTagSync.sync(database: db, volume: dir, field: Self.field,
                                       isIndexingEnabled: { _ in true },
                                       taggedPaths: { _ in [f.path] })

        #expect(r.updatedInLibrary == 1)
        #expect(r.updatedInFinder == 0)
        #expect(try libraryValue(db, id) == "SF")
        #expect(try db.finderTagBaseline(bookID: id) == "SF", "前回同期値が記録されていないと削除を検出できない")
    }

    // MARK: - 2. StackNest → Finder

    @Test func aValueThatOnlyExistsInTheLibraryIsWrittenToFinder() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let db = try makeDB()
        let f = try makeFile(dir, "b.zip")
        let id = try addBook(db, path: f, keywordA: "マンガ")

        // mdfind はこの本を返さない（タグがまだ 1 つも無いので当然）。
        let r = try FinderTagSync.sync(database: db, volume: dir, field: Self.field,
                                       isIndexingEnabled: { _ in true },
                                       taggedPaths: { _ in [] })

        #expect(r.updatedInFinder == 1)
        #expect(try tagNames(f) == ["マンガ"])
        #expect(try db.finderTagBaseline(bookID: id) == "マンガ")
    }

    // MARK: - 3. 削除が両方向に伝わる

    @Test func removingATagInFinderRemovesTheValueFromTheLibrary() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let db = try makeDB()
        let f = try makeFile(dir, "c.zip")
        try FinderTagStore.write([FinderTagEntry(name: "SF", colorIndex: nil)], to: f)
        let id = try addBook(db, path: f, keywordA: "SF")
        _ = try FinderTagSync.sync(database: db, volume: dir, field: Self.field,
                                   isIndexingEnabled: { _ in true }, taggedPaths: { _ in [f.path] })
        #expect(try db.finderTagBaseline(bookID: id) == "SF")

        // ユーザーが Finder でタグを外した。
        try FinderTagStore.write([], to: f)
        let r = try FinderTagSync.sync(database: db, volume: dir, field: Self.field,
                                       isIndexingEnabled: { _ in true }, taggedPaths: { _ in [] })

        #expect(r.updatedInLibrary == 1, "本物の削除は妨げない")
        #expect(try libraryValue(db, id) == "")
        #expect(try db.finderTagBaseline(bookID: id) == "")
    }

    @Test func removingAValueInTheLibraryRemovesTheTagFromFinder() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let db = try makeDB()
        let f = try makeFile(dir, "d.zip")
        try FinderTagStore.write([FinderTagEntry(name: "SF", colorIndex: nil)], to: f)
        let id = try addBook(db, path: f, keywordA: "SF")
        _ = try FinderTagSync.sync(database: db, volume: dir, field: Self.field,
                                   isIndexingEnabled: { _ in true }, taggedPaths: { _ in [f.path] })

        // ユーザーが StackNest 側で値を消した（CLI/MCP 経由でもありうる・spec §5）。
        try db.updateBook(id: id, patch: BookPatch(keywordA: ""))
        let r = try FinderTagSync.sync(database: db, volume: dir, field: Self.field,
                                       isIndexingEnabled: { _ in true }, taggedPaths: { _ in [f.path] })

        #expect(r.updatedInFinder == 1)
        #expect(try tagNames(f) == [])
    }

    // MARK: - 4. ★★ `mdfind` の沈黙で消えない（spec §4.5・このフェーズの心臓部）

    /// **`mdfind` が返さなかったことは「タグが無い証拠」ではない。**
    /// 索引が反映されていないだけ・置換中に読んだだけかもしれない。
    /// そのまま削除と解釈すると、**ユーザーが何もしていないのに両側からタグが消える**。
    @Test func silenceFromSpotlightNeverDeletesAnything() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let db = try makeDB()
        let f = try makeFile(dir, "e.zip")
        try FinderTagStore.write([FinderTagEntry(name: "SF", colorIndex: 6)], to: f)
        let id = try addBook(db, path: f, keywordA: "SF")
        _ = try FinderTagSync.sync(database: db, volume: dir, field: Self.field,
                                   isIndexingEnabled: { _ in true }, taggedPaths: { _ in [f.path] })

        // タグはファイルに**実在したまま**。mdfind だけが返さない（索引の反映遅れ）。
        let r = try FinderTagSync.sync(database: db, volume: dir, field: Self.field,
                                       isIndexingEnabled: { _ in true }, taggedPaths: { _ in [] })

        #expect(try libraryValue(db, id) == "SF", "StackNest 側のタグが消えてはいけない")
        #expect(try tagNames(f) == ["SF"], "Finder 側のタグも消えてはいけない")
        #expect(try FinderTagStore.read(at: f).first?.colorIndex == 6, "色も残ること")
        #expect(try db.finderTagBaseline(bookID: id) == "SF", "前回同期値も書き換えない")
        #expect(r.updatedInLibrary == 0)
        #expect(r.updatedInFinder == 0)
    }

    /// 索引がまるごと空を返す（庫じゅうが「タグ無し」に見える）状況でも同じ。
    /// **被害が 1 冊ではなく庫全体になる経路**（spec §4.5 の表の 2 行目・3 行目）。
    @Test func anEmptyIndexDoesNotWipeTheWholeLibrary() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let db = try makeDB()
        var ids: [Int] = []
        var files: [URL] = []
        for i in 0..<5 {
            let f = try makeFile(dir, "book\(i).zip")
            try FinderTagStore.write([FinderTagEntry(name: "T\(i)", colorIndex: nil)], to: f)
            ids.append(try addBook(db, path: f, keywordA: "T\(i)"))
            files.append(f)
        }
        _ = try FinderTagSync.sync(database: db, volume: dir, field: Self.field,
                                   isIndexingEnabled: { _ in true },
                                   taggedPaths: { _ in files.map(\.path) })

        let r = try FinderTagSync.sync(database: db, volume: dir, field: Self.field,
                                       isIndexingEnabled: { _ in true }, taggedPaths: { _ in [] })

        for (i, id) in ids.enumerated() {
            #expect(try libraryValue(db, id) == "T\(i)")
            #expect(try tagNames(files[i]) == ["T\(i)"])
        }
        #expect(r.updatedInLibrary == 0)
        #expect(r.updatedInFinder == 0)
    }

    /// 逆向きの被害も同じ穴から出る: `mdfind` の不在を信じて書き戻すと、**Finder にしか
    /// 無かったタグを消してしまう**（`apply` は同期対象のタグを `names` に揃えるため）。
    @Test func silenceFromSpotlightNeverDeletesATagOnlyFinderKnows() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let db = try makeDB()
        let f = try makeFile(dir, "e2.zip")
        try FinderTagStore.write([FinderTagEntry(name: "OnlyInFinder", colorIndex: 2)], to: f)
        let id = try addBook(db, path: f, keywordA: "OnlyInLib")

        // 一度も同期していない本（baseline なし）に、StackNest 側の値を書き戻す場面。
        // mdfind はこの本を返さないが、ファイルにはタグが実在する。
        _ = try FinderTagSync.sync(database: db, volume: dir, field: Self.field,
                                   isIndexingEnabled: { _ in true }, taggedPaths: { _ in [] })

        #expect(try Set(tagNames(f)) == ["OnlyInFinder", "OnlyInLib"], "Finder 側のタグを消してはいけない")
        #expect(try FinderTagStore.read(at: f).first { $0.name == "OnlyInFinder" }?.colorIndex == 2)
        #expect(try libraryValue(db, id) == "OnlyInLib, OnlyInFinder")
    }

    // MARK: - 5. ★ 索引が無効（spec §3.3）

    @Test func withIndexingDisabledOnlyTheWriteBackDirectionRuns() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let db = try makeDB()
        let onlyFinder = try makeFile(dir, "f1.zip")
        try FinderTagStore.write([FinderTagEntry(name: "FromFinder", colorIndex: 3)], to: onlyFinder)
        let finderID = try addBook(db, path: onlyFinder)

        let onlyLibrary = try makeFile(dir, "f2.zip")
        let libraryID = try addBook(db, path: onlyLibrary, keywordA: "FromLib")

        // 書き戻す本に、Finder 側だけが知っているタグがある場合。
        // 書き戻し（StackNest → Finder）は走るが、**その逆は走らない**。
        let both = try makeFile(dir, "f3.zip")
        try FinderTagStore.write([FinderTagEntry(name: "Extra", colorIndex: nil)], to: both)
        let bothID = try addBook(db, path: both, keywordA: "FromLib2")

        var askedSpotlight = false
        let r = try FinderTagSync.sync(database: db, volume: dir, field: Self.field,
                                       isIndexingEnabled: { _ in false },
                                       taggedPaths: { _ in askedSpotlight = true; return [] })

        #expect(r.indexingDisabled)
        #expect(!askedSpotlight, "索引が無効なら mdfind は当てにならない（exit 0 で空を返す）")
        // Finder → StackNest 方向は走らない
        #expect(try libraryValue(db, finderID) == nil)
        #expect(r.updatedInLibrary == 0)
        // …が、Finder 側のタグを消してしまってもいけない
        #expect(try tagNames(onlyFinder) == ["FromFinder"])
        #expect(try FinderTagStore.read(at: onlyFinder).first?.colorIndex == 3)
        // StackNest → Finder 方向は動く
        #expect(r.updatedInFinder == 2)
        #expect(try tagNames(onlyLibrary) == ["FromLib"])
        #expect(try db.finderTagBaseline(bookID: libraryID) == "FromLib")
        // 書き戻した本でも、Finder 側の値は StackNest 側へ入れない（この方向は無効）
        #expect(try libraryValue(db, bothID) == "FromLib2")
        #expect(try Set(tagNames(both)) == ["Extra", "FromLib2"], "Finder 側の既存タグは残す")
        #expect(try db.finderTagBaseline(bookID: bothID) == "FromLib2",
                "前回同期値は StackNest 側の値。merged を書くと索引が戻ったとき削除と読まれる")
    }

    /// 索引が無効なときに**全件の xattr を読みに行かない**（spec §3.3 が明示的に禁じている）。
    /// StackNest 側が前回同期から変わっていない本には触らない。
    @Test func withIndexingDisabledUnchangedBooksAreNotTouched() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let db = try makeDB()
        let f = try makeFile(dir, "g.zip")
        try FinderTagStore.write([FinderTagEntry(name: "SF", colorIndex: nil)], to: f)
        let id = try addBook(db, path: f, keywordA: "SF")
        _ = try FinderTagSync.sync(database: db, volume: dir, field: Self.field,
                                   isIndexingEnabled: { _ in true }, taggedPaths: { _ in [f.path] })
        #expect(try db.finderTagBaseline(bookID: id) == "SF")
        // ファイルを読めなくする。触ったら必ずエラーになるので「触っていない」ことが分かる。
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: f.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.path) }

        let r = try FinderTagSync.sync(database: db, volume: dir, field: Self.field,
                                       isIndexingEnabled: { _ in false }, taggedPaths: { _ in [] })

        #expect(r.updatedInFinder == 0)
        #expect(r.updatedInLibrary == 0)
        #expect(r.skippedBooks.isEmpty)
    }

    // MARK: - 6. ★ 区切り文字を含むタグ（spec §4.4）

    @Test func aTagContainingTheSeparatorIsSkippedWithoutBlockingTheOthers() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let db = try makeDB()
        let f = try makeFile(dir, "h.zip")
        try FinderTagStore.write([FinderTagEntry(name: "SF, ファンタジー", colorIndex: 6),
                                  FinderTagEntry(name: "マンガ", colorIndex: nil)], to: f)
        let id = try addBook(db, path: f)

        let r = try FinderTagSync.sync(database: db, volume: dir, field: Self.field,
                                       isIndexingEnabled: { _ in true }, taggedPaths: { _ in [f.path] })

        #expect(try libraryValue(db, id) == "マンガ", "同じ本の他のタグは同期される")
        #expect(r.skippedTags == ["SF, ファンタジー"])
        let back = try FinderTagStore.read(at: f)
        #expect(back.contains { $0.name == "SF, ファンタジー" && $0.colorIndex == 6 },
                "スキップしたタグを消してはいけない（色ごと）")
        #expect(try db.finderTagBaseline(bookID: id) == "マンガ",
                "前回同期値にスキップしたタグを混ぜない（次回 Finder 側の削除と誤読される）")
    }

    // MARK: - 7. ★ 色が保たれる（統合）

    @Test func syncingKeepsTheColourOfExistingTags() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let db = try makeDB()
        let f = try makeFile(dir, "i.zip")
        try FinderTagStore.write([FinderTagEntry(name: "レッド", colorIndex: 6)], to: f)
        _ = try addBook(db, path: f, keywordA: "レッド, 青")

        let r = try FinderTagSync.sync(database: db, volume: dir, field: Self.field,
                                       isIndexingEnabled: { _ in true }, taggedPaths: { _ in [f.path] })

        #expect(r.updatedInFinder == 1)
        let back = try FinderTagStore.read(at: f)
        #expect(back.first { $0.name == "レッド" }?.colorIndex == 6)
        #expect(back.first { $0.name == "青" }?.colorIndex == nil)
    }

    // MARK: - 8. ★ 壊れた plist は 1 冊分だけ諦める（spec §4.6）

    @Test func oneCorruptedBookDoesNotStopTheRest() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let db = try makeDB()
        let broken = try makeFile(dir, "broken.zip")
        try writeCorruptedTags(broken)
        _ = try addBook(db, path: broken)
        let ok = try makeFile(dir, "ok.zip")
        let okID = try addBook(db, path: ok, keywordA: "OK")

        let r = try FinderTagSync.sync(database: db, volume: dir, field: Self.field,
                                       isIndexingEnabled: { _ in true },
                                       taggedPaths: { _ in [broken.path, ok.path] })

        #expect(r.skippedBooks == [broken.path])
        #expect(r.updatedInFinder == 1)
        #expect(try tagNames(ok) == ["OK"])
        #expect(try db.finderTagBaseline(bookID: okID) == "OK")
    }

    /// **壊れた plist 以外のエラーを一緒に握り潰さないこと**（spec §4.6）。
    /// `ENOENT`（ボリューム未マウント）や `EACCES` まで飲み込むと、全件が無言でスキップされ、
    /// §4.5 の「庫じゅうが空に見える」と同型の事故になる。読み取り経路。
    @Test func aPermissionFailureWhileReadingIsNotSwallowed() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let db = try makeDB()
        let f = try makeFile(dir, "j.zip")
        try FinderTagStore.write([FinderTagEntry(name: "SF", colorIndex: nil)], to: f)
        _ = try addBook(db, path: f)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: f.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.path) }

        #expect(throws: FinderTagError.self) {
            _ = try FinderTagSync.sync(database: db, volume: dir, field: Self.field,
                                       isIndexingEnabled: { _ in true }, taggedPaths: { _ in [f.path] })
        }
    }

    /// 同じく書き込み経路。
    @Test func aPermissionFailureWhileWritingIsNotSwallowed() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let db = try makeDB()
        let f = try makeFile(dir, "k.zip")
        _ = try addBook(db, path: f, keywordA: "マンガ")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: f.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.path) }

        #expect(throws: FinderTagError.self) {
            _ = try FinderTagSync.sync(database: db, volume: dir, field: Self.field,
                                       isIndexingEnabled: { _ in true }, taggedPaths: { _ in [] })
        }
    }

    /// 本のファイルが見つからないのは「壊れた plist」とは別の理由で 1 冊分だけ諦める。
    /// **errno を握り潰すのではなく、存在を明示的に確かめてから諦める。**
    @Test func aMissingFileIsSkippedNotFatal() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let db = try makeDB()
        let gone = dir.appendingPathComponent("gone.zip")
        _ = try addBook(db, path: gone, keywordA: "値だけある")
        let ok = try makeFile(dir, "l.zip")
        _ = try addBook(db, path: ok, keywordA: "OK")

        let r = try FinderTagSync.sync(database: db, volume: dir, field: Self.field,
                                       isIndexingEnabled: { _ in true }, taggedPaths: { _ in [] })

        #expect(r.skippedBooks == [gone.path])
        #expect(try tagNames(ok) == ["OK"])
    }

    /// ボリュームごと見当たらないのは**全件スキップにせず投げる**。
    /// 黙って 0 件同期にすると「庫じゅうタグ無し」と区別が付かない。
    @Test func aMissingVolumeThrowsInsteadOfSkippingEverything() throws {
        let dir = try tempDir()
        let db = try makeDB()
        try FileManager.default.removeItem(at: dir)
        #expect(throws: FinderTagSyncError.volumeUnavailable(dir.path)) {
            _ = try FinderTagSync.sync(database: db, volume: dir, field: Self.field,
                                       isIndexingEnabled: { _ in true }, taggedPaths: { _ in [] })
        }
    }

    // MARK: - 9. whitelist

    @Test func anUnsupportedFieldThrowsAndChangesNothing() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let db = try makeDB()
        let f = try makeFile(dir, "m.zip")
        try FinderTagStore.write([FinderTagEntry(name: "SF", colorIndex: nil)], to: f)
        let id = try addBook(db, path: f, keywordA: "マンガ")

        for bad in ["memo", "title", "rating", "", "keyword_d", "keyword_a; DROP TABLE book"] {
            #expect(throws: FinderTagSyncError.unsupportedField(bad)) {
                _ = try FinderTagSync.sync(database: db, volume: dir, field: bad,
                                           isIndexingEnabled: { _ in true },
                                           taggedPaths: { _ in [f.path] })
            }
        }
        #expect(try libraryValue(db, id) == "マンガ")
        #expect(try tagNames(f) == ["SF"])
        #expect(try db.finderTagBaseline(bookID: id) == nil, "何もしていないので前回同期値も付かない")
    }

    @Test func everyWhitelistedFieldRoundTrips() throws {
        for field in FinderTagSync.syncableFields.sorted() {
            let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
            let db = try makeDB()
            let f = try makeFile(dir, "n.zip")
            try FinderTagStore.write([FinderTagEntry(name: "SF", colorIndex: nil)], to: f)
            let id = try addBook(db, path: f)

            let r = try FinderTagSync.sync(database: db, volume: dir, field: field,
                                           isIndexingEnabled: { _ in true },
                                           taggedPaths: { _ in [f.path] })

            #expect(r.updatedInLibrary == 1, "\(field) に入らなかった")
            let row = try db.fetchAllBooks().first { $0.id == id }
            #expect(FinderTagSync.value(of: field, in: row!) == "SF", "\(field)")
        }
    }

    // MARK: - 項目の切り替え（spec §4.2）

    /// 同期対象の項目を切り替えたら前回同期値は無効。残したまま切り替えると、
    /// **別項目の値を「前回のタグ」と誤認して実在しない削除を検出する**。
    @Test func switchingTheFieldResetsTheBaselines() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let db = try makeDB()
        let f = try makeFile(dir, "o.zip")
        try FinderTagStore.write([FinderTagEntry(name: "SF", colorIndex: nil)], to: f)
        let id = try addBook(db, path: f, keywordA: "SF")
        _ = try FinderTagSync.sync(database: db, volume: dir, field: "keyword_a",
                                   isIndexingEnabled: { _ in true }, taggedPaths: { _ in [f.path] })
        #expect(try db.finderTagBaseline(bookID: id) == "SF")

        // 項目を neta に切り替える。neta は空なので、前回値が残っていると
        // 「StackNest 側で SF を消した」と読まれ、Finder のタグまで消える。
        let r = try FinderTagSync.sync(database: db, volume: dir, field: "neta",
                                       isIndexingEnabled: { _ in true }, taggedPaths: { _ in [f.path] })

        #expect(try tagNames(f) == ["SF"], "項目を替えただけで Finder のタグが消えてはいけない")
        #expect(try libraryValue(db, id) == "SF", "keyword_a は触られない")
        #expect(r.updatedInLibrary == 1)
        #expect(try db.fetchAllBooks().first { $0.id == id }?.neta == "SF")
    }

    // MARK: - 冪等性

    @Test func syncingTwiceChangesNothingTheSecondTime() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let db = try makeDB()
        let f1 = try makeFile(dir, "p1.zip")
        try FinderTagStore.write([FinderTagEntry(name: "SF", colorIndex: 6)], to: f1)
        _ = try addBook(db, path: f1, keywordA: "マンガ")
        let f2 = try makeFile(dir, "p2.zip")
        _ = try addBook(db, path: f2)

        _ = try FinderTagSync.sync(database: db, volume: dir, field: Self.field,
                                   isIndexingEnabled: { _ in true }, taggedPaths: { _ in [f1.path] })
        let second = try FinderTagSync.sync(database: db, volume: dir, field: Self.field,
                                            isIndexingEnabled: { _ in true },
                                            taggedPaths: { _ in [f1.path] })

        #expect(second.updatedInLibrary == 0)
        #expect(second.updatedInFinder == 0)
        #expect(try Set(tagNames(f1)) == ["SF", "マンガ"])
        // タグも値も無い本は前回同期値を持たない（12,000 冊分の無駄な書き込みをしない）
        let untouched = try db.fetchAllBooks().first { $0.path == f2.path }!
        #expect(try db.finderTagBaseline(bookID: untouched.id) == nil)
    }
}

/// レビューが「テストが 1 本も無い」と指摘した箇所を固定する。
/// いずれも壊れても既存テストが緑のままだった（生存変異）。
@Suite("Finder タグ同期の細部（G39・レビュー由来）")
struct FinderTagSyncDetailTests {
    /// ★ フォルダの本は `path` に末尾 `/` が付きうる。落とさないと `mdfind` の出力と
    /// 突き合わず、**値の無い本に新しく付いたタグが永久に拾われない**（直読みが起動しないため）。
    @Test func trailingSlashesAreStrippedSoFolderBooksMatchSpotlight() {
        #expect(FinderTagSync.normalize("/Volumes/comic/本/") == "/Volumes/comic/本")
        #expect(FinderTagSync.normalize("/Volumes/comic/本///") == "/Volumes/comic/本")
        #expect(FinderTagSync.normalize("/Volumes/comic/本.zip") == "/Volumes/comic/本.zip")
        #expect(FinderTagSync.normalize("/") == "/", "根だけは残す")
    }

    /// ★ spec §2 が決めた 7 項目そのものを固定する。
    /// 既存テストは whitelist 自身を回すので、**項目が減っても増えても検出できない**。
    @Test func theSyncableFieldsAreTheOnesTheSpecChose() {
        #expect(FinderTagSync.syncableFields == [
            "genre", "series", "author", "neta", "keyword_a", "keyword_b", "keyword_c",
        ])
    }

    /// 既存の並びを保ち、増えた分を末尾に足す（`FinderTagStore.apply` と同じ方針）。
    @Test func orderedKeepsWhatWasThereAndAppendsTheRest() {
        #expect(FinderTagSync.ordered(["c", "a", "z"], preferring: ["c", "a"]) == ["c", "a", "z"])
        #expect(FinderTagSync.ordered(["a"], preferring: ["c", "a"]) == ["a"])
        #expect(FinderTagSync.ordered(["b", "a"], preferring: []) == ["a", "b"],
                "元の並びが無ければ決定的に並べる")
    }
}

/// G39 追補: **中断が本の境界で効くこと**（`FinderTagSync.sync` の `Task.isCancelled`）。
///
/// ここに至るまでの経緯: 中断チェックは当初**ボリュームの境界にしか無かった**。
/// 普通の庫はボリュームが 1 個なので、庫を閉じても実質何も止まらない
/// （レビューが実測: cancel 済みで 200/200 冊を処理した）。本の境界に移して直したが、
/// **その修正にテストが無かった** —— このプロジェクトが繰り返し踏んできた
/// 「守っていると称して何もしていない分岐」と同じ形なので、ここで固定する。
///
/// **実機 smoke では確かめられない。** 484 冊の庫で同期は 0.4 秒で終わり、
/// 外から「途中で閉じる」を当てられない（2026-08-24 に実測して断念した）。
@Suite("Finder タグ同期の中断（G39）")
struct FinderTagSyncCancellationTests {
    private static let field = "keyword_a"

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("g39-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 書き出す仕事が確実にある庫を作る（図書側に値があり、Finder 側は空）。
    private func makeFixture(_ dir: URL, count: Int) throws -> (Database, [URL]) {
        let db = try Database.openInMemory()
        try db.migrate()
        var files: [URL] = []
        for i in 0..<count {
            let f = dir.appendingPathComponent("book\(i).cbz")
            try Data("x".utf8).write(to: f)
            _ = try db.insertBookReturningID(BookRecord(
                id: 0, title: "book\(i)", path: f.path, dateAdded: Date(), keywordA: "書き出す値"))
            files.append(f)
        }
        return (db, files)
    }

    /// 対照: 中断していなければ全冊に書き出す。
    /// **これが無いと次のテストの「0 件」が「そもそも仕事が無かった」と区別できない。**
    @Test("中断していなければ全冊書き出す（対照）")
    func writesEverythingWhenNotCancelled() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (db, files) = try makeFixture(dir, count: 5)

        let r = try FinderTagSync.sync(database: db, volume: dir, field: Self.field,
                                       isIndexingEnabled: { _ in true }, taggedPaths: { _ in [] })

        #expect(r.updatedInFinder == 5)
        for f in files {
            #expect(try FinderTagStore.read(at: f).map(\.name) == ["書き出す値"])
        }
    }

    /// ★ 本命: 既に中断されたタスクの中では**1 冊も触らない**。
    ///
    /// xattr を見るのが要点 —— 閉じた庫への DB 書き込みは黙って no-op になるので、
    /// 図書側の件数では「中断できた」と「書けなかっただけ」を区別できない。
    /// **ファイルに書いてしまったかどうか**だけが非可逆な事実。
    @Test("中断済みなら 1 冊も書き出さない")
    func writesNothingWhenAlreadyCancelled() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (db, files) = try makeFixture(dir, count: 5)

        let task = Task<FinderTagSyncReport, Error> {
            // 走り出す前に中断されているので、最初の本の境界で抜ける。
            while !Task.isCancelled { await Task.yield() }
            return try FinderTagSync.sync(database: db, volume: dir, field: Self.field,
                                          isIndexingEnabled: { _ in true }, taggedPaths: { _ in [] })
        }
        task.cancel()
        let r = try await task.value

        #expect(r.updatedInFinder == 0, "中断済みなのに Finder へ書いた")
        #expect(r.updatedInLibrary == 0)
        for f in files {
            #expect(try FinderTagStore.read(at: f).isEmpty, "ファイルにタグが書かれてしまった")
        }
    }
}

/// Codex レビュー P1（2026-08-25）: **同期の飛行中に前回同期値が全消しされたら、
/// このラウンドの分を書き戻さない。**
///
/// 消す経路は設定シート / CLI / MCP / 共有サーバ / 別窓と複数あり（spec §5）、
/// 消す側で飛行中の同期を止めるのは漏れる。だから**書き戻す側**が世代番号を見て降りる。
///
/// 書き戻さなければ次回は「初回」として合併するだけで**削除は起きない**（安全側）。
/// 逆に書き戻してしまうと「無効にしていた間の編集は削除とみなさない」という
/// spec §4.2 の安全策が破れ、**Finder のタグが実際に消える**（非可逆）。
@Suite("Finder タグ同期と前回同期値の全消しの競合（G39・Codex P1）")
struct FinderTagBaselineGenerationTests {
    private static let field = "keyword_a"

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("g39-gen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func fixture(_ dir: URL) throws -> (Database, URL, Int) {
        let db = try Database.openInMemory()
        try db.migrate()
        let f = dir.appendingPathComponent("book.cbz")
        try Data("x".utf8).write(to: f)
        let id = try db.insertBookReturningID(BookRecord(
            id: 0, title: "book", path: f.path, dateAdded: Date(), keywordA: "値"))
        return (db, f, id)
    }

    @Test("全消しは世代番号を上げる")
    func clearingBumpsTheGeneration() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        #expect(try db.finderTagBaselineGeneration() == 0)
        try db.clearAllFinderTagBaselines()
        #expect(try db.finderTagBaselineGeneration() == 1)
        try db.clearAllFinderTagBaselines()
        #expect(try db.finderTagBaselineGeneration() == 2)
    }

    /// 対照: 誰も消さなければ前回同期値は普通に書かれる。
    /// **これが無いと次のテストの「書かれない」が「そもそも書く物が無かった」と区別できない。**
    @Test("誰も消さなければ前回同期値は書かれる（対照）")
    func writesTheBaselineWhenNobodyClears() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (db, _, id) = try fixture(dir)

        _ = try FinderTagSync.sync(database: db, volume: dir, field: Self.field,
                                   isIndexingEnabled: { _ in true }, taggedPaths: { _ in [] })

        #expect(try db.finderTagBaseline(bookID: id) == "値")
    }

    /// ★ 本命: 同期の**最中に**全消しされたら、そのラウンドの前回同期値は書かない。
    /// `taggedPaths` の中で消す —— 本を回し始める前の、実際に起こりうる位置。
    @Test("飛行中に全消しされたら前回同期値を書き戻さない")
    func doesNotResurrectBaselinesClearedMidFlight() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (db, _, id) = try fixture(dir)

        _ = try FinderTagSync.sync(
            database: db, volume: dir, field: Self.field,
            isIndexingEnabled: { _ in true },
            taggedPaths: { _ in
                // ここで設定シート / CLI / MCP が同期項目を変えた、を模す。
                try db.clearAllFinderTagBaselines()
                return []
            })

        #expect(try db.finderTagBaseline(bookID: id) == nil,
                "消したはずの前回同期値が書き戻されている（次回の照合が実在しない削除を見る）")
    }
}
