// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
@testable import LibraryStore
import ArchiveAdapter

@Suite("quick integrity scan (G27a)")
struct QuickIntegrityScannerTests {
    private func setupDB() throws -> Database {
        let db = try Database.openInMemory()
        try db.migrate()
        return db
    }

    private func book(id: Int, title: String, path: String, pages: Int? = nil) -> BookRow {
        BookRow(id: id, title: title, author: nil, genre: nil, path: path,
                dateAdded: Date(), playDate: nil, bookType: 0, fileType: 0, pages: pages,
                rating: 0, unseen: false, keywordA: nil, keywordB: nil,
                keywordC: nil, neta: nil, memo: nil)
    }

    /// 既定は「存在するアーカイブ・24 ページ・stat 成功」。個別テストで必要な所だけ差し替える。
    private func deps(probe: @escaping @Sendable (URL) async -> QuickProbe,
                      statFile: @escaping @Sendable (String) -> (Int64?, Double?) = { _ in (4096, 111.0) },
                      fileExists: @escaping @Sendable (String) -> Bool = { _ in true },
                      now: @escaping @Sendable () -> Int64 = { 1_700_000_000 })
    -> QuickIntegrityScanner.Dependencies {
        QuickIntegrityScanner.Dependencies(
            categoryOf: { _ in .archive }, fileExists: fileExists,
            statFile: statFile, probe: probe, now: now)
    }

    @Test("正常な本は ok が記録され pages と file_size が書き戻される(②+④)")
    func okBookPersistsStatusAndBackfills() async throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "a", path: "/lib/a.zip"))

        let report = try await QuickIntegrityScanner.scan(
            database: db, deps: deps(probe: { _ in .enumerated(count: 24, truncated: false) }))

        #expect(report.scanned == 1)
        #expect(report.byStatus[.ok] == 1)
        #expect(report.pagesUpdated == 1)

        let rec = try #require(try db.integrityRecord(bookID: 1))
        #expect(rec.status == .ok)
        #expect(rec.method == .quick)
        #expect(rec.entryCount == 24)
        #expect(rec.fileSize == 4096)
        #expect(rec.checkedAt == 1_700_000_000)

        let updated = try #require(try db.fetchBook(id: 1))
        #expect(updated.pages == 24, "pages が書き戻されていない")
        #expect(updated.fileSize == 4096, "file_size が書き戻されていない")
    }

    @Test("破損本は damaged が記録され pages は書き戻されない")
    func damagedBookDoesNotBackfillPages() async throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "b", path: "/lib/b.zip"))

        let report = try await QuickIntegrityScanner.scan(
            database: db, deps: deps(probe: { _ in .enumerated(count: 13, truncated: true) }))

        #expect(report.byStatus[.damaged] == 1)
        #expect(report.pagesUpdated == 0)
        #expect(try #require(db.integrityRecord(bookID: 1)).status == .damaged)
        #expect(try #require(db.fetchBook(id: 1)).pages == nil, "破損本の pages を確定させてはいけない")
    }

    @Test("ファイル不在は missing が記録され、開こうとしない")
    func missingFileIsRecordedWithoutProbing() async throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "c", path: "/lib/gone.zip"))

        let report = try await QuickIntegrityScanner.scan(
            database: db,
            deps: deps(probe: { _ in
                Issue.record("不在ファイルを開こうとした")
                return .failed(reason: "unreachable")
            },
            statFile: { _ in (nil, nil) },
            fileExists: { _ in false }))

        #expect(report.byStatus[.missing] == 1)
        #expect(try #require(db.integrityRecord(bookID: 1)).status == .missing)
    }

    @Test("pages が入っている本は候補にならない")
    func booksWithPagesAreNotScanned() async throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "d", path: "/lib/d.zip", pages: 30))

        let report = try await QuickIntegrityScanner.scan(
            database: db, deps: deps(probe: { _ in
                Issue.record("走査対象外の本を開いた")
                return .failed(reason: "unreachable")
            }))

        #expect(report.scanned == 0)
    }

    @Test("1 冊が失敗しても残りの走査が続く")
    func failureDoesNotStopScan() async throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "bad", path: "/lib/bad.zip"))
        try db.insertBook(book(id: 2, title: "good", path: "/lib/good.zip"))

        let report = try await QuickIntegrityScanner.scan(
            database: db,
            deps: deps(probe: { url in
                url.path.contains("bad") ? .failed(reason: "boom")
                                         : .enumerated(count: 5, truncated: false)
            }))

        #expect(report.scanned == 2, "1 冊の失敗で走査が止まっている")
        #expect(try #require(db.integrityRecord(bookID: 1)).status == .damaged)
        #expect(try #require(db.integrityRecord(bookID: 2)).status == .ok)
    }

    /// レビュー指摘: 永続化（upsertIntegrity 等）が throw すると走査全体が止まってしまう
    /// 危険が未検証だった。`book_integrity.book_id` は `REFERENCES book(id) ON DELETE CASCADE`
    /// かつ全接続で `PRAGMA foreign_keys = ON` なので、走査中に本が削除されると
    /// upsertIntegrity の INSERT が FK 違反で本当に throw する（31 時間走る G27b では
    /// 現実的に起こりうるシナリオでもある）。
    @Test("永続化が throw しても残りの走査は続き、失敗件数が報告される")
    func persistenceFailureDoesNotStopScan() async throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "gone-mid-scan", path: "/lib/e.zip"))
        try db.insertBook(book(id: 2, title: "f", path: "/lib/f.zip"))

        let report = try await QuickIntegrityScanner.scan(
            database: db,
            deps: deps(probe: { url in
                if url.path.contains("e.zip") {
                    // 走査中に本が削除された状況を再現する。
                    try? db.deleteBook(id: 1)
                }
                return .enumerated(count: 5, truncated: false)
            }))

        #expect(report.scanned == 2, "永続化の失敗で走査が止まっている")
        #expect(report.persistenceFailures == 1, "FK 違反による永続化失敗が検知されていない")
        #expect(try db.integrityRecord(bookID: 1) == nil,
                "削除された本の永続化が成功したことになっている")
        #expect(try #require(try db.integrityRecord(bookID: 2)).status == .ok,
                "1 冊目の失敗後、2 冊目が最後まで走査されていない")
    }

    /// `var` を async クロージャの中で書き換えると Swift 6 の並行性チェックに
    /// 引っかかりうるため、`@unchecked Sendable` の収集用クラスに寄せる
    /// (brief 記載の回避策。scan の signature/挙動は変えない)。
    private final class Collector: @unchecked Sendable {
        var seen: [Int] = []
        var totals: [Int] = []
    }

    @Test("進捗が 1 冊ごとに報告される")
    func progressIsReportedPerBook() async throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "a", path: "/lib/a.zip"))
        try db.insertBook(book(id: 2, title: "b", path: "/lib/b.zip"))

        let collector = Collector()
        _ = try await QuickIntegrityScanner.scan(
            database: db, deps: deps(probe: { _ in .enumerated(count: 1, truncated: false) })
        ) { done, total in
            collector.seen.append(done)
            collector.totals.append(total)
        }
        #expect(collector.seen == [1, 2])
        #expect(collector.totals == [2, 2])
    }

    @Test("2 回走らせると 1 回目の結果が prev に退避される")
    func rescanCarriesPreviousGeneration() async throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "a", path: "/lib/a.zip"))

        // 1 回目: 画像 0 枚(empty) → pages=0 が確定するので 2 回目も候補に残る。
        _ = try await QuickIntegrityScanner.scan(
            database: db, deps: deps(probe: { _ in .enumerated(count: 0, truncated: false) }))
        #expect(try #require(db.integrityRecord(bookID: 1)).status == .empty)

        // 2 回目: 破損に変化。
        _ = try await QuickIntegrityScanner.scan(
            database: db, deps: deps(probe: { _ in .failed(reason: "boom") }))

        let rec = try #require(try db.integrityRecord(bookID: 1))
        #expect(rec.status == .damaged)
        #expect(rec.prevStatus == .empty)
    }

    // MARK: - Smoke fix: probeFailureReason は badEntries に path を書かない

    private static let leakyURL = URL(fileURLWithPath: "/Volumes/ecomic/(成年コミック) [雑誌] 2015年11月号.zip")

    /// G27a task 8 (Codex High #2): 旧テストは "Unrecognized archive format"（path を含まない
    /// たった 1 つのモード）だけを見て「塞がった」と判断していた。それが今回の見落としの原因
    /// だったので、ここでは `classifyOpenFailure` が固定分類名だけを返すことを直接検証する。
    @Test("archiveUnreadable は固定の分類名になり、reason 原文も URL も含めない")
    func archiveUnreadableReasonExcludesURL() {
        let error = ArchiveAdapterError.archiveUnreadable(Self.leakyURL, reason: "Unrecognized archive format")
        let reason = QuickIntegrityScanner.probeFailureReason(for: error)

        #expect(reason == "archive unreadable: unrecognized archive format")
        #expect(!reason.contains("/Volumes"))
        #expect(!reason.contains("file://"))
        #expect(!reason.contains(Self.leakyURL.path))
    }

    /// 実測（controller, 2026-08-06）: 権限拒否・ファイル不在は `Failed to open '<絶対パス>'`
    /// という reason 文字列自体に絶対パスを埋め込む。この 2 モードが今回の実漏洩箇所。
    @Test("permission-denied 相当の reason 文字列からパスが漏れない",
          arguments: [
            "Failed to open '/tmp/g27a-errs/noperm.zip'",
            "Failed to open '/tmp/g27a-errs/missing.zip'",
            "Failed to open '/Volumes/ecomic/(成年コミック) [雑誌] 2015年11月号.zip'",
          ])
    func failedToOpenReasonExcludesPath(rawReason: String) {
        let error = ArchiveAdapterError.archiveUnreadable(Self.leakyURL, reason: rawReason)
        let reason = QuickIntegrityScanner.probeFailureReason(for: error)

        #expect(reason == "archive unreadable: could not open archive")
        #expect(!reason.hasPrefix("/"))
        #expect(!reason.contains("/tmp"))
        #expect(!reason.contains("/Volumes"))
        #expect(!reason.contains("file://"))
        #expect(!reason.contains("'"))
    }

    /// header-read ループ内での破綻（`.enumerationFailed`）は、libarchive の生文字列が
    /// 破損パターンごとに全く異なる（"Damaged Zip archive" 等、固定の接頭辞を持たない）ため、
    /// reason の中身に関わらず常に固定文言だけを返すこと。
    @Test(".enumerationFailed は reason の中身に関わらず固定文言になり、URL も含めない",
          arguments: [
            "Damaged Zip archive",
            "(null)",
            "read header failed",
            "Failed to open '/should/not/leak/even/here.zip'",
          ])
    func enumerationFailedReasonIsAlwaysFixed(rawReason: String) {
        let error = ArchiveAdapterError.enumerationFailed(Self.leakyURL, reason: rawReason)
        let reason = QuickIntegrityScanner.probeFailureReason(for: error)

        #expect(reason == "archive read truncated")
        #expect(!reason.contains("/Volumes"))
        #expect(!reason.contains("file://"))
        #expect(!reason.contains("/should/not/leak"))
    }

    @Test("noImageEntry は固定メッセージになり、URL を含めない")
    func noImageEntryReasonExcludesURL() {
        let error = ArchiveAdapterError.noImageEntry(Self.leakyURL)
        let reason = QuickIntegrityScanner.probeFailureReason(for: error)

        #expect(reason == "no image entry found")
        #expect(!reason.contains("/Volumes"))
        #expect(!reason.contains("file://"))
        #expect(!reason.contains(Self.leakyURL.path))
    }

    /// 想定外の libarchive メッセージ（表に無いもの）も、原文を通さず固定の「それ以外」バケットへ。
    @Test("未知の archiveUnreadable reason はそれ以外バケットになり、原文を含めない")
    func unrecognizedReasonFallsIntoCatchAllBucket() {
        let error = ArchiveAdapterError.archiveUnreadable(
            Self.leakyURL, reason: "some brand new libarchive message /Volumes/leak.zip")
        let reason = QuickIntegrityScanner.probeFailureReason(for: error)

        #expect(reason == "archive unreadable: unexpected archive read failure")
        #expect(!reason.contains("/Volumes"))
    }

    /// 任意の Error（`ArchiveAdapterError` 以外）は `String(describing:)` を経由させない ――
    /// path を埋め込んだカスタム description を持つ Error が来ても、型名だけの bounded な
    /// 文字列に留まることを確認する。
    @Test("未知のエラー型は String(describing:) にフォールバックせず型名のみ返す")
    func unknownErrorTypeDoesNotLeakDescription() {
        struct LeakyError: Error, CustomStringConvertible {
            var description: String { "failed reading file:///Volumes/ecomic/secret.zip" }
        }

        let reason = QuickIntegrityScanner.probeFailureReason(for: LeakyError())

        #expect(!reason.contains("/Volumes"))
        #expect(!reason.contains("file://"))
        #expect(reason.contains("LeakyError"))
    }

    @Test("probe(.failed) 経由の scan でも badEntries に URL が残らないことを end-to-end で確認する")
    func scanBadEntriesNeverContainsURL() async throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "leaky", path: "/lib/leaky.zip"))

        let error = ArchiveAdapterError.archiveUnreadable(Self.leakyURL, reason: "Unrecognized archive format")
        _ = try await QuickIntegrityScanner.scan(
            database: db,
            deps: deps(probe: { _ in .failed(reason: QuickIntegrityScanner.probeFailureReason(for: error)) }))

        let rec = try #require(try db.integrityRecord(bookID: 1))
        for entry in rec.badEntries {
            #expect(!entry.contains("/Volumes"))
            #expect(!entry.contains("file://"))
        }
    }

    // MARK: - G27a task 8: 実ファイルを libarchive に実際に処理させ、全 6 失敗モードを網羅する
    //
    // brief の実測表（controller が libarchive を直叩きして確認）にある 6 モード全てを、合成した
    // 実ファイルで再現し、実際の `LibarchiveCoverExtractor.listImageEntries` → `probeFailureReason`
    // を通す。「1 ケースだけ見て塞がったと判断した」のが前回の見落としの原因だったため、
    // ここでは synthetic な ArchiveAdapterError ではなく実ファイル処理で検証する。

    private static func writeTemp(_ data: Data, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("g27a-t8-\(UUID().uuidString)-\(name)")
        try data.write(to: url)
        return url
    }

    /// 無圧縮(store)の最小 zip を組み立てる（DamagedArchiveTests と同じ手法。テスト用に複製）。
    private static func makeStoredZip(_ entries: [(String, Data)]) -> Data {
        var out = Data()
        var central = Data()
        var offsets: [Int] = []
        func u16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

        for (name, body) in entries {
            offsets.append(out.count)
            let nameBytes = Data(name.utf8)
            out.append(u32(0x0403_4b50)); out.append(u16(10)); out.append(u16(0x0800))
            out.append(u16(0)); out.append(u16(0)); out.append(u16(0))
            out.append(u32(0)); out.append(u32(UInt32(body.count))); out.append(u32(UInt32(body.count)))
            out.append(u16(UInt16(nameBytes.count))); out.append(u16(0))
            out.append(nameBytes); out.append(body)
        }
        for (name, body) in entries {
            let nameBytes = Data(name.utf8)
            central.append(u32(0x0201_4b50))
            central.append(u16(20)); central.append(u16(10))
            central.append(u16(0x0800)); central.append(u16(0))
            central.append(u16(0)); central.append(u16(0))
            central.append(u32(0)); central.append(u32(UInt32(body.count))); central.append(u32(UInt32(body.count)))
            central.append(u16(UInt16(nameBytes.count)))
            central.append(u16(0)); central.append(u16(0))
            central.append(u16(0)); central.append(u16(0))
            central.append(u32(0)); central.append(u32(UInt32(offsets[entries.firstIndex { $0.0 == name }!])))
            central.append(nameBytes)
        }
        let centralOffset = out.count
        out.append(central)
        out.append(u32(0x0605_4b50))
        out.append(u16(0)); out.append(u16(0))
        out.append(u16(UInt16(entries.count))); out.append(u16(UInt16(entries.count)))
        out.append(u32(UInt32(central.count))); out.append(u32(UInt32(centralOffset)))
        out.append(u16(0))
        return out
    }

    private static let tinyPNG = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    ])

    /// EOCD/central directory は無傷のまま、先頭エントリの local header 署名だけを壊す。
    /// libarchive は EOCD から zip と認識する（open は成功）が、1 件目の header 読み取りで
    /// いきなり ARCHIVE_FATAL になる ―― `names.isEmpty` のまま `.enumerationFailed` を踏む。
    private static func makeZipDamagedAtFirstEntry() -> Data {
        var zip = makeStoredZip([("1.png", tinyPNG), ("2.png", tinyPNG)])
        zip[2] = 0xFF   // local header signature (offset 0) の 3 バイト目を破壊
        return zip
    }

    /// 実ファイルを `LibarchiveCoverExtractor` に処理させ、`probeFailureReason` の出力が
    /// - 絶対パス・`file://` を一切含まない
    /// - 期待した固定分類名と一致する
    /// ことを確認する共通ヘルパ。
    private func expectNoLeak(_ url: URL, expectedReason: String,
                              sourceLocation: SourceLocation = #_sourceLocation) async throws {
        do {
            _ = try await LibarchiveCoverExtractor().listImageEntries(in: url)
            Issue.record("期待した failure が throw されなかった", sourceLocation: sourceLocation)
        } catch {
            let reason = QuickIntegrityScanner.probeFailureReason(for: error)
            #expect(reason == expectedReason, sourceLocation: sourceLocation)
            #expect(!reason.contains(url.path), sourceLocation: sourceLocation)
            #expect(!reason.hasPrefix("/"), sourceLocation: sourceLocation)
            #expect(!reason.contains("file://"), sourceLocation: sourceLocation)
            #expect(!reason.contains(FileManager.default.temporaryDirectory.path),
                     sourceLocation: sourceLocation)
        }
    }

    @Test("実測モード1: 中身がアーカイブでない → unrecognized archive format・path なし")
    func realFixtureNotAnArchive() async throws {
        let url = try Self.writeTemp(Data("this is not an archive at all".utf8), name: "notarchive.zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try await expectNoLeak(url, expectedReason: "archive unreadable: unrecognized archive format")
    }

    @Test("実測モード2: ランダムバイト列 → unrecognized archive format・path なし")
    func realFixtureRandomBytes() async throws {
        var bytes = [UInt8](repeating: 0, count: 4096)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        let url = try Self.writeTemp(Data(bytes), name: "random.zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try await expectNoLeak(url, expectedReason: "archive unreadable: unrecognized archive format")
    }

    @Test("実測モード3: 0 バイト → unrecognized archive format・path なし")
    func realFixtureEmptyFile() async throws {
        let url = try Self.writeTemp(Data(), name: "empty.zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try await expectNoLeak(url, expectedReason: "archive unreadable: unrecognized archive format")
    }

    @Test("実測モード4: 途中で切れている（先頭 header 破損）→ archive read truncated・path なし")
    func realFixtureTruncatedArchive() async throws {
        let url = try Self.writeTemp(Self.makeZipDamagedAtFirstEntry(), name: "truncated.zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try await expectNoLeak(url, expectedReason: "archive read truncated")
    }

    @Test("実測モード5: 権限拒否 → could not open archive・path なし")
    func realFixturePermissionDenied() async throws {
        let url = try Self.writeTemp(Data([1, 2, 3, 4]), name: "noperm.zip")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        // root 権限で実行されていると chmod 000 でも読めてしまい、このモードを再現できない
        // （root は POSIX パーミッションを無視する）。その場合はこのテストの対象外として skip する。
        guard !FileManager.default.isReadableFile(atPath: url.path) else { return }
        try await expectNoLeak(url, expectedReason: "archive unreadable: could not open archive")
    }

    @Test("実測モード6: ファイル不在 → could not open archive・path なし")
    func realFixtureMissingFile() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("g27a-t8-\(UUID().uuidString)-does-not-exist.zip")
        try await expectNoLeak(url, expectedReason: "archive unreadable: could not open archive")
    }
}
