// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
@testable import LibraryStore
import ArchiveAdapter

@Suite("full CRC integrity scan (G27b)")
struct FullIntegrityScannerTests {
    private func setupDB() throws -> Database {
        let db = try Database.openInMemory()
        try db.migrate()
        return db
    }

    private func book(id: Int, title: String, path: String) -> BookRow {
        BookRow(id: id, title: title, author: nil, genre: nil, path: path,
                dateAdded: Date(), playDate: nil, bookType: 0, fileType: 0, pages: nil,
                rating: 0, unseen: false, keywordA: nil, keywordB: nil,
                keywordC: nil, neta: nil, memo: nil)
    }

    /// 既定は「存在するアーカイブ・stat 成功・categoryOf は常に .archive」。
    /// 個別テストで必要な所だけ差し替える（QuickIntegrityScannerTests と同じ流儀）。
    private func deps(
        verify: @escaping @Sendable (URL, @escaping @Sendable () async -> Bool) async throws -> ArchiveVerifyResult,
        categoryOf: @escaping @Sendable (String) -> BookCategory = { _ in .archive },
        statFile: @escaping @Sendable (String) -> (Int64?, Double?) = { _ in (4096, 111.0) },
        fileExists: @escaping @Sendable (String) -> Bool = { _ in true },
        now: @escaping @Sendable () -> Int64 = { 1_700_000_000 },
        libraryReachable: @escaping @Sendable () -> Bool = { true }
    ) -> FullIntegrityScanner.Dependencies {
        FullIntegrityScanner.Dependencies(
            categoryOf: categoryOf, fileExists: fileExists,
            statFile: statFile, verify: verify, now: now,
            libraryReachable: libraryReachable)
    }

    // MARK: - 1. 正常な本

    @Test("正常な本は ok が記録され pages と file_size が書き戻される")
    func okBookPersistsStatusAndBackfills() async throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "a", path: "/lib/a.zip"))

        let report = try await FullIntegrityScanner.scan(
            database: db,
            deps: deps(verify: { _, _ in
                ArchiveVerifyResult(entryCount: 24, imageCount: 24, badEntries: [], truncated: false)
            }))

        #expect(report.scanned == 1)
        #expect(report.byStatus[.ok] == 1)
        #expect(report.cancelled == false)
        #expect(report.persistenceFailures == 0)

        let rec = try #require(try db.integrityRecord(bookID: 1))
        #expect(rec.status == .ok)
        #expect(rec.method == .full)
        #expect(rec.entryCount == 24)
        #expect(rec.fileSize == 4096)
        #expect(rec.checkedAt == 1_700_000_000)

        let updated = try #require(try db.fetchBook(id: 1))
        #expect(updated.pages == 24, "pages (imageCount) が書き戻されていない")
        #expect(updated.fileSize == 4096, "file_size が書き戻されていない")
    }

    // MARK: - 2. CRC 不良

    @Test("CRC 不良は damaged が記録され pages は書き戻されず badEntries に不良エントリ名が入る")
    func crcFailureDoesNotBackfillPagesAndRecordsBadEntries() async throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "b", path: "/lib/b.zip"))

        let report = try await FullIntegrityScanner.scan(
            database: db,
            deps: deps(verify: { _, _ in
                ArchiveVerifyResult(entryCount: 24, imageCount: 24,
                                    badEntries: ["012.jpg"], truncated: false)
            }))

        #expect(report.byStatus[.damaged] == 1)

        let rec = try #require(try db.integrityRecord(bookID: 1))
        #expect(rec.status == .damaged)
        #expect(rec.badEntries == ["012.jpg"])

        #expect(try #require(db.fetchBook(id: 1)).pages == nil, "破損本の pages を確定させてはいけない")
    }

    @Test("構造破綻で truncated になった場合も damaged が記録される（中断ではない）")
    func structuralTruncationIsRecordedAsDamaged() async throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "t", path: "/lib/t.zip"))

        let report = try await FullIntegrityScanner.scan(
            database: db,
            deps: deps(verify: { _, _ in
                ArchiveVerifyResult(entryCount: 3, imageCount: 3, badEntries: [], truncated: true)
            }),
            isCancelled: { false })

        #expect(report.byStatus[.damaged] == 1)
        #expect(report.cancelled == false)
        let rec = try #require(try db.integrityRecord(bookID: 1))
        #expect(rec.status == .damaged)
        #expect(rec.badEntries == ["archive read truncated"])
    }

    @Test("verify が throw した場合は damaged が記録され、reason に絶対パスが含まれない")
    func verifyThrowingIsNormalizedIntoDamaged() async throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "leaky", path: "/lib/leaky.zip"))
        let leakyURL = URL(fileURLWithPath: "/Volumes/ecomic/leaky.zip")

        let report = try await FullIntegrityScanner.scan(
            database: db,
            deps: deps(verify: { _, _ in
                throw ArchiveAdapterError.archiveUnreadable(leakyURL, reason: "Failed to open '/Volumes/ecomic/leaky.zip'")
            }))

        #expect(report.byStatus[.damaged] == 1)
        let rec = try #require(try db.integrityRecord(bookID: 1))
        #expect(rec.status == .damaged)
        #expect(rec.badEntries == ["archive unreadable: could not open archive"])
        for entry in rec.badEntries {
            #expect(!entry.contains("/Volumes"))
            #expect(!entry.contains("file://"))
        }
    }

    // MARK: - missing / unsupported

    @Test("ファイル不在は missing が記録され、verify を呼ばない")
    func missingFileIsRecordedWithoutVerifying() async throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "gone", path: "/lib/gone.zip"))

        let report = try await FullIntegrityScanner.scan(
            database: db,
            deps: deps(verify: { _, _ in
                Issue.record("不在ファイルを verify しようとした")
                return ArchiveVerifyResult(entryCount: 0, imageCount: 0, badEntries: [], truncated: false)
            },
            fileExists: { _ in false }))

        #expect(report.byStatus[.missing] == 1)
        #expect(try #require(db.integrityRecord(bookID: 1)).status == .missing)
    }

    @Test("アーカイブ以外(video)は unsupported が記録され、verify を呼ばない")
    func nonArchiveCategoryIsUnsupportedWithoutVerifying() async throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "movie", path: "/lib/movie.mp4"))

        let report = try await FullIntegrityScanner.scan(
            database: db,
            deps: deps(verify: { _, _ in
                Issue.record("video を verify しようとした")
                return ArchiveVerifyResult(entryCount: 0, imageCount: 0, badEntries: [], truncated: false)
            },
            categoryOf: { _ in .video }))

        #expect(report.byStatus[.unsupported] == 1)
        #expect(try #require(db.integrityRecord(bookID: 1)).status == .unsupported)
        #expect(try #require(db.integrityRecord(bookID: 1)).method == .full,
                "unsupported も method='full' で書かないと .uncheckedOnly から外れない")
    }

    // MARK: - レビュー修正: 非アーカイブを無条件 unsupported にすると既知の破損が消える

    /// Task 2 レビュー（Important）の再現テスト。G27a の quick スキャンは 0 バイト画像を
    /// `damaged` と記録する（`QuickIntegrityCheck.swift` の意図的な fail-safe）。この本は
    /// `method='full'` の行を持たないため `.uncheckedOnly` の候補に普通に入る ―― full スキャンが
    /// 非アーカイブを無条件で `unsupported` に書き換えると、CRC を見てもいないのに破損が
    /// 「検査対象外」として一覧・件数から消える。修正後は `QuickIntegrityCheck.classify` と
    /// 同じ判定（サイズ 0/不明 → damaged）を通すため `damaged` のまま残るはず。
    @Test("0 バイト画像は damaged のまま(.uncheckedOnly で消えない・回帰防止)")
    func zeroByteImageStaysDamagedUnderUncheckedOnly() async throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "zero-byte", path: "/lib/zero.jpg"))
        // G27a の quick スキャン相当: 0 バイト画像を damaged として先に記録しておく。
        try db.upsertIntegrity(IntegrityRecord(
            bookID: 1, status: .damaged, method: .quick, checkedAt: 100,
            fileSize: 0, fileMtime: nil, entryCount: nil,
            badEntries: ["image file size is zero or unknown"],
            prevStatus: nil, prevCheckedAt: nil))

        let report = try await FullIntegrityScanner.scan(
            database: db, mode: .uncheckedOnly,
            deps: deps(verify: { _, _ in
                Issue.record("image を verify しようとした")
                return ArchiveVerifyResult(entryCount: 0, imageCount: 0, badEntries: [], truncated: false)
            },
            categoryOf: { _ in .image },
            statFile: { _ in (0, 111.0) }))

        #expect(report.byStatus[.damaged] == 1, "0 バイト画像が unsupported に化けている")
        let rec = try #require(try db.integrityRecord(bookID: 1))
        #expect(rec.status == .damaged, "既知の破損が unsupported で消されている")
        #expect(rec.method == .full)
        #expect(try #require(db.fetchBook(id: 1)).pages == nil,
                "破損した画像に pages を確定させてはいけない")
    }

    /// 同じ再現を `.damagedOnly` でも確認する ―― こちらも brief どおり method を問わず
    /// `status='damaged'` の本を候補にするため、同じ本が同様に消えてはいけない。
    @Test("0 バイト画像は damaged のまま(.damagedOnly で消えない・回帰防止)")
    func zeroByteImageStaysDamagedUnderDamagedOnly() async throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "zero-byte", path: "/lib/zero.jpg"))
        try db.upsertIntegrity(IntegrityRecord(
            bookID: 1, status: .damaged, method: .quick, checkedAt: 100,
            fileSize: 0, fileMtime: nil, entryCount: nil,
            badEntries: ["image file size is zero or unknown"],
            prevStatus: nil, prevCheckedAt: nil))

        let report = try await FullIntegrityScanner.scan(
            database: db, mode: .damagedOnly,
            deps: deps(verify: { _, _ in
                Issue.record("image を verify しようとした")
                return ArchiveVerifyResult(entryCount: 0, imageCount: 0, badEntries: [], truncated: false)
            },
            categoryOf: { _ in .image },
            statFile: { _ in (0, 111.0) }))

        #expect(report.byStatus[.damaged] == 1)
        let rec = try #require(try db.integrityRecord(bookID: 1))
        #expect(rec.status == .damaged, "既知の破損が unsupported で消されている")
        #expect(rec.method == .full)
    }

    /// 健全な単独画像（サイズ > 0）は ok・pages=1 が full スキャンでも成立すること
    /// （damaged 側だけでなく ok 側の判定も classify() 経由で正しく動くことの確認）。
    @Test("サイズが確認できる単独画像は full スキャンでも ok・pages=1 になる")
    func nonZeroByteImageIsOkUnderFullScan() async throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "fine", path: "/lib/fine.jpg"))

        let report = try await FullIntegrityScanner.scan(
            database: db,
            deps: deps(verify: { _, _ in
                Issue.record("image を verify しようとした")
                return ArchiveVerifyResult(entryCount: 0, imageCount: 0, badEntries: [], truncated: false)
            },
            categoryOf: { _ in .image },
            statFile: { _ in (2048, 111.0) }))

        #expect(report.byStatus[.ok] == 1)
        let rec = try #require(try db.integrityRecord(bookID: 1))
        #expect(rec.status == .ok)
        #expect(try #require(db.fetchBook(id: 1)).pages == 1)
    }

    // MARK: - Codex 事前レビュー Blocker1: フォルダは既存の判定を上書きしない

    /// フォルダの実体検証は quick スキャンの担当で、full スキャンには手段（probe）が無い。
    /// quick スキャンが列挙失敗/打ち切りで damaged と判定済みのフォルダを、full スキャンが
    /// 無条件 unsupported で上書きしてしまうと「known damage が silently erase される」――
    /// 本ブランチが守る不変条件そのものに反する。修正後は既存行があれば full スキャンは
    /// 一切書かない（.uncheckedOnly 経路）。
    @Test("既存行がある damaged フォルダは .uncheckedOnly でも unsupported に上書きされない")
    func damagedFolderWithExistingRowSurvivesUncheckedOnlyFullScan() async throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "folder-book", path: "/lib/folder-book"))
        // G27a の quick スキャン相当: 列挙失敗で damaged と判定済み。
        try db.upsertIntegrity(IntegrityRecord(
            bookID: 1, status: .damaged, method: .quick, checkedAt: 100,
            fileSize: nil, fileMtime: nil, entryCount: nil,
            badEntries: ["enumeration truncated"],
            prevStatus: nil, prevCheckedAt: nil))

        let report = try await FullIntegrityScanner.scan(
            database: db, mode: .uncheckedOnly,
            deps: deps(verify: { _, _ in
                Issue.record("フォルダを verify しようとした（フォルダに CRC 検証は無い）")
                return ArchiveVerifyResult(entryCount: 0, imageCount: 0, badEntries: [], truncated: false)
            },
            categoryOf: { _ in .folder }))

        let rec = try #require(try db.integrityRecord(bookID: 1))
        #expect(rec.status == .damaged, "quick スキャンの damaged を full スキャンが上書きしている")
        #expect(rec.method == .quick, "書き込みが一切起きていないなら method も quick のまま")
        #expect(rec.checkedAt == 100, "checked_at が更新されている＝何か書いてしまっている")
        #expect(report.byStatus[.unsupported] == nil, "この本を unsupported として計上してはいけない")
    }

    /// 同じ再現を `.damagedOnly` でも確認する ―― こちらは book_integrity を JOIN して直接
    /// status='damaged' を候補にするため、必ずこのフォルダが選ばれる。
    @Test("既存行がある damaged フォルダは .damagedOnly でも unsupported に上書きされない")
    func damagedFolderWithExistingRowSurvivesDamagedOnlyFullScan() async throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "folder-book", path: "/lib/folder-book"))
        try db.upsertIntegrity(IntegrityRecord(
            bookID: 1, status: .damaged, method: .quick, checkedAt: 100,
            fileSize: nil, fileMtime: nil, entryCount: nil,
            badEntries: ["enumeration truncated"],
            prevStatus: nil, prevCheckedAt: nil))

        let report = try await FullIntegrityScanner.scan(
            database: db, mode: .damagedOnly,
            deps: deps(verify: { _, _ in
                Issue.record("フォルダを verify しようとした（フォルダに CRC 検証は無い）")
                return ArchiveVerifyResult(entryCount: 0, imageCount: 0, badEntries: [], truncated: false)
            },
            categoryOf: { _ in .folder }))

        let rec = try #require(try db.integrityRecord(bookID: 1))
        #expect(rec.status == .damaged, "quick スキャンの damaged を full スキャンが上書きしている")
        #expect(rec.method == .quick)
        #expect(rec.checkedAt == 100)
        #expect(report.byStatus[.unsupported] == nil)
    }

    /// 既存行が無いフォルダ（初回走査）は、従来どおり unsupported を新規に書いてよい ――
    /// そうしないと .uncheckedOnly の候補から永久に外れない（brief の要件）。
    @Test("既存行が無いフォルダは unsupported が新規に記録される")
    func folderWithoutExistingRowGetsUnsupported() async throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "new-folder-book", path: "/lib/new-folder-book"))

        let report = try await FullIntegrityScanner.scan(
            database: db, mode: .uncheckedOnly,
            deps: deps(verify: { _, _ in
                Issue.record("フォルダを verify しようとした（フォルダに CRC 検証は無い）")
                return ArchiveVerifyResult(entryCount: 0, imageCount: 0, badEntries: [], truncated: false)
            },
            categoryOf: { _ in .folder }))

        #expect(report.byStatus[.unsupported] == 1)
        let rec = try #require(try db.integrityRecord(bookID: 1))
        #expect(rec.status == .unsupported)
        #expect(rec.method == .full, "既存行が無い場合は method='full' で書かないと候補から外れない")
    }

    // MARK: - 3. 中断

    /// `var` を async クロージャの中で書き換えると Swift 6 の並行性チェックに
    /// 引っかかりうるため、`@unchecked Sendable` の収集用クラスに寄せる（Quick と同じ回避策）。
    private final class Counter: @unchecked Sendable {
        var value = 0
    }

    @Test("中断すると、それまでの結果は残り cancelled が true になる")
    func cancellationStopsScanButKeepsPriorResults() async throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "a", path: "/lib/a.zip"))
        try db.insertBook(book(id: 2, title: "b", path: "/lib/b.zip"))
        try db.insertBook(book(id: 3, title: "c", path: "/lib/c.zip"))

        let counter = Counter()
        let report = try await FullIntegrityScanner.scan(
            database: db,
            deps: deps(verify: { _, _ in
                ArchiveVerifyResult(entryCount: 3, imageCount: 3, badEntries: [], truncated: false)
            }),
            isCancelled: {
                counter.value += 1
                return counter.value > 1   // 1 冊目の開始前チェックだけ false
            })

        #expect(report.cancelled == true)
        #expect(report.scanned == 1, "中断後の本まで処理してしまっている")
        #expect(try db.integrityRecord(bookID: 1) != nil, "中断前に処理した本の結果が残っていない")
        #expect(try db.integrityRecord(bookID: 2) == nil, "中断後の本まで永続化してしまっている")
        #expect(try db.integrityRecord(bookID: 3) == nil)
    }

    @Test("冊の途中で中断された場合、その本は永続化されずに走査が終わる")
    func midBookCancellationDoesNotPersistThatBook() async throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "a", path: "/lib/a.zip"))
        try db.insertBook(book(id: 2, title: "b", path: "/lib/b.zip"))

        // 1 冊目: 開始前チェックは false（処理される）。verify 内で中断が発生し
        // truncated=true を返す ―― ここで isCancelled を再確認すると true になる、
        // という「エントリ単位の中断」を模す。
        let isCancelledFlag = Counter()
        let report = try await FullIntegrityScanner.scan(
            database: db,
            deps: deps(verify: { _, _ in
                isCancelledFlag.value = 1   // verify の内部で中断が起きたことにする
                return ArchiveVerifyResult(entryCount: 1, imageCount: 0, badEntries: [], truncated: true)
            }),
            isCancelled: { isCancelledFlag.value == 1 })

        #expect(report.cancelled == true)
        #expect(report.scanned == 0, "中断された本を scanned に数えてしまっている")
        #expect(try db.integrityRecord(bookID: 1) == nil,
                "中断された本を永続化すると、method='full' 行ができて再開できなくなる")
        #expect(try db.integrityRecord(bookID: 2) == nil)
    }

    // MARK: - 4. 永続化の失敗

    @Test("永続化が throw しても残りの走査は続き、失敗件数が報告される")
    func persistenceFailureDoesNotStopScan() async throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "gone-mid-scan", path: "/lib/e.zip"))
        try db.insertBook(book(id: 2, title: "f", path: "/lib/f.zip"))

        let report = try await FullIntegrityScanner.scan(
            database: db,
            deps: deps(verify: { url, _ in
                if url.path.contains("e.zip") {
                    // 走査中に本が削除された状況を再現する（FK 違反で upsertIntegrity が throw する）。
                    try? db.deleteBook(id: 1)
                }
                return ArchiveVerifyResult(entryCount: 5, imageCount: 5, badEntries: [], truncated: false)
            }))

        #expect(report.scanned == 2, "永続化の失敗で走査が止まっている")
        #expect(report.persistenceFailures == 1, "FK 違反による永続化失敗が検知されていない")
        #expect(try db.integrityRecord(bookID: 1) == nil,
                "削除された本の永続化が成功したことになっている")
        #expect(try #require(try db.integrityRecord(bookID: 2)).status == .ok,
                "1 冊目の失敗後、2 冊目が最後まで走査されていない")
    }

    // MARK: - G27b 最終レビュー Fix3: ライブラリが走査中に閉じられた場合は loop-fatal

    @Test("ライブラリが走査中に閉じられると、以降の全冊を空回りせず中断で終える")
    func libraryClosedMidScanStopsAsCancelledInsteadOfLoopingFailures() async throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "a", path: "/lib/a.zip"))
        try db.insertBook(book(id: 2, title: "b", path: "/lib/b.zip"))
        try db.insertBook(book(id: 3, title: "c", path: "/lib/c.zip"))

        // 1 冊目の verify の最中に「ユーザーがライブラリを閉じた」を模す（db.close() で
        // queue が nil になり、以後の upsertIntegrity は DatabaseError.libraryClosed を throw する）。
        let report = try await FullIntegrityScanner.scan(
            database: db,
            deps: deps(verify: { url, _ in
                if url.path.contains("a.zip") { db.close() }
                return ArchiveVerifyResult(entryCount: 1, imageCount: 1, badEntries: [], truncated: false)
            }))

        #expect(report.cancelled == true, "永続化失敗の連続ではなく中断として扱われるべき")
        #expect(report.persistenceFailures == 0,
                "libraryClosed は per-book failure に計上してはいけない（無限に近い空回りの温床）")
        // 2, 3 冊目は 1 冊目の close 直後に打ち切られ、一切試みられていないこと。
        #expect(try db.integrityRecord(bookID: 2) == nil)
        #expect(try db.integrityRecord(bookID: 3) == nil)
    }

    // MARK: - G27b 最終レビュー Fix5: ボリューム不到達時は missing を書かずスキップする

    @Test("ボリュームが到達不能な間の !exists は missing を書かずスキップする")
    func volumeUnreachableSkipsWithoutOverwritingExistingStatus() async throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "was-damaged", path: "/lib/a.zip"))
        try db.insertBook(book(id: 2, title: "was-ok", path: "/lib/b.zip"))
        // 既存の判定（劣化検出の唯一の証跡を含む）を先に用意しておく。`upsertIntegrity` は
        // 渡した record の prevStatus を使わず既存行から自分で退避するため、劣化の証跡
        // （prev_status='ok'）を作るには他のテストと同じく 2 段階（ok→damaged）で積む。
        try db.upsertIntegrity(IntegrityRecord(
            bookID: 1, status: .ok, method: .full, checkedAt: 50,
            fileSize: nil, fileMtime: nil, entryCount: nil, badEntries: [],
            prevStatus: nil, prevCheckedAt: nil))
        try db.upsertIntegrity(IntegrityRecord(
            bookID: 1, status: .damaged, method: .full, checkedAt: 100,
            fileSize: nil, fileMtime: nil, entryCount: nil, badEntries: ["x"],
            prevStatus: nil, prevCheckedAt: nil))
        try db.upsertIntegrity(IntegrityRecord(
            bookID: 2, status: .ok, method: .full, checkedAt: 100,
            fileSize: nil, fileMtime: nil, entryCount: nil, badEntries: [],
            prevStatus: nil, prevCheckedAt: nil))

        let report = try await FullIntegrityScanner.scan(
            database: db, mode: .all,
            deps: deps(verify: { _, _ in
                Issue.record("ボリューム不到達時に verify を呼ぼうとした")
                return ArchiveVerifyResult(entryCount: 0, imageCount: 0, badEntries: [], truncated: false)
            },
            fileExists: { _ in false },       // NAS が寝ていて全冊 stat 失敗を模す
            libraryReachable: { false }))      // バンドル自体も到達不能

        #expect(report.volumeUnavailableSkips == 2)
        #expect(report.scanned == 0, "スキップした本は scanned に数えてはいけない")
        #expect(report.byStatus[.missing] == nil, "missing を書いてはいけない")

        // 既存の判定（劣化の証跡含む）が一切変更されていないこと。
        let rec1 = try #require(try db.integrityRecord(bookID: 1))
        #expect(rec1.status == .damaged)
        #expect(rec1.isDegraded, "ボリューム不到達での再走査で劣化の証跡が消えてはいけない")
        let rec2 = try #require(try db.integrityRecord(bookID: 2))
        #expect(rec2.status == .ok)
    }

    @Test("ライブラリ自体が到達可能なら、消えた本は従来どおり missing になる")
    func trulyMissingBookIsStillRecordedWhenLibraryReachable() async throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "really-gone", path: "/lib/gone.zip"))

        let report = try await FullIntegrityScanner.scan(
            database: db,
            deps: deps(verify: { _, _ in
                Issue.record("不在ファイルを verify しようとした")
                return ArchiveVerifyResult(entryCount: 0, imageCount: 0, badEntries: [], truncated: false)
            },
            fileExists: { _ in false },
            libraryReachable: { true }))   // ライブラリ自体は健在＝本当にこの 1 冊が消えた

        #expect(report.volumeUnavailableSkips == 0)
        #expect(report.byStatus[.missing] == 1)
        #expect(try #require(try db.integrityRecord(bookID: 1)).status == .missing)
    }

    // MARK: - 5. 3 モードで対象が変わる

    @Test("3 モードで対象になる本の集合が異なる（scan が正しい候補だけを検査する）")
    func threeModesSelectDifferentCandidates() async throws {
        // モード間で状態を共有すると、後段の scan（例: .all）が前段の判定材料（例: book 3 の
        // status='damaged'）を上書きしてしまい、独立した比較にならない。モードごとに
        // まっさらなライブラリを用意する。
        func freshLibrary() throws -> Database {
            let db = try setupDB()
            try db.insertBook(book(id: 1, title: "unchecked", path: "/lib/1.zip"))
            try db.insertBook(book(id: 2, title: "already-full", path: "/lib/2.zip"))
            try db.insertBook(book(id: 3, title: "damaged", path: "/lib/3.zip"))
            try db.upsertIntegrity(IntegrityRecord(
                bookID: 2, status: .ok, method: .full, checkedAt: 100,
                fileSize: nil, fileMtime: nil, entryCount: nil, badEntries: [],
                prevStatus: nil, prevCheckedAt: nil))
            try db.upsertIntegrity(IntegrityRecord(
                bookID: 3, status: .damaged, method: .full, checkedAt: 100,
                fileSize: nil, fileMtime: nil, entryCount: nil, badEntries: [],
                prevStatus: nil, prevCheckedAt: nil))
            return db
        }

        final class Tracker: @unchecked Sendable {
            var verifiedPaths: Set<String> = []
        }

        func verifiedIDs(mode: FullScanMode) async throws -> Set<Int> {
            let db = try freshLibrary()
            let tracker = Tracker()
            _ = try await FullIntegrityScanner.scan(
                database: db, mode: mode,
                deps: deps(verify: { url, _ in
                    tracker.verifiedPaths.insert(url.path)
                    return ArchiveVerifyResult(entryCount: 1, imageCount: 1, badEntries: [], truncated: false)
                }))
            return Set(tracker.verifiedPaths.compactMap {
                Int((($0 as NSString).lastPathComponent as NSString).deletingPathExtension)
            })
        }

        #expect(try await verifiedIDs(mode: .uncheckedOnly) == [1],
                "未検査のみは book 1 だけを対象にすべき（2,3 は既に full 行を持つ）")
        #expect(try await verifiedIDs(mode: .all) == [1, 2, 3],
                ".all は method='full' の有無を無視して全冊を対象にすべき")
        #expect(try await verifiedIDs(mode: .damagedOnly) == [3],
                "damagedOnly は前回 damaged だった book 3 だけを対象にすべき")
    }

    // MARK: - 6. 劣化検出（ビット腐敗）

    /// spec §4.1: `.all` で再走査することで初めて `prev_status='ok'` → `status='damaged'` の
    /// 遷移（劣化）が到達可能になる。G27a では構造的に 0 だった。
    @Test("2 回目の .all 走査で ok → damaged になると isDegraded が true になる")
    func rescanWithAllModeDetectsDegradation() async throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "a", path: "/lib/a.zip"))

        // 1 回目: 正常。
        _ = try await FullIntegrityScanner.scan(
            database: db, mode: .all,
            deps: deps(verify: { _, _ in
                ArchiveVerifyResult(entryCount: 10, imageCount: 10, badEntries: [], truncated: false)
            }))
        var rec = try #require(try db.integrityRecord(bookID: 1))
        #expect(rec.status == .ok)
        #expect(rec.isDegraded == false)

        // .uncheckedOnly では 1 回目で method='full' 行ができているので、もう候補にならない
        // （＝劣化検出には .all が不可欠であることの裏付け）。
        #expect(try db.booksNeedingFullCheck(mode: .uncheckedOnly).isEmpty)

        // 2 回目: ディスク上で腐った想定（サイズ・mtime は変えず CRC だけ不一致になる）。
        _ = try await FullIntegrityScanner.scan(
            database: db, mode: .all,
            deps: deps(verify: { _, _ in
                ArchiveVerifyResult(entryCount: 10, imageCount: 10, badEntries: ["003.png"], truncated: false)
            }))

        rec = try #require(try db.integrityRecord(bookID: 1))
        #expect(rec.status == .damaged)
        #expect(rec.prevStatus == .ok)
        #expect(rec.isDegraded == true, "ok → damaged の遷移が劣化として検出できていない")
    }

    @Test("進捗が 1 冊ごとに報告される")
    func progressIsReportedPerBook() async throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "a", path: "/lib/a.zip"))
        try db.insertBook(book(id: 2, title: "b", path: "/lib/b.zip"))

        final class Collector: @unchecked Sendable {
            var seen: [Int] = []
            var totals: [Int] = []
        }
        let collector = Collector()

        _ = try await FullIntegrityScanner.scan(
            database: db,
            deps: deps(verify: { _, _ in
                ArchiveVerifyResult(entryCount: 1, imageCount: 1, badEntries: [], truncated: false)
            })
        ) { done, total in
            collector.seen.append(done)
            collector.totals.append(total)
        }

        #expect(collector.seen == [1, 2])
        #expect(collector.totals == [2, 2])
    }
}
