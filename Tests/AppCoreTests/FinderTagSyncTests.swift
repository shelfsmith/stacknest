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

    /// ★ 同期できる項目そのものを固定する。
    /// 既存テストは whitelist 自身を回すので、**項目が減っても増えても検出できない**。
    ///
    /// **`series` は 2026-08-25 に外した**（Codex レビュー 4 巡目）。spec §2 は当初 7 項目
    /// としていたが、§4.4 の前提「StackNest 側の値に `", "` は構造上あり得ない」が
    /// **単一値の `series` にだけ当てはまらない**。実測: `Love, Chunibyo & Other Delusions`
    /// が Finder 上で 2 個のタグに分裂し、**片方を消すと series が `Love` になる**（非可逆）。
    @Test func theSyncableFieldsAreTheOnesTheSpecChose() {
        #expect(FinderTagSync.syncableFields == [
            "genre", "author", "neta", "keyword_a", "keyword_b", "keyword_c",
        ])
        #expect(FinderTagSync.syncableFields.contains("series") == false,
                "単一値の列を区切りで分割してはいけない")
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
    ///
    /// **2 巡目で保護が強くなった**: 当初は「書き戻さない」だけだったが、
    /// Codex の 2・3 巡目の指摘を受けて**そのラウンド自体を中断して溜めた分を捨てる**ようにした
    /// （書き戻さないだけでは、古い項目のまま Finder と図書を書き換え続けてしまう）。
    /// ここではその両方 —— 投げること と 前回同期値が残らないこと —— を見る。
    @Test("飛行中に全消しされたら中断し、前回同期値も書き戻さない")
    func doesNotResurrectBaselinesClearedMidFlight() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (db, _, id) = try fixture(dir)

        #expect(throws: FinderTagSyncError.fieldChangedDuringSync) {
            _ = try FinderTagSync.sync(
                database: db, volume: dir, field: Self.field,
                isIndexingEnabled: { _ in true },
                taggedPaths: { _ in
                    // ここで設定シート / CLI / MCP が同期項目を変えた、を模す。
                    try db.clearAllFinderTagBaselines()
                    return []
                })
        }

        #expect(try db.finderTagBaseline(bookID: id) == nil,
                "消したはずの前回同期値が書き戻されている（次回の照合が実在しない削除を見る）")
    }
}

/// Codex レビュー 2 巡目（2026-08-25）: 前回同期値を書かないだけでは足りない。
///
/// 1 巡目の修正は「書き戻さない」までしか守っておらず、**このラウンドは古い項目のまま
/// Finder のタグと図書の値を書き換えながら進み続けていた**。項目が変わった後も書くと、
/// 古い項目の値が Finder に残り、次の照合で**新しい項目へ流れ込む**（非可逆の混入）。
///
/// 直したのは 2 箇所。**64 冊ごとに世代を見て抜ける**（ここのテスト）と、
/// **`AppState.setFinderTagSyncField` が先に走行中の同期を止める**（App 層のテスト）。
@Suite("項目が変わったら書き込みごと止める（G39・Codex 2 巡目）")
struct FinderTagSyncFieldChangeAbortTests {
    private static let field = "keyword_a"

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("g39-abort-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 世代の確認は 64 冊ごとなので、確実に跨ぐ数を用意する。
    private func fixture(_ dir: URL, count: Int) throws -> (Database, [URL]) {
        let db = try Database.openInMemory()
        try db.migrate()
        var files: [URL] = []
        for i in 0..<count {
            let f = dir.appendingPathComponent("b\(i).cbz")
            try Data("x".utf8).write(to: f)
            _ = try db.insertBookReturningID(BookRecord(
                id: 0, title: "b\(i)", path: f.path, dateAdded: Date(), keywordA: "値\(i)"))
            files.append(f)
        }
        return (db, files)
    }

    /// ★ 本命: 走っている最中に項目が変えられたら**投げて止まる**。
    /// 図書の値は 1 冊も書かれない（溜めた分を捨てるので）。
    @Test("走行中に項目が変わったら中断して溜めた分を捨てる")
    func abortsAndDiscardsWhenTheFieldChanges() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (db, _) = try fixture(dir, count: 200)

        #expect(throws: FinderTagSyncError.fieldChangedDuringSync) {
            _ = try FinderTagSync.sync(
                database: db, volume: dir, field: Self.field,
                isIndexingEnabled: { _ in true },
                taggedPaths: { _ in
                    // 走り出した直後に設定シート / CLI / MCP が項目を変えた、を模す。
                    try db.clearAllFinderTagBaselines()
                    return []
                })
        }
        #expect(try db.finderTagBaselines().isEmpty, "前回同期値を書き戻していない")
    }

    /// 対照: 誰も変えなければ最後まで走って前回同期値が入る。
    @Test("誰も変えなければ完走する（対照）")
    func completesWhenNobodyChangesTheField() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (db, _) = try fixture(dir, count: 200)

        let r = try FinderTagSync.sync(database: db, volume: dir, field: Self.field,
                                       isIndexingEnabled: { _ in true }, taggedPaths: { _ in [] })
        #expect(r.updatedInFinder == 200)
        #expect(try db.finderTagBaselines().count == 200)
    }
}

/// Codex レビュー 2 巡目 P2: **ボリュームごとの回で、そのボリュームの本だけを見る。**
///
/// 渡さないと `sync` はボリュームごとに庫の全冊を回すので、仕事が `ボリューム数 × 冊数` になる。
/// 加えて、あるボリュームの回で別のボリュームの本を**そのボリュームの索引状態で**処理してしまい、
/// 「索引が無効なら Finder → StackNest 方向は動かさない」（spec §3.3）が本ごとに崩れる。
@Suite("ボリュームごとに担当の本だけ見る（G39・Codex 2 巡目 P2）")
struct FinderTagSyncVolumeScopeTests {
    private static let field = "keyword_a"

    @Test("担当外の本には触らない")
    func leavesBooksOnOtherVolumesAlone() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("g39-scope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let db = try Database.openInMemory()
        try db.migrate()
        let mine = dir.appendingPathComponent("mine.cbz")
        let theirs = dir.appendingPathComponent("theirs.cbz")
        try Data("x".utf8).write(to: mine)
        try Data("x".utf8).write(to: theirs)
        _ = try db.insertBookReturningID(BookRecord(
            id: 0, title: "mine", path: mine.path, dateAdded: Date(), keywordA: "書く"))
        _ = try db.insertBookReturningID(BookRecord(
            id: 0, title: "theirs", path: theirs.path, dateAdded: Date(), keywordA: "書かない"))

        let r = try FinderTagSync.sync(
            database: db, volume: dir, field: Self.field,
            isIndexingEnabled: { _ in true }, taggedPaths: { _ in [] },
            includesPath: { $0 == mine.path })

        #expect(r.updatedInFinder == 1, "担当の 1 冊だけ書く")
        #expect(try FinderTagStore.read(at: mine).map(\.name) == ["書く"])
        #expect(try FinderTagStore.read(at: theirs).isEmpty, "担当外の本にタグを書いてしまった")
    }

    /// 既定は全件（既存の呼び出しの挙動を変えていないこと）。
    @Test("既定では全件を見る")
    func defaultsToEveryBook() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("g39-scope-all-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let db = try Database.openInMemory()
        try db.migrate()
        for i in 0..<3 {
            let f = dir.appendingPathComponent("b\(i).cbz")
            try Data("x".utf8).write(to: f)
            _ = try db.insertBookReturningID(BookRecord(
                id: 0, title: "b\(i)", path: f.path, dateAdded: Date(), keywordA: "値"))
        }
        let r = try FinderTagSync.sync(database: db, volume: dir, field: Self.field,
                                       isIndexingEnabled: { _ in true }, taggedPaths: { _ in [] })
        #expect(r.updatedInFinder == 3)
    }
}

/// 図書側の書き込みが失敗したときに**前回同期値を残さない**こと。
///
/// レビューが実測で見つけた欠陥（部分適用の直後に再同期すると `tags=[]` になる）を守るもので、
/// **これまでテストが無かった**（「実測した」で終わっていた）。書き込み失敗はトリガで
/// 確実に起こす（`SQLITE_BUSY` はテストから狙って作れない）。
///
/// **Codex 3 巡目 P2 の扱い**: 「`updatedInLibrary` が未コミット分を数えたまま報告される」と
/// 指摘されたが、**その値は外に出ない** —— flush が失敗すると `sync` は必ず投げるので、
/// `FinderTagSyncReport` は生成されない（このテストがまさにそれを示している）。
/// 数え方は念のため直した（書けなかった分を引く）が、**報告に現れる欠陥ではなかった。**
@Suite("書き込み失敗時に前回同期値を残さない（G39）")
struct FinderTagSyncCommitCountTests {
    private static let field = "keyword_a"

    @Test("図書側の書き込みが失敗したら前回同期値も残さない")
    func failedWritesLeaveNoBaseline() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("g39-count-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let db = try Database.openInMemory()
        try db.migrate()
        var files: [URL] = []
        for i in 0..<3 {
            let f = dir.appendingPathComponent("b\(i).cbz")
            try Data("x".utf8).write(to: f)
            // 図書側は空・Finder 側にタグ ＝ Finder → 図書の更新が 3 件出る状況。
            _ = try db.insertBookReturningID(BookRecord(
                id: 0, title: "b\(i)", path: f.path, dateAdded: Date()))
            try FinderTagStore.apply(names: ["取り込む"], to: f)
            files.append(f)
        }
        // 図書側の UPDATE を必ず失敗させる。
        try db.queue?.write { conn in
            try conn.execute(sql: """
                CREATE TRIGGER block_update BEFORE UPDATE OF keyword_a ON book
                BEGIN SELECT RAISE(ABORT, 'blocked'); END;
                """)
        }

        var report: FinderTagSyncReport?
        #expect(throws: (any Error).self) {
            report = try FinderTagSync.sync(
                database: db, volume: dir, field: Self.field,
                isIndexingEnabled: { _ in true }, taggedPaths: { _ in files.map(\.path) })
        }
        // ★ **投げるので report は受け取れない。**Codex P2 が言う「不正確な件数」は
        // ここから外へ出ない、ということでもある。DB を直接見て確かめる。
        #expect(report == nil)
        let written = try db.fetchAllBooks().filter { $0.keywordA != nil }.count
        #expect(written == 0, "前提: 図書側には 1 件も書けていない")
        #expect(try db.finderTagBaselines().isEmpty,
                "書けていないのに前回同期値を書いてはいけない（次回が実在しない削除を見る）")
    }
}

/// Codex レビュー 8 巡目（2026-08-25）: **同期中に庫を閉じると、xattr だけ先に進む。**
///
/// `closeBundle()` は子を cancel してすぐ `database.close()` へ進む。同期は
/// **xattr は 1 冊ずつ即座に書く**が、図書側と前回同期値は**最後にまとめて**書くので、
/// この瞬間に閉じられると DB 側の書き込みが黙って no-op になり、
/// **Finder のほうが図書より進んだ**状態が残る。
///
/// **その状態は次の照合で安全側に収束する**（＝削除は起きない）ことをここで固定する。
/// 前回同期値も書かれていないので、次回は「Finder 側が変わった」と読んで**取り込む**。
/// 逆（図書側の欠落を「ユーザーが消した」と読んで Finder から消す）にはならない。
///
/// この性質があるので、`closeBundle()` を async にして待つ改修は見送っている
/// （DB を閉じる順序に手を入れる риск のほうが大きい）。**受け入れている挙動**。
@Suite("閉庫で xattr だけ進んだ状態は次回に収束する（G39・Codex 8 巡目）")
struct FinderTagSyncCloseMidFlightConvergenceTests {
    private static let field = "keyword_a"

    @Test("Finder が図書より進んでいても、次の照合は取り込む（消さない）")
    func theNextRoundImportsRatherThanDeletes() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("g39-conv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let db = try Database.openInMemory()
        try db.migrate()
        let f = dir.appendingPathComponent("b.cbz")
        try Data("x".utf8).write(to: f)
        // 閉庫直後の状態を作る: 図書側は古いまま・前回同期値も古いまま・**xattr だけ新しい**。
        let id = try db.insertBookReturningID(BookRecord(
            id: 0, title: "b", path: f.path, dateAdded: Date(), keywordA: "元の値"))
        try db.setFinderTagBaseline(bookID: id, value: "元の値")
        try FinderTagStore.apply(names: ["元の値", "あとから付いた"], to: f)

        let r = try FinderTagSync.sync(database: db, volume: dir, field: Self.field,
                                       isIndexingEnabled: { _ in true },
                                       taggedPaths: { _ in [f.path] })

        let after = try db.fetchAllBooks().first { $0.id == id }?.keywordA ?? ""
        #expect(Set(MultiValueParser.split(after)) == ["元の値", "あとから付いた"],
                "Finder が進んでいた分を取り込むこと（実際: \(after)）")
        #expect(r.updatedInLibrary == 1)
        #expect(try FinderTagStore.read(at: f).map(\.name).sorted()
                == ["あとから付いた", "元の値"].sorted(),
                "Finder のタグを消してはいけない")
    }
}
