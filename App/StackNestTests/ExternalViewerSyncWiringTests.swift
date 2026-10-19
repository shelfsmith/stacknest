// SPDX-License-Identifier: MIT
import Testing
import Foundation
import AppCore
import LibraryStore
import LibraryServerAPI
import RemoteClient
import StackroomFormat
@testable import StackNest

/// viewer-token にだけ答える URLProtocol（G60 の App テスト用）。それ以外の要求は 200 `{}`。
/// 記録は URLSession のスレッドと main の両方から触るので `NSLock` で包む。
final class G60ViewerTokenStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedIssueStatus = 200
    nonisolated(unsafe) private static var storedIssueBody = Data()
    nonisolated(unsafe) private static var storedPaths: [String] = []
    nonisolated(unsafe) private static var storedIssueHeaders: [String: String] = [:]
    nonisolated(unsafe) private static var storedStatusStatus = 200
    nonisolated(unsafe) private static var storedStatusBody = Data(#"{"firstUsedAt":null,"viewer":null}"#.utf8)
    nonisolated(unsafe) private static var storedDetailBody: Data?

    /// `GET …/books/{id}/detail` の応答。nil なら他の道と同じ `{}`（読めないので一覧の位置に倒れる）。
    static var detailBody: Data? {
        get { lock.withLock { storedDetailBody } }
        set { lock.withLock { storedDetailBody = newValue } }
    }

    /// G60 v3: `GET /api/v1/viewer-tokens/{id}`（使用の照会）の応答。
    static var statusStatus: Int {
        get { lock.withLock { storedStatusStatus } }
        set { lock.withLock { storedStatusStatus = newValue } }
    }
    static var statusBody: Data {
        get { lock.withLock { storedStatusBody } }
        set { lock.withLock { storedStatusBody = newValue } }
    }

    /// viewer-token の応答に足すヘッダ（施錠ゲートの 403 は `X-Library-Locked: 1`）。
    static var issueHeaders: [String: String] {
        get { lock.withLock { storedIssueHeaders } }
        set { lock.withLock { storedIssueHeaders = newValue } }
    }

    static var issueStatus: Int {
        get { lock.withLock { storedIssueStatus } }
        set { lock.withLock { storedIssueStatus = newValue } }
    }
    static var issueBody: Data {
        get { lock.withLock { storedIssueBody } }
        set { lock.withLock { storedIssueBody = newValue } }
    }
    static var paths: [String] {
        get { lock.withLock { storedPaths } }
        set { lock.withLock { storedPaths = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.lock.withLock { Self.storedPaths.append("\(request.httpMethod ?? "") \(path)") }
        let isIssue = path.hasSuffix("/viewer-token")
        let isStatus = path.hasPrefix("/api/v1/viewer-tokens/")
        let detail = path.hasSuffix("/detail") ? Self.detailBody : nil
        let status = isIssue ? Self.issueStatus : (isStatus ? Self.statusStatus : 200)
        let resp = HTTPURLResponse(url: request.url!, statusCode: status,
                                   httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"].merging(isIssue ? Self.issueHeaders : [:]) { $1 })!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: isIssue ? Self.issueBody : (isStatus ? Self.statusBody : (detail ?? Data("{}".utf8))))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// G60: 「StackNest と読書位置を同期する」の ON/OFF で開き方が変わること・失敗したら従来の開き方に戻ること。
/// `HelperLauncher.launch` を差し替えるので、ローカルもリモートも**この 1 つの Suite** に置いて直列で走らせる
/// （Suite を分けると並行に走り、差し替えが競合する）。
/// UserDefaults.standard・実ポート・`LastReadTracker.shared` には触れない（`ExternalViewerHandoff` を差し替える）。
@MainActor
@Suite("G60: 外部ビューアとの読書位置の同期（配線）", .serialized)
struct ExternalViewerSyncWiringTests {
    final class Launches { var entries: [(file: URL, viewer: URL)] = [] }

    struct Env {
        let suiteName: String
        let suite: UserDefaults
        let base: URL
        let viewerApp: URL
        let settings: ViewerSettings
        let tokens: ViewerTokenStore
        let confirmed: ConfirmedViewerStore
        let relays: ViewerRelayRegistry
        func cleanup() {
            suite.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: base)
        }
    }

    /// G60 v3: 偽アプリの Info.plist に、StackNest への対応の宣言（`StackNestViewerSupport`）を書く。
    static func declareReferenceSupport(_ app: URL, versions: [Int] = [1]) throws {
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.fakeviewer",
            "CFBundleName": "FakeViewer",
            StackNestViewerSupport.infoPlistKey: [StackNestViewerSupport.versionsKey: versions],
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
    }

    /// G60 v3: 参照ファイルの型（UTType・拡張子）だけを宣言し、`StackNestViewerSupport` を持たない Info.plist
    /// （v2 で対応とみなしていた形）に差し替える。v3 では未対応。
    static func writeTypeOnlyInfoPlist(_ app: URL) throws {
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.fakeviewer",
            "CFBundleName": "FakeViewer",
            "CFBundleDocumentTypes": [
                ["LSItemContentTypes": [StackNestFormat.typeIdentifier]],
                ["CFBundleTypeExtensions": [StackNestFormat.fileExtension, "zip"]],
            ],
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
    }

    func makeEnv(sync: Bool) throws -> Env {
        let name = "g60-wiring-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("g60-wiring-\(UUID().uuidString)", isDirectory: true)
        let viewerApp = base.appendingPathComponent("FakeViewer.app", isDirectory: true)
        try FileManager.default.createDirectory(at: viewerApp, withIntermediateDirectories: true)
        try Self.declareReferenceSupport(viewerApp)
        let settings = ViewerSettings(defaults: suite)
        settings.useBuiltInImageViewer = false
        settings.externalViewerAppPath = viewerApp.path
        settings.syncsReadingPositionWithExternalViewer = sync
        return Env(suiteName: name, suite: suite, base: base, viewerApp: viewerApp,
                   settings: settings, tokens: ViewerTokenStore(defaults: suite),
                   confirmed: ConfirmedViewerStore(defaults: suite),
                   relays: ViewerRelayRegistry())
    }

    final class LastReads { var items: [LastReadBook] = [] }
    /// G60 §5.9: 中継の本の先読みを始めた記録（中継の id と中心）。
    final class Prefetches { var items: [(relayID: String, focus: Int)] = [] }
    /// 127.0.0.1 の口が動いているか（渡しの途中で止める試験用）。
    final class EndpointFlag { var running = true }
    final class Fallbacks { var entries: [(bookID: Int, manifest: ManifestDTO?)] = [] }
    /// 確認の待ちに渡された時間を記録する（`sleep` は @Sendable なので鍵で包む）。
    final class Delays: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Duration] = []
        var values: [Duration] { lock.withLock { stored } }
        func append(_ d: Duration) { lock.withLock { stored.append(d) } }
    }

    /// - Parameter relay: リモートの本を中継するか（本番の判断は `ExternalViewerSyncRouting.relaysRemoteBooks`）。
    /// - Parameter prefetches: 中継の本の先読みを始めた記録（G60 §5.9）。nil なら記録しない（本物の先読みは走らない）。
    /// - Parameter sleep: 確認の待ち。**既定は即座に取り消す**（確認を走らせず、照会の要求も出さない。
    ///   スタブは照会以外に `{}` を返すので、既定で確認が走ると全部「未使用」と読まれてしまう）。
    /// - Parameter endpoint: 渡しの途中で口を止める試験用。あれば `endpointRunning` より優先する。
    func handoff(_ env: Env, endpointRunning: Bool = true, endpoint: EndpointFlag? = nil, lastReads: LastReads? = nil,
                 relay: Bool = true, prefetches: Prefetches? = nil,
                 sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in throw CancellationError() })
        -> ExternalViewerHandoff {
        ExternalViewerHandoff(
            tokens: env.tokens,
            references: BookReferenceStore(baseDirectory: env.base.appendingPathComponent("AppSupport")),
            localPort: { 4321 },
            isLocalEndpointRunning: { endpoint?.running ?? endpointRunning },
            recordLastRead: { lastReads?.items.append($0) },
            now: { Date() },
            relays: env.relays,
            relaysRemoteBooks: relay,
            sleep: sleep,
            confirmedViewers: env.confirmed,
            startRelayPrefetch: { relayID, focus in prefetches?.items.append((relayID, focus)) })
    }

    func recording(_ launches: Launches) -> (URL, URL) -> Void {
        { file, viewer in launches.entries.append((file, viewer)) }
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        // 全スイート並行のときは MainActor が混むので余裕を持たせる（成功時は即戻る）。
        let deadline = ContinuousClock.now + .seconds(60)
        while !condition() {
            if ContinuousClock.now >= deadline { Issue.record("待ちきれなかった"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// 3 ページのフォルダ本 1 冊（読書位置 2）を持つローカルの書庫。
    private func makeLocalState(_ env: Env, handoff: ExternalViewerHandoff) throws -> (AppState, BookRow, URL) {
        let dir = env.base.appendingPathComponent("folder-book", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<3 { try Data("p\(i)".utf8).write(to: dir.appendingPathComponent("p\(i).jpg")) }
        let db = try Database.openInMemory()
        try db.migrate()
        try db.insertBook(BookRecord(
            id: 1, title: "本の題名", author: nil, genre: nil,
            path: dir.path, dateAdded: Date(timeIntervalSince1970: 100), playDate: nil,
            bookType: 0, fileType: 2, pages: 3, myRate: 0, unseen: true,
            keywordA: nil, keywordB: nil, keywordC: nil, neta: nil))
        try db.saveViewerState(bookID: 1, spreadEnabled: false, coverOffset: false, lastPage: 2)
        let state = AppState(bundleURL: env.base.appendingPathComponent("g60.stacknest"))
        state.database = db
        state.librarySettings = try LibrarySettings(database: db)
        state.viewerSettings = env.settings
        state.viewerHandoff = handoff
        let row = try #require(try db.fetchBook(id: 1))
        return (state, row, dir)
    }

    // MARK: - ローカル

    @Test func localSyncOnHandsAReferenceFile() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (state, row, _) = try makeLocalState(env, handoff: handoff(env))

        state.openBooks([row])
        try await waitUntil { !launches.entries.isEmpty }

        let launched = try #require(launches.entries.first)
        #expect(launches.entries.count == 1, "参照ファイルで開いたら従来の開き方は走らない")
        #expect(launched.file.pathExtension == "stacknestbook")
        #expect(launched.viewer.path == env.viewerApp.path)
        let attrs = try FileManager.default.attributesOfItem(atPath: launched.file.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let ref = try StackNestBookReference.load(contentsOf: launched.file)
        let uuid = try #require(state.librarySettings?.ensureLibraryUUID())
        #expect(ref.bookURL.absoluteString == "http://127.0.0.1:4321/api/v1/libraries/\(uuid)/books/1")
        #expect(ref.title == "本の題名")
        #expect(ref.pageCount == 3)
        #expect(ref.startPage == 2)
        #expect(ref.version == 1, "宣言 [1] との共通の最大")
        guard case .valid(let record) = env.tokens.lookup(token: ref.token, issuer: .localEndpoint) else {
            Issue.record("参照ファイルのトークンが 127.0.0.1 の口で有効でない"); return
        }
        #expect(record.libraryUUID == uuid)
        #expect(record.bookID == 1)
        #expect(record.issuedByGrantID == nil, "アプリが手元で出したトークンはグラントに結び付かない")
        // Codex P1（2 回目）: 本の印（書庫の DB の追加日時＝1970 年から 100 秒）に結び付ける。
        #expect(record.bookStamp == "added:100")
        #expect(record.bookStamp == ViewerTokenRecord.bookStamp(dateAdded: row.dateAdded))
    }

    @Test func localSyncOffOpensTheFile() async throws {
        let env = try makeEnv(sync: false); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (state, row, dir) = try makeLocalState(env, handoff: handoff(env))

        state.openBooks([row])
        try await waitUntil { !launches.entries.isEmpty }

        #expect(launches.entries.first?.file.path == dir.path)
        #expect(env.tokens.allRecords().isEmpty, "OFF ではトークンを出さない")
    }

    @Test func localFailureFallsBackToTheFileWithANotice() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (state, row, dir) = try makeLocalState(env, handoff: handoff(env, endpointRunning: false))

        state.openBooks([row])
        try await waitUntil { !launches.entries.isEmpty }

        #expect(launches.entries.count == 1)
        #expect(launches.entries.first?.file.path == dir.path)
        #expect(state.watchNotice.notice?.kind == .warning)
        #expect(state.watchNotice.notice?.text.contains("ファイルをそのまま") == true)
        #expect(state.watchNotice.notice?.text.contains("127.0.0.1") == true)
    }

    // MARK: - G64: 足した拡張子の本は、読めるときだけ参照ファイルで渡す

    /// `canServePages` が呼ばれた回数を数える（実物の `BookReadability` に任せる）。
    final class ReadabilityCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        var paths: [String] { lock.withLock { stored } }
        func record(_ path: String) { lock.withLock { stored.append(path) } }
    }

    /// 1 冊のファイルの本（`fileName` の名前で `data` を書く）を持つローカルの書庫。一覧は `userExtensions` に固定する
    /// （App のテストは本物の UserDefaults の上で動くので、`UserExtensionStore.shared` を書き換えない）。
    private func makeLocalFileState(_ env: Env, fileName: String, data: Data, userExtensions: UserExtensionMap,
                                    calls: ReadabilityCalls) throws -> (AppState, BookRow, URL) {
        let url = env.base.appendingPathComponent(fileName)
        try data.write(to: url)
        let db = try Database.openInMemory()
        try db.migrate()
        try db.insertBook(BookRecord(
            id: 1, title: "本の題名", author: nil, genre: nil,
            path: url.path, dateAdded: Date(timeIntervalSince1970: 100), playDate: nil,
            bookType: 0, fileType: 2, pages: nil, myRate: 0, unseen: true,
            keywordA: nil, keywordB: nil, keywordC: nil, neta: nil))
        let state = AppState(bundleURL: env.base.appendingPathComponent("g64.stacknest"))
        state.database = db
        state.librarySettings = try LibrarySettings(database: db)
        state.viewerSettings = env.settings
        state.viewerHandoff = handoff(env)
        state.userExtensions = { userExtensions }
        state.canServePages = { path, list in
            calls.record(path)
            return await BookReadability.canServePages(path: path, userExtensions: list)
        }
        let row = try #require(try db.fetchBook(id: 1))
        return (state, row, url)
    }

    /// PNG 1 枚の tar（`/usr/bin/tar`）。
    private func tarData(gzip: Bool) throws -> Data {
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("g64-wiring-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: src) }
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!
            .write(to: src.appendingPathComponent("p1.png"))
        let out = src.appendingPathComponent("out")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.environment = ["COPYFILE_DISABLE": "1"]
        process.arguments = [gzip ? "-czf" : "-cf", out.path, "-C", src.path, "p1.png"]
        try process.run()
        process.waitUntilExit()
        return try Data(contentsOf: out)
    }

    @Test func localUnreadableAddedBookOpensTheFileWithoutAToken() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let calls = ReadabilityCalls()
        let (state, row, url) = try makeLocalFileState(
            env, fileName: "book.g64bad", data: Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }),
            userExtensions: ["g64bad": .archive], calls: calls)

        await state.openInExternalViewerSyncing([row])

        #expect(calls.paths == [url.path])
        #expect(launches.entries.count == 1)
        #expect(launches.entries.first?.file.path == url.path, "参照ファイルではなく本そのもの")
        #expect(env.tokens.allRecords().isEmpty, "鍵を出さない")
        #expect(referenceFiles(env).isEmpty)
        #expect(state.watchNotice.notice == nil, "お知らせを出さない")
        #expect(state.error == nil)
    }

    @Test func localReadableAddedBookIsHandedByReference() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let calls = ReadabilityCalls()
        let (state, row, url) = try makeLocalFileState(
            env, fileName: "book.g64arc", data: try tarData(gzip: true), userExtensions: ["g64arc": .archive], calls: calls)

        await state.openInExternalViewerSyncing([row])

        #expect(calls.paths == [url.path])
        #expect(launches.entries.first?.file.pathExtension == "stacknestbook")
        #expect(env.tokens.allRecords().count == 1)
    }

    @Test func standardBooksAreNotCheckedBeforeTheHandOff() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let calls = ReadabilityCalls()
        // 標準の cbt（足した一覧に cbt があっても標準が勝つ）。
        let (state, row, _) = try makeLocalFileState(
            env, fileName: "book.cbt", data: try tarData(gzip: false), userExtensions: ["cbt": .text], calls: calls)

        await state.openInExternalViewerSyncing([row])

        #expect(calls.paths.isEmpty, "標準の拡張子では読めるかを確かめない")
        #expect(launches.entries.first?.file.pathExtension == "stacknestbook")

        // フォルダの本も確かめない。
        let (folderState, folderRow, _) = try makeLocalState(env, handoff: handoff(env))
        folderState.userExtensions = { ["g64arc": .archive] }
        folderState.canServePages = { path, _ in calls.record(path); return false }
        await folderState.openInExternalViewerSyncing([folderRow])
        #expect(calls.paths.isEmpty)
    }

    // MARK: - ロック・ビューア未設定（G60 fix round 1）

    private func setLock(_ state: AppState, _ value: String) throws {
        try state.database?.setLibrarySetting(key: "lock_password_hash", value: value)
    }

    private func referenceFiles(_ env: Env) -> [URL] {
        let root = env.base.appendingPathComponent("AppSupport/ViewerHandoff")
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (e?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "stacknestbook" }
    }

    @Test func lockedLibraryBindsTheTokenToTheVerifiedHash() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (state, row, _) = try makeLocalState(env, handoff: handoff(env))
        try setLock(state, "H1")
        state.markUnlocked(hash: "H1")

        state.openBooks([row])
        try await waitUntil { !launches.entries.isEmpty }

        #expect(launches.entries.count == 1)
        let launched = try #require(launches.entries.first)
        let ref = try StackNestBookReference.load(contentsOf: launched.file)
        guard case .valid(let record) = env.tokens.lookup(token: ref.token, issuer: .localEndpoint) else {
            Issue.record("トークンが有効でない"); return
        }
        #expect(record.lockFingerprint == ViewerTokenStore.lockFingerprint(for: "H1"))
    }

    @Test func lockChangedBehindTheWindowOpensNothingAndIssuesNothing() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let h = handoff(env)
        let (state, row, _) = try makeLocalState(env, handoff: h)
        try setLock(state, "H2")          // 書庫側は H2
        state.markUnlocked(hash: "H1")    // このウィンドウが検証したのは H1

        let failure = await h.openLocal(
            book: row, libraryUUID: try #require(state.librarySettings?.ensureLibraryUUID()),
            viewer: try #require(HelperLauncher.referenceViewer(bookPath: row.path ?? "", settings: env.settings)),
            lockCredential: { "H2" }, verifiedLockHash: { "H1" }, startPage: 0,
            direction: .rightToLeft, settings: env.settings)
        #expect(failure == .libraryLocked)

        await state.openInExternalViewerSyncing([row])
        #expect(launches.entries.isEmpty, "施錠庫は生のファイルにも逃がさない")
        #expect(env.tokens.allRecords().isEmpty)
        #expect(referenceFiles(env).isEmpty)
        #expect(state.watchNotice.notice?.kind == .warning)
    }

    @Test func missingViewerSkipsTheHandoffWithoutIssuingAToken() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        env.settings.externalViewerAppPath = env.base.appendingPathComponent("Nope.app").path
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (state, row, _) = try makeLocalState(env, handoff: handoff(env))

        await state.openInExternalViewerSyncing([row])

        #expect(env.tokens.allRecords().isEmpty)
        #expect(referenceFiles(env).isEmpty)
        #expect(launches.entries.isEmpty)
        #expect(state.watchNotice.notice == nil, "同期失敗のお知らせは出さない")
        #expect(state.error != nil, "従来の開き方がビューア未設定を報告する")
    }


    /// G60 v3: 参照ファイルの型だけを宣言し `StackNestViewerSupport` を持たないビューアには、トークンも参照ファイルも
    /// お知らせも出さず、G60 前と同じにファイルそのものを渡す（v2 ではこの形を対応とみなしていた）。
    @Test func localTypeOnlyViewerGetsTheFileSilently() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        try Self.writeTypeOnlyInfoPlist(env.viewerApp)
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (state, row, dir) = try makeLocalState(env, handoff: handoff(env))

        state.openBooks([row])
        try await waitUntil { !launches.entries.isEmpty }
        try await Task.sleep(for: .milliseconds(50))   // 余計な起動があれば、ここで届く

        #expect(launches.entries.count == 1)
        #expect(launches.entries.first?.file.path == dir.path, "参照ファイルではなく本そのもの")
        #expect(launches.entries.first?.viewer.path == env.viewerApp.path)
        #expect(env.tokens.allRecords().isEmpty)
        #expect(referenceFiles(env).isEmpty)
        #expect(state.watchNotice.notice == nil)
        #expect(state.error == nil)
    }

    /// G60 v3: 将来の版を併せて宣言していても、StackNest が書ける最大（1）で書く。
    @Test func localReferenceUsesTheNegotiatedVersion() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        try Self.declareReferenceSupport(env.viewerApp, versions: [1, 9])
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (state, row, _) = try makeLocalState(env, handoff: handoff(env))

        state.openBooks([row])
        try await waitUntil { !launches.entries.isEmpty }

        let ref = try StackNestBookReference.load(contentsOf: try #require(launches.entries.first).file)
        #expect(ref.version == 1)
    }

    /// G60 v3: 共通の版が無い（[9] だけを宣言）なら未対応。ファイルのまま黙って渡す。
    @Test func localViewerWithNoCommonVersionGetsTheFile() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        try Self.declareReferenceSupport(env.viewerApp, versions: [9])
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (state, row, dir) = try makeLocalState(env, handoff: handoff(env))

        state.openBooks([row])
        try await waitUntil { !launches.entries.isEmpty }
        try await Task.sleep(for: .milliseconds(50))

        #expect(launches.entries.count == 1)
        #expect(launches.entries.first?.file.path == dir.path)
        #expect(env.tokens.allRecords().isEmpty)
        #expect(referenceFiles(env).isEmpty)
        #expect(state.watchNotice.notice == nil)
    }

    // MARK: - リモート

    /// 内蔵ビューアで開く本体は差し替える（`builtInOpenOverride`）。本物の窓・`LastReadTracker.shared` に触れず、
    /// 「内蔵へ倒した」を陽性の合図として待てる。ダウンロード済みコピーの問い合わせも差し替える（実 `~/Library` を読まない）。
    /// - Parameter issueExpiresAt: リモートが返す鍵の期限（既定は中継の鍵より遠い 2033 年）。
    private func makeRemoteState(_ env: Env, issueStatus: Int, libraryToken: String? = nil,
                                 issueHeaders: [String: String] = [:], lastReads: LastReads? = nil,
                                 offlineLastPage: Int? = nil, serverLastPage: Int? = nil,
                                 relay: Bool = true, endpointRunning: Bool = true,
                                 issueExpiresAt: Date = Date(timeIntervalSince1970: 2_000_000_000),
                                 statusStatus: Int = 200,
                                 statusBody: Data = Data(#"{"firstUsedAt":null,"viewer":null}"#.utf8),
                                 sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in throw CancellationError() })
        throws -> (RemoteLibraryState, Fallbacks) {
        G60ViewerTokenStub.paths = []
        G60ViewerTokenStub.issueStatus = issueStatus
        G60ViewerTokenStub.issueHeaders = issueHeaders
        G60ViewerTokenStub.statusStatus = statusStatus
        G60ViewerTokenStub.statusBody = statusBody
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // サーバの今の位置（`detail`）。nil なら読めない応答にする（一覧の位置に倒れる）。
        G60ViewerTokenStub.detailBody = try serverLastPage.map {
            try encoder.encode(BookDetailDTO(
                id: 0, title: "本の題名", author: nil, genre: nil, path: nil, dateAdded: Date(), playDate: nil,
                bookType: 0, fileType: 0, pages: 20, lastPage: $0, rating: 0, unseen: false,
                keywordA: nil, keywordB: nil, keywordC: nil, neta: nil, memo: nil, series: nil, volume: nil,
                coverImageName: nil, coverCropRectJSON: nil, pageDirection: nil))
        }
        G60ViewerTokenStub.issueBody = try encoder.encode(
            ViewerTokenReply(token: "VIEWER-TOKEN", expiresAt: issueExpiresAt, tokenID: "TID-1"))
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [G60ViewerTokenStub.self]
        let client = RemoteLibraryClient(baseURL: URL(string: "http://127.0.0.1:1/")!, deviceToken: "device",
                                         session: URLSession(configuration: cfg))
        let s = RemoteLibraryState(
            client: client, serverID: UUID(), libraryUUID: "LIB-\(UUID().uuidString)",
            libraryName: "テスト", locked: false, libraryToken: libraryToken,
            coverCache: RemoteCoverCache(cache: nil, serverID: nil, libraryUUID: nil))
        s.viewerSettings = env.settings
        s.viewerHandoff = handoff(env, endpointRunning: endpointRunning, lastReads: lastReads, relay: relay, sleep: sleep)
        s.offlineLastPageOverride = { _ in offlineLastPage }
        let fallbacks = Fallbacks()
        s.builtInOpenOverride = { book, manifest in fallbacks.entries.append((book.id, manifest)) }
        return (s, fallbacks)
    }

    private func remoteBook(id: Int, filename: String, lastPage: Int) -> BookListItemDTO {
        BookListItemDTO(
            id: id, title: "本の題名", author: nil, series: nil, volume: nil,
            rating: 0, unseen: true, bookType: 0, pages: 20, lastPage: lastPage,
            lastReadAt: nil, dateAdded: Date(), hasCover: false, coverVersion: nil,
            filename: filename)
    }

    private func archiveManifest() -> ManifestDTO {
        ManifestDTO(pageCount: 20, direction: "ltr", format: "archive", etag: "e")
    }

    @Test func remoteSyncOnHandsAReferenceFile() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let lastReads = LastReads()
        let (s, fallbacks) = try makeRemoteState(env, issueStatus: 200, lastReads: lastReads)
        s.testPutManifestHandoff(bookID: 42, value: archiveManifest())
        let book = remoteBook(id: 42, filename: "a.zip", lastPage: 5)
        s.books = [book]

        s.openViewer(book: book)
        try await waitUntil { !launches.entries.isEmpty }

        let file = try #require(launches.entries.first).file
        let ref = try StackNestBookReference.load(contentsOf: file)
        // G60 v3（spec §5.8・試用）: リモートの本も手元の 127.0.0.1 の口で中継する。
        let relayPrefix = "http://127.0.0.1:4321/api/v1/relay/"
        #expect(ref.bookURL.absoluteString.hasPrefix(relayPrefix))
        let relayID = String(ref.bookURL.absoluteString.dropFirst(relayPrefix.count))
        let target = try #require(env.relays.target(for: relayID))
        #expect(target.remoteToken == "VIEWER-TOKEN")
        #expect(target.remoteBookURL == "http://127.0.0.1:1/api/v1/libraries/\(s.libraryUUID)/books/42")
        #expect(ref.token != "VIEWER-TOKEN", "リモートの鍵は参照ファイルに書かない")
        let raw = try String(contentsOf: file, encoding: .utf8)
        #expect(!raw.contains("VIEWER-TOKEN"))
        guard case .valid(let relayRecord) = env.tokens.lookup(token: ref.token, issuer: .localEndpoint) else {
            Issue.record("参照ファイルの鍵が 127.0.0.1 の口の中継の鍵になっていない"); return
        }
        #expect(relayRecord.relayID == relayID)
        // M-3: 中継の鍵の記録は本物の書庫・本を持たない（本物は中継の記録だけ）。
        #expect(relayRecord.libraryUUID == ViewerTokenRecord.relaySentinelLibraryUUID)
        #expect(relayRecord.bookID == ViewerTokenRecord.relaySentinelBookID)
        #expect(relayRecord.libraryUUID != s.libraryUUID)
        // レビュー I-4: リモートの鍵（2033 年）の方が遅いので、参照ファイルの期限は中継の鍵の期限と同じ
        // （参照ファイルの日時は秒までなので 1 秒未満の差は許す）。
        #expect(abs(ref.expiresAt.timeIntervalSince(relayRecord.expiresAt)) < 1)
        #expect(relayRecord.expiresAt < Date(timeIntervalSince1970: 2_000_000_000))
        // 中継の記録も同じ期限で切れる（その時刻を過ぎたら 401）。
        #expect(env.relays.target(for: relayID, now: relayRecord.expiresAt.addingTimeInterval(-1)) != nil)
        #expect(env.relays.target(for: relayID, now: relayRecord.expiresAt) == nil)
        #expect(ref.pageCount == 20)
        #expect(ref.direction == .leftToRight)
        #expect(ref.startPage == 5)
        #expect(G60ViewerTokenStub.paths.contains("POST /api/v1/libraries/\(s.libraryUUID)/books/42/viewer-token"))
        #expect(s.errorText == nil)
        #expect(fallbacks.entries.isEmpty)
        // 内蔵と同じに、開いた時点で既読にし、最後に開いた本として記録する。
        #expect(s.books.first?.unseen == false)
        #expect(lastReads.items == [.remote(
            serverID: s.serverID, serverURL: "http://127.0.0.1:1/", libraryUUID: s.libraryUUID,
            libraryName: "テスト", bookID: 42, title: "本の題名", locked: false)])
        // 開いた後の既読の書き込み（投げっぱなしの POST /progress）が届くまで待つ。
        // 待たずに抜けると、次のテストが記録を空にした後にこの要求が届いて記録を汚す。
        try await waitUntil { G60ViewerTokenStub.paths.contains { $0.hasSuffix("/books/42/progress") } }
        #expect(!G60ViewerTokenStub.paths.contains { $0.hasPrefix("GET /api/v1/viewer-tokens/") },
                "テストの既定の待ちは取り消されるので、照会の要求は出ない")
    }

    /// リモートのフォルダの本（filename に拡張子が無い）は、manifest の format でフォルダの外部ビューアへ渡す
    /// （filename の拡張子から決めるとアーカイブの指定に倒れていた＝最終レビュー M-1）。
    @Test func remoteFolderBookUsesTheFolderViewer() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let folderViewer = env.base.appendingPathComponent("FolderViewer.app", isDirectory: true)
        try FileManager.default.createDirectory(at: folderViewer, withIntermediateDirectories: true)
        try Self.declareReferenceSupport(folderViewer)
        env.settings.categoryViewerPaths[.folder] = folderViewer.path
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (s, fallbacks) = try makeRemoteState(env, issueStatus: 200)
        s.testPutManifestHandoff(bookID: 51, value: ManifestDTO(pageCount: 20, direction: "rtl", format: "folder", etag: "e"))

        s.openViewer(book: remoteBook(id: 51, filename: "フォルダの本", lastPage: 0))
        try await waitUntil { !launches.entries.isEmpty || !fallbacks.entries.isEmpty }

        #expect(fallbacks.entries.isEmpty)
        let launched = try #require(launches.entries.first)
        #expect(launched.file.pathExtension == "stacknestbook")
        #expect(launched.viewer.path == folderViewer.path, "フォルダの本はフォルダの外部ビューアで開く")
        try await waitUntil { G60ViewerTokenStub.paths.contains { $0.hasSuffix("/books/51/progress") } }
    }

    /// ダウンロード済みコピーの方が先まで読んでいるときは、内蔵と同じにそちらから始める（サーバを巻き戻さない）。
    @Test func remoteStartPageUsesTheFurtherOfServerAndOfflinePosition() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (s, _) = try makeRemoteState(env, issueStatus: 200, offlineLastPage: 12)
        s.testPutManifestHandoff(bookID: 48, value: archiveManifest())

        s.openViewer(book: remoteBook(id: 48, filename: "a.zip", lastPage: 5))
        try await waitUntil { !launches.entries.isEmpty }

        let ref = try StackNestBookReference.load(contentsOf: try #require(launches.entries.first).file)
        #expect(ref.startPage == 12)
        try await waitUntil { G60ViewerTokenStub.paths.contains { $0.hasSuffix("/books/48/progress") } }
    }

    /// Codex P1: 外部ビューアが書き戻した位置は一覧に届かない（`/progress` は SSE を出さない）。渡す前にサーバの
    /// 今の位置を引き直して、そこから開く（一覧の古い位置で開いて、渡した後の `postProgress` でサーバを巻き戻さない）。
    @Test func remoteStartPageUsesTheServerPositionFetchedAtHandoff() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (s, _) = try makeRemoteState(env, issueStatus: 200, serverLastPage: 15)
        s.testPutManifestHandoff(bookID: 49, value: archiveManifest())

        s.openViewer(book: remoteBook(id: 49, filename: "a.zip", lastPage: 3))   // 一覧はまだ 3 のまま
        try await waitUntil { !launches.entries.isEmpty }

        let ref = try StackNestBookReference.load(contentsOf: try #require(launches.entries.first).file)
        #expect(ref.startPage == 15)
        #expect(G60ViewerTokenStub.paths.contains { $0.hasSuffix("/books/49/detail") })
    }

    /// Codex P2（3 回目）: 開いた位置をサーバへ書き終えてから外部ビューアを起動する（起動した後に書くと、ビューアが
    /// 先に書いた新しい位置を、遅れて届いた最初の書き込みが巻き戻しうる）。
    @Test func remoteInitialProgressIsWrittenBeforeTheViewerLaunches() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        final class Seen { var progressBeforeLaunch: Bool? }
        let seen = Seen()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = { file, viewer in
            seen.progressBeforeLaunch = G60ViewerTokenStub.paths.contains { $0.hasSuffix("/books/50/progress") }
            launches.entries.append((file, viewer))
        }
        let (s, _) = try makeRemoteState(env, issueStatus: 200, serverLastPage: 7)
        s.testPutManifestHandoff(bookID: 50, value: archiveManifest())

        s.openViewer(book: remoteBook(id: 50, filename: "a.zip", lastPage: 7))
        try await waitUntil { !launches.entries.isEmpty }

        #expect(seen.progressBeforeLaunch == true)
    }

    /// Codex P2（5 回目）: 期限付きの待ち。期限までに返らなければ nil（作業は取り消す）、返れば値。
    @Test func boundedWaitGivesUpOnASlowOperation() async {
        let start = ContinuousClock.now
        let slow: Int? = await RemoteLibraryState.value(within: .milliseconds(200)) {
            try? await Task.sleep(for: .seconds(30))
            return 1
        }
        #expect(slow == nil)
        #expect(ContinuousClock.now - start < .seconds(5), "期限で見切る（30 秒待たない）")
        let fast: Int? = await RemoteLibraryState.value(within: .seconds(5)) { 7 }
        #expect(fast == 7)
    }

    /// Codex P1（内蔵ビューアの道も同じ選び方）: 引き直した本詳細があればその値（未読なら nil）、無ければ一覧の値。
    @Test func currentServerLastPagePrefersTheFetchedDetail() {
        func detail(_ lastPage: Int?) -> BookDetailDTO {
            BookDetailDTO(id: 1, title: "t", author: nil, genre: nil, path: nil, dateAdded: Date(), playDate: nil,
                          bookType: 0, fileType: 0, pages: 20, lastPage: lastPage, rating: 0, unseen: false,
                          keywordA: nil, keywordB: nil, keywordC: nil, neta: nil, memo: nil, series: nil, volume: nil,
                          coverImageName: nil, coverCropRectJSON: nil, pageDirection: nil)
        }
        #expect(RemoteLibraryState.currentServerLastPage(detail: detail(15), listed: 3) == 15)
        #expect(RemoteLibraryState.currentServerLastPage(detail: detail(2), listed: 9) == 2, "戻って読んだ位置も引き直した値に従う")
        #expect(RemoteLibraryState.currentServerLastPage(detail: detail(nil), listed: 3) == nil, "サーバが未読なら未読")
        #expect(RemoteLibraryState.currentServerLastPage(detail: nil, listed: 3) == 3, "取れなければ一覧の値")
    }

    @Test func remoteIssueFailureFallsBackToTheBuiltInViewerWithABanner() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (s, fallbacks) = try makeRemoteState(env, issueStatus: 500)
        s.testPutManifestHandoff(bookID: 43, value: archiveManifest())

        s.openViewer(book: remoteBook(id: 43, filename: "a.zip", lastPage: 0))
        try await waitUntil { !fallbacks.entries.isEmpty }

        #expect(launches.entries.isEmpty)
        #expect(fallbacks.entries.count == 1)
        #expect(fallbacks.entries.first?.manifest?.pageCount == 20, "取得済みの manifest を内蔵へ渡す")
        #expect(s.errorText?.contains("内蔵ビューアで開きました") == true)
        #expect(s.errorText?.contains("トークンを発行できませんでした") == true)
    }

    /// 旧サーバ（viewer-token のルートが無い＝404）は G60 前と同じ挙動なので、知らせずに内蔵で開く。
    @Test func remoteOldServerFallsBackSilently() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (s, fallbacks) = try makeRemoteState(env, issueStatus: 404)
        s.testPutManifestHandoff(bookID: 45, value: archiveManifest())

        s.openViewer(book: remoteBook(id: 45, filename: "a.zip", lastPage: 0))
        try await waitUntil { !fallbacks.entries.isEmpty }

        #expect(G60ViewerTokenStub.paths.contains { $0.hasSuffix("/books/45/viewer-token") })
        #expect(launches.entries.isEmpty)
        #expect(s.errorText == nil)
    }

    /// 旧サーバが 501 を返しても、404 と同じく知らせずに内蔵で開く。
    @Test func remoteNotImplementedFallsBackSilently() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (s, fallbacks) = try makeRemoteState(env, issueStatus: 501)
        s.testPutManifestHandoff(bookID: 46, value: archiveManifest())

        s.openViewer(book: remoteBook(id: 46, filename: "a.zip", lastPage: 0))
        try await waitUntil { !fallbacks.entries.isEmpty }

        #expect(G60ViewerTokenStub.paths.contains { $0.hasSuffix("/books/46/viewer-token") })
        #expect(launches.entries.isEmpty)
        #expect(s.errorText == nil)
    }

    /// 施錠ゲートの 403（パスワード変更など）。他のリモート呼び出しと同じく解錠へ戻し、何も開かない。
    @Test func remoteLockGateAtIssuanceReturnsToUnlockAndOpensNothing() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (s, fallbacks) = try makeRemoteState(
            env, issueStatus: 403, libraryToken: "LIB-TOKEN", issueHeaders: [RemoteClientError.libraryLockedHeader: "1"])
        s.testPutManifestHandoff(bookID: 49, value: archiveManifest())

        s.openViewer(book: remoteBook(id: 49, filename: "a.zip", lastPage: 0))
        try await waitUntil { s.libraryToken == nil || !fallbacks.entries.isEmpty || s.errorText != nil }

        #expect(s.libraryToken == nil, "失効としてトークンを捨てる（解錠フォームへ戻る）")
        #expect(s.locked)
        #expect(s.errorText?.contains("パスワードが変更されました") == true)
        #expect(launches.entries.isEmpty)
        #expect(fallbacks.entries.isEmpty, "内蔵へも倒さない")
    }

    /// 使える外部ビューアが無いときは、トークンを要求せずに黙って内蔵で開く。
    @Test func remoteMissingViewerSkipsTheTokenRequest() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        env.settings.externalViewerAppPath = env.base.appendingPathComponent("Nope.app").path
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (s, fallbacks) = try makeRemoteState(env, issueStatus: 200)
        s.testPutManifestHandoff(bookID: 47, value: archiveManifest())

        s.openViewer(book: remoteBook(id: 47, filename: "a.zip", lastPage: 0))
        try await waitUntil { !fallbacks.entries.isEmpty }

        #expect(!G60ViewerTokenStub.paths.contains { $0.hasSuffix("/viewer-token") })
        #expect(launches.entries.isEmpty)
        #expect(s.errorText == nil)
    }

    /// G60 v3: 参照ファイルの型だけを宣言した外部ビューアには、トークンを要求せずに黙って内蔵で開く。
    @Test func remoteTypeOnlyViewerSkipsTheTokenRequest() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        try Self.writeTypeOnlyInfoPlist(env.viewerApp)
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (s, fallbacks) = try makeRemoteState(env, issueStatus: 200)
        s.testPutManifestHandoff(bookID: 52, value: archiveManifest())

        s.openViewer(book: remoteBook(id: 52, filename: "a.zip", lastPage: 0))
        try await waitUntil { !fallbacks.entries.isEmpty }
        try await Task.sleep(for: .milliseconds(50))

        #expect(fallbacks.entries.count == 1, "内蔵ビューアで開く")
        #expect(!G60ViewerTokenStub.paths.contains { $0.hasSuffix("/viewer-token") })
        #expect(launches.entries.isEmpty)
        #expect(referenceFiles(env).isEmpty)
        #expect(s.errorText == nil)
    }

    @Test func remoteSyncOffStaysBuiltIn() async throws {
        let env = try makeEnv(sync: false); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (s, fallbacks) = try makeRemoteState(env, issueStatus: 200)
        s.testPutManifestHandoff(bookID: 44, value: archiveManifest())

        s.openViewer(book: remoteBook(id: 44, filename: "a.zip", lastPage: 0))

        // 同期 OFF なら内蔵の本体が**同期的に**呼ばれる（参照ファイルの Task を作っていれば、ここではまだ呼ばれない）。
        #expect(fallbacks.entries.count == 1)
        try await Task.sleep(for: .milliseconds(50))   // 余計な Task があれば、ここで走り出す
        #expect(fallbacks.entries.count == 1)
        #expect(launches.entries.isEmpty)
        #expect(!G60ViewerTokenStub.paths.contains { $0.hasSuffix("/viewer-token") })
    }

    final class FakeViewerWindow: ViewerWindowControlling {
        var focused = 0
        func focus() { focused += 1 }
        func close() {}
    }

    /// この本の内蔵窓が既に開いているなら、従来どおり前面化するだけ（外部ビューアへ渡さない）。
    @Test func remoteOpenBuiltInWindowIsFrontedInsteadOfHandingOff() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (s, fallbacks) = try makeRemoteState(env, issueStatus: 200)
        s.testPutManifestHandoff(bookID: 50, value: archiveManifest())
        let identity = ViewerIdentity.remote(serverID: s.serverID.uuidString, libraryUUID: s.libraryUUID, bookID: 50)
        let window = FakeViewerWindow()
        #expect(ViewerWindowRegistry.shared.beginOpen(identity))
        ViewerWindowRegistry.shared.finishOpen(identity, controller: window)
        defer { ViewerWindowRegistry.shared.unregister(controller: window) }

        s.openViewer(book: remoteBook(id: 50, filename: "a.zip", lastPage: 0))

        #expect(window.focused == 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!G60ViewerTokenStub.paths.contains { $0.hasSuffix("/viewer-token") })
        #expect(launches.entries.isEmpty)
        #expect(fallbacks.entries.isEmpty)
    }

    // MARK: - G60 v3: 中継（spec §5.8・試用）

    /// 中継を切ると（§5.6 の直接つなぐ形）、参照ファイルにはサーバの URL とリモートの鍵を書く。
    @Test func remoteDirectModePointsAtTheServer() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (s, _) = try makeRemoteState(env, issueStatus: 200, relay: false)
        s.testPutManifestHandoff(bookID: 61, value: archiveManifest())

        s.openViewer(book: remoteBook(id: 61, filename: "a.zip", lastPage: 0))
        try await waitUntil { !launches.entries.isEmpty }

        let ref = try StackNestBookReference.load(contentsOf: try #require(launches.entries.first).file)
        #expect(ref.bookURL.absoluteString == "http://127.0.0.1:1/api/v1/libraries/\(s.libraryUUID)/books/61")
        #expect(ref.token == "VIEWER-TOKEN")
        #expect(ref.expiresAt == Date(timeIntervalSince1970: 2_000_000_000))
        #expect(env.relays.count == 0)
        #expect(env.tokens.allRecords().isEmpty, "直接つなぐ形では手元の鍵を出さない")
        try await waitUntil { G60ViewerTokenStub.paths.contains { $0.hasSuffix("/books/61/progress") } }
    }

    /// 中継には 127.0.0.1 の口が要る。動いていなければ、リモートの鍵も出してもらわずに内蔵で開き、理由を出す。
    @Test func remoteRelayNeedsTheLocalEndpoint() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (s, fallbacks) = try makeRemoteState(env, issueStatus: 200, endpointRunning: false)
        s.testPutManifestHandoff(bookID: 60, value: archiveManifest())

        s.openViewer(book: remoteBook(id: 60, filename: "a.zip", lastPage: 0))
        try await waitUntil { !fallbacks.entries.isEmpty }

        #expect(launches.entries.isEmpty)
        #expect(!G60ViewerTokenStub.paths.contains { $0.hasSuffix("/viewer-token") })
        #expect(env.relays.count == 0)
        #expect(env.tokens.allRecords().isEmpty)
        #expect(s.errorText?.contains("内蔵ビューアで開きました") == true)
        #expect(s.errorText?.contains("127.0.0.1") == true)
    }

    /// G60 §5.9 最終レビュー m4: リモートの鍵を出してもらう往復のあいだに 127.0.0.1 の口が止まったら、中継の記録も
    /// 参照ファイルも作らず、ビューアも起動せず、先読みも始めない（口を止めた後に先読みが 1 回分走らない）。
    @Test func remoteRelayEndpointStoppedDuringIssuanceStartsNoPrefetch() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let endpoint = EndpointFlag()
        let prefetches = Prefetches()
        let h = handoff(env, endpoint: endpoint, prefetches: prefetches)
        let viewer = try #require(HelperLauncher.referenceViewer(category: .archive, settings: env.settings))
        let reply = ViewerTokenReply(token: "VIEWER-TOKEN", expiresAt: Date(timeIntervalSince1970: 2_000_000_000), tokenID: "TID-1")

        let failure = await h.openRemote(
            book: remoteBook(id: 65, filename: "a.zip", lastPage: 0), manifest: archiveManifest(), viewer: viewer,
            serverID: UUID(), serverBase: URL(string: "http://127.0.0.1:1/")!, libraryUUID: "LIB-X", startPage: 0,
            settings: env.settings,
            issue: {
                endpoint.running = false   // 往復のあいだに、作者が同期とローカルコントロールを OFF にする
                return reply
            },
            fetchStatus: { _ in throw CancellationError() })

        #expect(failure == .localEndpointNotRunning)
        #expect(launches.entries.isEmpty)
        #expect(prefetches.items.isEmpty)
        #expect(env.relays.count == 0)
        #expect(env.tokens.allRecords().isEmpty)
    }

    /// レビュー I-4: リモートの鍵が先に切れる（今から 1 時間）なら、参照ファイルと中継の記録はその時刻で切れる
    /// （中継の鍵は 30 日あっても、リモートの鍵が切れたら中継しても 401 になるため）。
    @Test func remoteRelayExpiresWithTheRemoteTokenWhenItIsSooner() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        // JSON の ISO 8601 は秒までなので、比べる値も秒に丸めておく。
        let remoteExpiry = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 3600).rounded(.down))
        let (s, _) = try makeRemoteState(env, issueStatus: 200, issueExpiresAt: remoteExpiry)
        s.testPutManifestHandoff(bookID: 62, value: archiveManifest())

        s.openViewer(book: remoteBook(id: 62, filename: "a.zip", lastPage: 0))
        try await waitUntil { !launches.entries.isEmpty }

        let ref = try StackNestBookReference.load(contentsOf: try #require(launches.entries.first).file)
        #expect(abs(ref.expiresAt.timeIntervalSince(remoteExpiry)) < 1, "リモートの鍵の期限に合わせる")
        guard case .valid(let relayRecord) = env.tokens.lookup(token: ref.token, issuer: .localEndpoint) else {
            Issue.record("参照ファイルの鍵が中継の鍵になっていない"); return
        }
        #expect(relayRecord.expiresAt > remoteExpiry, "中継の鍵そのものは 30 日")
        #expect(abs(ref.expiresAt.timeIntervalSince(min(relayRecord.expiresAt, remoteExpiry))) < 1)
        let relayID = try #require(relayRecord.relayID)
        #expect(env.relays.target(for: relayID, now: remoteExpiry.addingTimeInterval(-1)) != nil)
        #expect(env.relays.target(for: relayID, now: remoteExpiry) == nil, "中継の記録もリモートの鍵と一緒に切れる")
        try await waitUntil { G60ViewerTokenStub.paths.contains { $0.hasSuffix("/books/62/progress") } }
    }

    // MARK: - G60 v3: 渡した後の確認

    @Test func localUnusedTokenShowsANoticeWithTheUsualWay() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let delays = Delays()
        let (state, row, dir) = try makeLocalState(env, handoff: handoff(env, sleep: { delays.append($0) }))

        state.openBooks([row])
        try await waitUntil { state.watchNotice.notice != nil }

        #expect(delays.values == [.seconds(15)], "既定は 15 秒・一度だけ")
        let notice = try #require(state.watchNotice.notice)
        #expect(notice.kind == .warning)
        #expect(notice.text == "FakeViewer が本を読み込んでいません")
        let action = try #require(notice.action)
        #expect(action.title == "従来の開き方で開く")
        // トークンは取り消さない（ビューアが遅れて読み始めても動く）。
        let ref = try StackNestBookReference.load(contentsOf: try #require(launches.entries.first).file)
        guard case .valid = env.tokens.lookup(token: ref.token, issuer: .localEndpoint) else {
            Issue.record("お知らせを出してもトークンは有効のまま"); return
        }
        action.perform()
        #expect(launches.entries.count == 2)
        #expect(launches.entries.last?.file.path == dir.path, "従来の開き方＝ファイルのまま外部ビューア")
        #expect(launches.entries.last?.viewer.path == env.viewerApp.path)
    }

    @Test func localUsedTokenShowsNothing() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let tokens = env.tokens
        let delays = Delays()
        let (state, row, _) = try makeLocalState(env, handoff: handoff(env, sleep: { d in
            // 待ちの間にビューアが読んだことにする。
            for r in tokens.allRecords() { tokens.recordFirstUse(id: r.id, viewer: "com.example.fakeviewer/1.80; format=1") }
            delays.append(d)
        }))

        state.openBooks([row])
        try await waitUntil { !delays.values.isEmpty }
        try await Task.sleep(for: .milliseconds(50))   // お知らせが出るなら、ここで出る

        #expect(state.watchNotice.notice == nil)
    }

    @Test func useCheckDelayComesFromTheHiddenKey() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        env.suite.set(3, forKey: ViewerSettings.viewerUseCheckDelayKey)
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let delays = Delays()
        let (state, row, _) = try makeLocalState(env, handoff: handoff(env, sleep: { delays.append($0) }))

        state.openBooks([row])
        try await waitUntil { !delays.values.isEmpty }

        #expect(delays.values == [.seconds(3)])
    }

    @Test func remoteUnusedTokenShowsANoticeWithTheBuiltInViewer() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (s, fallbacks) = try makeRemoteState(env, issueStatus: 200, sleep: { _ in })
        s.testPutManifestHandoff(bookID: 53, value: archiveManifest())

        s.openViewer(book: remoteBook(id: 53, filename: "a.zip", lastPage: 0))
        try await waitUntil { s.viewerNotice.notice != nil }

        #expect(!G60ViewerTokenStub.paths.contains { $0.hasPrefix("GET /api/v1/viewer-tokens/") },
                "中継のときは手元の保存先で中継の鍵を確かめる（照会 API は使わない・spec §5.8）")
        let notice = try #require(s.viewerNotice.notice)
        #expect(notice.kind == .warning)
        #expect(notice.text == "FakeViewer が本を読み込んでいません")
        #expect(fallbacks.entries.isEmpty)
        try #require(notice.action).perform()
        #expect(fallbacks.entries.count == 1, "従来の開き方＝内蔵ビューア")
        #expect(fallbacks.entries.first?.bookID == 53)
        #expect(fallbacks.entries.first?.manifest == nil, "遅れて押されても古い manifest を使わず、内蔵ビューアが取り直す")
        try await waitUntil { G60ViewerTokenStub.paths.contains { $0.hasSuffix("/books/53/progress") } }
    }

    /// 中継の鍵が使われていれば（ビューアが 127.0.0.1 の中継から読んだ）、何も出さない。
    @Test func remoteUsedTokenShowsNothing() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let tokens = env.tokens
        let delays = Delays()
        let (s, _) = try makeRemoteState(env, issueStatus: 200, sleep: { d in
            // 待ちの間にビューアが中継から読んだことにする（中継の鍵の初回使用）。
            for r in tokens.allRecords() { tokens.recordFirstUse(id: r.id, viewer: "com.example.fakeviewer/1.80; format=1") }
            delays.append(d)
        })
        s.testPutManifestHandoff(bookID: 54, value: archiveManifest())

        s.openViewer(book: remoteBook(id: 54, filename: "a.zip", lastPage: 0))
        try await waitUntil { !delays.values.isEmpty }
        try await waitUntil { G60ViewerTokenStub.paths.contains { $0.hasSuffix("/books/54/progress") } }
        try await Task.sleep(for: .milliseconds(50))

        #expect(s.viewerNotice.notice == nil)
        #expect(!G60ViewerTokenStub.paths.contains { $0.hasPrefix("GET /api/v1/viewer-tokens/") })
    }

    /// 中継を切った形（§5.6）では、確認はリモートの照会 API で行う。
    @Test func remoteDirectModeChecksThroughTheStatusAPI() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (s, _) = try makeRemoteState(env, issueStatus: 200, relay: false, sleep: { _ in })
        s.testPutManifestHandoff(bookID: 63, value: archiveManifest())

        s.openViewer(book: remoteBook(id: 63, filename: "a.zip", lastPage: 0))
        try await waitUntil { s.viewerNotice.notice != nil }

        #expect(G60ViewerTokenStub.paths.contains("GET /api/v1/viewer-tokens/TID-1"))
        try await waitUntil { G60ViewerTokenStub.paths.contains { $0.hasSuffix("/books/63/progress") } }
    }

    /// 中継を切った形で照会に失敗したら（500・通信の失敗）確かめられないので、何も出さない。
    @Test func remoteStatusFailureIsSilent() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (s, _) = try makeRemoteState(env, issueStatus: 200, relay: false, statusStatus: 500, sleep: { _ in })
        s.testPutManifestHandoff(bookID: 55, value: archiveManifest())

        s.openViewer(book: remoteBook(id: 55, filename: "a.zip", lastPage: 0))
        try await waitUntil { G60ViewerTokenStub.paths.contains("GET /api/v1/viewer-tokens/TID-1") }
        try await waitUntil { G60ViewerTokenStub.paths.contains { $0.hasSuffix("/books/55/progress") } }
        try await Task.sleep(for: .milliseconds(50))

        #expect(s.viewerNotice.notice == nil)
        #expect(s.errorText == nil)
    }

    @Test func checkUseIsUnknownWhenTheWaitIsCancelled() async {
        let cancelled = await ExternalViewerHandoff.checkUse(
            after: .seconds(15), sleep: { _ in throw CancellationError() }, read: { .notUsed })
        #expect(cancelled == .unknown, "待ちが取り消されたら確かめない")
        let read = await ExternalViewerHandoff.checkUse(after: .seconds(15), sleep: { _ in }, read: { .notUsed })
        #expect(read == .notUsed)
    }

    @Test func outcomeOfALocalRecord() throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        #expect(ExternalViewerHandoff.outcome(of: nil) == .unknown)
        let issued = env.tokens.issue(libraryUUID: "LIB-1", bookID: 1, issuer: .localEndpoint, lockCredential: nil)
        #expect(ExternalViewerHandoff.outcome(of: env.tokens.record(id: issued.record.id)) == .notUsed)
        let usedAt = Date(timeIntervalSince1970: 1_800_000_000)
        env.tokens.recordFirstUse(id: issued.record.id, viewer: "com.example.fakeviewer/1.80; format=1", now: usedAt)
        #expect(ExternalViewerHandoff.outcome(of: env.tokens.record(id: issued.record.id))
                == .used(firstUsedAt: usedAt, viewer: "com.example.fakeviewer/1.80; format=1"))
    }

    // MARK: - G60 v3: 確認できた対応ビューアと設定の状態

    /// 鍵は渡した先のアプリの bundle id（`com.example.fakeviewer`）。版は名乗りから。
    @Test func localUseIsRecordedAsAConfirmedViewer() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let tokens = env.tokens
        let usedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let (state, row, _) = try makeLocalState(env, handoff: handoff(env, sleep: { _ in
            for r in tokens.allRecords() {
                tokens.recordFirstUse(id: r.id, viewer: "com.example.viewer/1.80; format=1", now: usedAt)
            }
        }))

        state.openBooks([row])
        try await waitUntil { env.confirmed.confirmed(bundleIdentifier: "com.example.fakeviewer") != nil }

        let seen = try #require(env.confirmed.confirmed(bundleIdentifier: "com.example.fakeviewer"))
        #expect(seen.viewerVersion == "1.80")
        #expect(seen.formatVersion == 1)
        #expect(abs(seen.confirmedAt.timeIntervalSince(usedAt)) < 0.001)
        #expect(env.confirmed.confirmed(bundleIdentifier: "com.example.viewer") == nil)
        #expect(state.watchNotice.notice == nil)
    }

    /// リモートの本（中継）でも、中継の鍵の初回使用で確認できた対応ビューアを記録する。
    @Test func remoteUseIsRecordedAsAConfirmedViewer() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let tokens = env.tokens
        let usedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let (s, _) = try makeRemoteState(env, issueStatus: 200, sleep: { _ in
            for r in tokens.allRecords() {
                tokens.recordFirstUse(id: r.id, viewer: "com.example.viewer/1.80; format=1", now: usedAt)
            }
        })
        s.testPutManifestHandoff(bookID: 56, value: archiveManifest())

        s.openViewer(book: remoteBook(id: 56, filename: "a.zip", lastPage: 0))
        try await waitUntil { env.confirmed.confirmed(bundleIdentifier: "com.example.fakeviewer") != nil }

        let seen = try #require(env.confirmed.confirmed(bundleIdentifier: "com.example.fakeviewer"))
        #expect(abs(seen.confirmedAt.timeIntervalSince(usedAt)) < 0.001)
        #expect(seen.viewerVersion == "1.80")
        #expect(s.viewerNotice.notice == nil)
        try await waitUntil { G60ViewerTokenStub.paths.contains { $0.hasSuffix("/books/56/progress") } }
    }

    @Test func unusedTokenRecordsNoConfirmedViewer() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (state, row, _) = try makeLocalState(env, handoff: handoff(env, sleep: { _ in }))

        state.openBooks([row])
        try await waitUntil { state.watchNotice.notice != nil }

        #expect(env.confirmed.confirmed(bundleIdentifier: "com.example.fakeviewer") == nil)
    }

    @Test func statusLineTexts() {
        #expect(ExternalViewerSupportStatusText.line(.none) == nil)
        #expect(ExternalViewerSupportStatusText.line(.unsupported(appName: "FakeViewer"))
                == "FakeViewer：未対応（今までどおり開きます）")
        #expect(ExternalViewerSupportStatusText.line(.declared(appName: "FakeViewer"))
                == "FakeViewer：対応を宣言（未確認）")
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let date = at.formatted(date: .abbreviated, time: .shortened)
        #expect(ExternalViewerSupportStatusText.line(.confirmed(appName: "FakeViewer", at: at, viewerVersion: "1.80"))
                == "FakeViewer：対応を確認（\(date)・1.80）")
        #expect(ExternalViewerSupportStatusText.line(.confirmed(appName: "FakeViewer", at: at, viewerVersion: nil))
                == "FakeViewer：対応を確認（\(date)）")
    }

    /// 直接つなぐ形で窓を閉じたら（待っている確認を取り消す）、閉じた後に照会を投げない。
    @Test func closingTheWindowCancelsAPendingStatusQuery() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let waits = Delays()
        let (s, _) = try makeRemoteState(env, issueStatus: 200, relay: false, sleep: {
            waits.append($0)
            try await Task.sleep(for: .milliseconds(400))
        })
        s.testPutManifestHandoff(bookID: 67, value: archiveManifest())

        s.openViewer(book: remoteBook(id: 67, filename: "a.zip", lastPage: 0))
        try await waitUntil { !waits.values.isEmpty }
        s.cancelViewerUseChecks()
        try await waitUntil { G60ViewerTokenStub.paths.contains { $0.hasSuffix("/books/67/progress") } }
        try await Task.sleep(for: .milliseconds(900))

        #expect(!G60ViewerTokenStub.paths.contains { $0.hasPrefix("GET /api/v1/viewer-tokens/") },
                "閉じた後に使用の照会を投げない")
        #expect(s.viewerNotice.notice == nil)
    }

    /// 中継の確認は手元の保存先を読むだけなので、窓を閉じても走り続け、確認できたビューアの記録を失わない。
    @Test func closingTheWindowKeepsARelayCheckRunning() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let tokens = env.tokens
        let waits = Delays()
        let usedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let (s, _) = try makeRemoteState(env, issueStatus: 200, relay: true, sleep: {
            waits.append($0)
            try await Task.sleep(for: .milliseconds(400))
            for r in tokens.allRecords() {
                tokens.recordFirstUse(id: r.id, viewer: "com.example.viewer/1.80; format=1", now: usedAt)
            }
        })
        s.testPutManifestHandoff(bookID: 68, value: archiveManifest())

        s.openViewer(book: remoteBook(id: 68, filename: "a.zip", lastPage: 0))
        try await waitUntil { !waits.values.isEmpty }
        s.cancelViewerUseChecks()
        try await waitUntil { env.confirmed.confirmed(bundleIdentifier: "com.example.fakeviewer") != nil }

        let seen = try #require(env.confirmed.confirmed(bundleIdentifier: "com.example.fakeviewer"))
        #expect(seen.viewerVersion == "1.80")
    }

    /// 中継を切った形で v2 のサーバ（`tokenID` の無い応答）でも参照ファイルで渡し、確認は走らせない（待ちも照会も無い）。
    /// 中継のときは手元の中継の鍵で確かめるので、この許容は中継を切った形だけに残る。
    @Test func remoteReplyWithoutTokenIDHandsOffWithoutACheck() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let delays = Delays()
        let (s, fallbacks) = try makeRemoteState(env, issueStatus: 200, relay: false, sleep: { delays.append($0) })
        G60ViewerTokenStub.issueBody = Data(#"{"token":"VIEWER-TOKEN","expiresAt":"2033-05-18T03:33:20Z"}"#.utf8)
        s.testPutManifestHandoff(bookID: 57, value: archiveManifest())

        s.openViewer(book: remoteBook(id: 57, filename: "a.zip", lastPage: 0))
        try await waitUntil { !launches.entries.isEmpty }
        try await waitUntil { G60ViewerTokenStub.paths.contains { $0.hasSuffix("/books/57/progress") } }
        try await Task.sleep(for: .milliseconds(50))

        let ref = try StackNestBookReference.load(contentsOf: try #require(launches.entries.first).file)
        #expect(ref.token == "VIEWER-TOKEN")
        #expect(fallbacks.entries.isEmpty)
        #expect(s.errorText == nil, "発行は成功している（v2 のサーバを失敗と取り違えない）")
        #expect(delays.values.isEmpty, "確認を走らせない")
        #expect(!G60ViewerTokenStub.paths.contains { $0.hasPrefix("GET /api/v1/viewer-tokens/") })
        #expect(s.viewerNotice.notice == nil)
    }

    /// 切り替えられる「ビューアが読んだか」（`sleep` の中で見る）。
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var on = false
        var value: Bool {
            get { lock.withLock { on } }
            set { lock.withLock { on = newValue } }
        }
    }

    /// 後の確認で使用が確かめられたら、前に出した「読み込んでいません」を消す。
    @Test func laterUsedCheckDismissesTheNotLoadedNotice() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let tokens = env.tokens
        let viewerReads = Flag()
        let (state, row, _) = try makeLocalState(env, handoff: handoff(env, sleep: { _ in
            guard viewerReads.value else { return }
            for r in tokens.allRecords() { tokens.recordFirstUse(id: r.id, viewer: "com.example.fakeviewer/1.80; format=1") }
        }))

        state.openBooks([row])
        try await waitUntil { state.watchNotice.notice != nil }
        viewerReads.value = true
        state.openBooks([row])
        try await waitUntil { state.watchNotice.notice == nil }

        #expect(launches.entries.count == 2)
    }

    /// 2 冊のフォルダの本（id 1・2）を持つローカルの書庫。
    private func makeTwoBookState(_ env: Env, handoff: ExternalViewerHandoff) throws -> (AppState, [BookRow], [URL]) {
        let db = try Database.openInMemory()
        try db.migrate()
        var dirs: [URL] = []
        for id in 1...2 {
            let dir = env.base.appendingPathComponent("folder-book-\(id)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for i in 0..<2 { try Data("p\(i)".utf8).write(to: dir.appendingPathComponent("p\(i).jpg")) }
            try db.insertBook(BookRecord(
                id: id, title: "Book \(id)", author: nil, genre: nil,
                path: dir.path, dateAdded: Date(timeIntervalSince1970: 100), playDate: nil,
                bookType: 0, fileType: 2, pages: 2, myRate: 0, unseen: true,
                keywordA: nil, keywordB: nil, keywordC: nil, neta: nil))
            dirs.append(dir)
        }
        let state = AppState(bundleURL: env.base.appendingPathComponent("g60-two.stacknest"))
        state.database = db
        state.librarySettings = try LibrarySettings(database: db)
        state.viewerSettings = env.settings
        state.viewerHandoff = handoff
        let rows = try (1...2).map { try #require(try db.fetchBook(id: $0)) }
        return (state, rows, dirs)
    }

    /// 2 冊を選んで開き、1 冊目だけが読まれなかった: 2 冊目が読まれたことでお知らせを消さず、ボタンは 1 冊目だけを開く。
    @Test func severalBooksKeepTheNoticeForTheUnreadBook() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let tokens = env.tokens
        let checks = Delays()
        // 確かめる前に、2 冊目（本 2）の鍵だけを使われたことにする（ビューアが 2 冊目だけ読んだ）。
        let (state, rows, dirs) = try makeTwoBookState(env, handoff: handoff(env, sleep: { d in
            for r in tokens.allRecords() where r.bookID == 2 {
                tokens.recordFirstUse(id: r.id, viewer: "com.example.fakeviewer/1.80; format=1")
            }
            checks.append(d)
        }))

        await state.openInExternalViewerSyncing(rows)
        try await waitUntil { checks.values.count == 2 && state.watchNotice.notice != nil }
        try await Task.sleep(for: .milliseconds(100))

        let notice = try #require(state.watchNotice.notice, "2 冊目が読まれても、1 冊目のお知らせは残る")
        #expect(notice.text == "FakeViewer が本を読み込んでいません")
        let before = launches.entries.count
        try #require(notice.action).perform()
        #expect(launches.entries.dropFirst(before).map(\.file.path) == [dirs[0].path], "従来の開き方で開くのは読まれなかった 1 冊目だけ")
    }

    /// 2 冊とも読まれなかった: お知らせは 1 つにまとまり、ボタンは 2 冊とも開く。前の受け渡しのお知らせは、後で読まれたら消える。
    @Test func severalUnreadBooksShareOneNotice() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let tokens = env.tokens
        let viewerReads = Flag()
        let checks = Delays()
        let (state, rows, dirs) = try makeTwoBookState(env, handoff: handoff(env, sleep: { d in
            if viewerReads.value {
                for r in tokens.allRecords() { tokens.recordFirstUse(id: r.id, viewer: "com.example.fakeviewer/1.80; format=1") }
            }
            checks.append(d)
        }))

        await state.openInExternalViewerSyncing(rows)
        try await waitUntil { checks.values.count == 2 && state.watchNotice.notice?.text.contains("2 冊") == true }
        let notice = try #require(state.watchNotice.notice)
        #expect(notice.text == "FakeViewer が 2 冊の本を読み込んでいません")
        let before = launches.entries.count
        try #require(notice.action).perform()
        #expect(launches.entries.dropFirst(before).map(\.file.path) == dirs.map(\.path))

        // 開き直した 1 冊が今度は読まれた（別の受け渡し）: 前の受け渡しのお知らせを消す。
        viewerReads.value = true
        await state.openInExternalViewerSyncing([rows[0]])
        try await waitUntil { state.watchNotice.notice == nil }
    }

    /// 使用が確かめられても、同じ枠の別のお知らせ（監視フォルダなど）は消さない。
    @Test func usedCheckLeavesOtherNoticesAlone() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let tokens = env.tokens
        let delays = Delays()
        let (state, row, _) = try makeLocalState(env, handoff: handoff(env, sleep: { d in
            for r in tokens.allRecords() { tokens.recordFirstUse(id: r.id, viewer: "com.example.fakeviewer/1.80; format=1") }
            delays.append(d)
        }))
        state.watchNotice.present(Notice(kind: .warning, text: "取り込みに失敗しました"))

        state.openBooks([row])
        try await waitUntil { !delays.values.isEmpty }
        try await Task.sleep(for: .milliseconds(50))

        #expect(state.watchNotice.notice?.text == "取り込みに失敗しました")
    }

    @Test func remoteLaterUsedCheckDismissesTheNotice() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let tokens = env.tokens
        let viewerReads = Flag()
        let (s, _) = try makeRemoteState(env, issueStatus: 200, sleep: { _ in
            guard viewerReads.value else { return }
            for r in tokens.allRecords() { tokens.recordFirstUse(id: r.id, viewer: "com.example.fakeviewer/1.80; format=1") }
        })
        // 預かり（`OneShotHandoff`）は 1 件だけなので、本ごとに入れ直す。
        s.testPutManifestHandoff(bookID: 58, value: archiveManifest())

        s.openViewer(book: remoteBook(id: 58, filename: "a.zip", lastPage: 0))
        try await waitUntil { s.viewerNotice.notice != nil }
        viewerReads.value = true
        s.testPutManifestHandoff(bookID: 59, value: archiveManifest())
        s.openViewer(book: remoteBook(id: 59, filename: "b.zip", lastPage: 0))
        try await waitUntil { s.viewerNotice.notice == nil }

        try await waitUntil { G60ViewerTokenStub.paths.contains { $0.hasSuffix("/books/58/progress") } }
        try await waitUntil { G60ViewerTokenStub.paths.contains { $0.hasSuffix("/books/59/progress") } }
    }

    // MARK: - G60 v3: レビューからの取り込み（Task 1 I-1・M-1）

    private func makeSecondViewer(_ env: Env) throws -> URL {
        let other = env.base.appendingPathComponent("OtherViewer.app", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Self.declareReferenceSupport(other)
        return other
    }

    /// I-1: 渡すのは、対応を確かめたビューア（`viewer.appURL`）。確かめた後に設定が変わっても、設定を引き直さない。
    /// （リモート: トークンの発行を待つ間に設定を差し替える。）
    @Test func remoteLaunchesTheViewerThatWasChecked() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let other = try makeSecondViewer(env)
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let h = handoff(env)
        let viewer = try #require(HelperLauncher.referenceViewer(category: .archive, settings: env.settings))
        #expect(viewer.appURL.path == env.viewerApp.path)
        let settings = env.settings
        let reply = ViewerTokenReply(token: "VIEWER-TOKEN", expiresAt: Date(timeIntervalSince1970: 2_000_000_000), tokenID: "TID-1")

        let failure = await h.openRemote(
            book: remoteBook(id: 64, filename: "a.zip", lastPage: 0), manifest: archiveManifest(), viewer: viewer,
            serverID: UUID(), serverBase: URL(string: "http://127.0.0.1:1/")!, libraryUUID: "LIB-X", startPage: 0,
            settings: settings,
            issue: {
                settings.externalViewerAppPath = other.path   // 確認の後・起動の前に設定が変わる
                return reply
            },
            fetchStatus: { _ in throw CancellationError() })

        #expect(failure == nil)
        #expect(launches.entries.count == 1)
        #expect(launches.entries.first?.viewer.path == env.viewerApp.path, "確かめたビューアを起動する（引き直さない）")
    }

    /// Codex P2（2 回目）: ページ数の待ちのあいだに 127.0.0.1 の口が止まったら（ローカルコントロールが OFF で
    /// 同期を OFF にした）、鍵を出さず、参照ファイルも渡さず `.localEndpointNotRunning` を返す（呼び出し側はファイルで開く）。
    /// 待ちの後・発行の前に呼ばれるロックの値の閉包の中で口を止めて、待ちのあいだに止まったことにする。
    @Test func localEndpointStoppedWhileCountingPagesIssuesNothing() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let endpoint = EndpointFlag()
        let h = handoff(env, endpoint: endpoint)
        let (state, row, _) = try makeLocalState(env, handoff: h)
        let viewer = try #require(HelperLauncher.referenceViewer(bookPath: row.path ?? "", settings: env.settings))

        let failure = await h.openLocal(
            book: row, libraryUUID: try #require(state.librarySettings?.ensureLibraryUUID()), viewer: viewer,
            lockCredential: {
                endpoint.running = false
                return nil
            },
            verifiedLockHash: { nil }, startPage: 0, direction: .rightToLeft, settings: env.settings)

        #expect(failure == .localEndpointNotRunning)
        #expect(launches.entries.isEmpty)
        #expect(env.tokens.allRecords().isEmpty)
    }

    /// I-1（ローカル）: ページ数の待ちの後・発行の前にロックの値を読む閉包の中で設定を差し替える。
    @Test func localLaunchesTheViewerThatWasChecked() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let other = try makeSecondViewer(env)
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let h = handoff(env)
        let (state, row, _) = try makeLocalState(env, handoff: h)
        let viewer = try #require(HelperLauncher.referenceViewer(bookPath: row.path ?? "", settings: env.settings))
        let settings = env.settings

        let failure = await h.openLocal(
            book: row, libraryUUID: try #require(state.librarySettings?.ensureLibraryUUID()), viewer: viewer,
            lockCredential: {
                settings.externalViewerAppPath = other.path
                return nil
            },
            verifiedLockHash: { nil }, startPage: 0, direction: .rightToLeft, settings: settings)

        #expect(failure == nil)
        #expect(launches.entries.first?.viewer.path == env.viewerApp.path)
        #expect(launches.entries.count == 1)
    }

    /// 確かめたビューアが消えていたら（確認の後に削除）、起動せずに理由を返す（`fileExists` の見張りは残す）。
    @Test func vanishedCheckedViewerIsNotLaunched() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let h = handoff(env)
        let viewer = try #require(HelperLauncher.referenceViewer(category: .archive, settings: env.settings))
        let app = env.viewerApp
        let reply = ViewerTokenReply(token: "VIEWER-TOKEN", expiresAt: Date(timeIntervalSince1970: 2_000_000_000), tokenID: "TID-1")

        let failure = await h.openRemote(
            book: remoteBook(id: 65, filename: "a.zip", lastPage: 0), manifest: archiveManifest(), viewer: viewer,
            serverID: UUID(), serverBase: URL(string: "http://127.0.0.1:1/")!, libraryUUID: "LIB-X", startPage: 0,
            settings: env.settings,
            issue: {
                try? FileManager.default.removeItem(at: app)
                return reply
            },
            fetchStatus: { _ in throw CancellationError() })

        guard case .launchFailed = failure else { Issue.record("起動に失敗した理由を返す: \(String(describing: failure))"); return }
        #expect(launches.entries.isEmpty)
    }

    // MARK: - G60 §5.9: 中継の本の先読み

    private func remoteReply() -> ViewerTokenReply {
        ViewerTokenReply(token: "VIEWER-TOKEN", expiresAt: Date(timeIntervalSince1970: 2_000_000_000), tokenID: "TID-1")
    }

    /// 中継の本を渡せたら、その中継の先読みを始める（中心は開くページ。範囲は先読み係が設定に従って決める）。
    /// 中継の記録には、渡す時点の manifest のページ数と etag（キャッシュのキーの版）を持たせる。
    @Test func relayedHandOffStartsThePrefetch() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let prefetches = Prefetches()
        let h = handoff(env, prefetches: prefetches)
        let viewer = try #require(HelperLauncher.referenceViewer(category: .archive, settings: env.settings))
        let reply = remoteReply()

        let failure = await h.openRemote(
            book: remoteBook(id: 70, filename: "a.zip", lastPage: 0),
            manifest: ManifestDTO(pageCount: 20, direction: "rtl", format: "archive", etag: "\"e7\""),
            viewer: viewer, serverID: UUID(), serverBase: URL(string: "http://127.0.0.1:1/")!, libraryUUID: "LIB-X",
            startPage: 7, settings: env.settings,
            issue: { reply }, fetchStatus: { _ in throw CancellationError() })

        #expect(failure == nil)
        let ref = try StackNestBookReference.load(contentsOf: try #require(launches.entries.first).file)
        let relayID = String(ref.bookURL.absoluteString.dropFirst("http://127.0.0.1:4321/api/v1/relay/".count))
        #expect(prefetches.items.map { $0.relayID } == [relayID])
        #expect(prefetches.items.map { $0.focus } == [7])
        let target = try #require(env.relays.target(for: relayID))
        #expect(target.pageCount == 20)
        #expect(target.manifestETag == "\"e7\"")
    }

    /// 続きのページが範囲を超えていても、先読みの中心は最後のページに収まる。
    @Test func prefetchFocusIsClampedToTheLastPage() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let prefetches = Prefetches()
        let h = handoff(env, prefetches: prefetches)
        let viewer = try #require(HelperLauncher.referenceViewer(category: .archive, settings: env.settings))
        let reply = remoteReply()

        let failure = await h.openRemote(
            book: remoteBook(id: 72, filename: "a.zip", lastPage: 0),
            manifest: ManifestDTO(pageCount: 20, direction: "rtl", format: "archive", etag: "\"e7\""),
            viewer: viewer, serverID: UUID(), serverBase: URL(string: "http://127.0.0.1:1/")!, libraryUUID: "LIB-X",
            startPage: 25, settings: env.settings,
            issue: { reply }, fetchStatus: { _ in throw CancellationError() })

        #expect(failure == nil)
        #expect(prefetches.items.map { $0.focus } == [19])
    }

    /// 渡せなかったら（確かめたビューアが消えていた）先読みしない。
    @Test func noPrefetchWhenTheHandOffFails() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let prefetches = Prefetches()
        let h = handoff(env, prefetches: prefetches)
        let viewer = try #require(HelperLauncher.referenceViewer(category: .archive, settings: env.settings))
        let app = env.viewerApp
        let reply = remoteReply()

        let failure = await h.openRemote(
            book: remoteBook(id: 71, filename: "a.zip", lastPage: 0), manifest: archiveManifest(), viewer: viewer,
            serverID: UUID(), serverBase: URL(string: "http://127.0.0.1:1/")!, libraryUUID: "LIB-X", startPage: 0,
            settings: env.settings,
            issue: {
                try? FileManager.default.removeItem(at: app)
                return reply
            },
            fetchStatus: { _ in throw CancellationError() })

        guard case .launchFailed = failure else { Issue.record("起動に失敗した理由を返す: \(String(describing: failure))"); return }
        #expect(prefetches.items.isEmpty)
    }

    /// 中継を切った形（§5.6 の直接つなぐ形）では、中継が無いので先読みもしない。
    @Test func noPrefetchInDirectMode() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let prefetches = Prefetches()
        let h = handoff(env, relay: false, prefetches: prefetches)
        let viewer = try #require(HelperLauncher.referenceViewer(category: .archive, settings: env.settings))
        let reply = remoteReply()

        let failure = await h.openRemote(
            book: remoteBook(id: 72, filename: "a.zip", lastPage: 0), manifest: archiveManifest(), viewer: viewer,
            serverID: UUID(), serverBase: URL(string: "http://127.0.0.1:1/")!, libraryUUID: "LIB-X", startPage: 0,
            settings: env.settings, issue: { reply }, fetchStatus: { _ in throw CancellationError() })

        #expect(failure == nil)
        #expect(!launches.entries.isEmpty)
        #expect(prefetches.items.isEmpty)
    }

    /// M-1: 将来の版を併せて宣言していても、リモートの参照ファイルは StackNest が書ける最大（1）で書く。
    @Test func remoteReferenceUsesTheNegotiatedVersion() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        try Self.declareReferenceSupport(env.viewerApp, versions: [1, 9])
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (s, _) = try makeRemoteState(env, issueStatus: 200)
        s.testPutManifestHandoff(bookID: 66, value: archiveManifest())

        s.openViewer(book: remoteBook(id: 66, filename: "a.zip", lastPage: 0))
        try await waitUntil { !launches.entries.isEmpty }

        let ref = try StackNestBookReference.load(contentsOf: try #require(launches.entries.first).file)
        #expect(ref.version == 1)
        try await waitUntil { G60ViewerTokenStub.paths.contains { $0.hasSuffix("/books/66/progress") } }
    }

    /// G63 段 4: 部品の型は、読む側が断る値（ページ数が上限を超える本など）では作れない。作れなければ参照ファイルを
    /// 書かず、ビューアも起動せず、先読みも始めない（`.referenceNotWritten`＝今の「従来の開き方」に合流する）。
    @Test func aReferenceTheKitRefusesIsNotHandedOff() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let prefetches = Prefetches()
        let h = handoff(env, prefetches: prefetches)
        let viewer = try #require(HelperLauncher.referenceViewer(category: .archive, settings: env.settings))
        let reply = remoteReply()

        let failure = await h.openRemote(
            book: remoteBook(id: 71, filename: "big.zip", lastPage: 0),
            manifest: ManifestDTO(pageCount: StackNestFormat.maxPageCount + 1, direction: "rtl", format: "archive",
                                  etag: "\"e8\""),
            viewer: viewer, serverID: UUID(), serverBase: URL(string: "http://127.0.0.1:1/")!, libraryUUID: "LIB-X",
            startPage: 0, settings: env.settings,
            issue: { reply }, fetchStatus: { _ in throw CancellationError() })

        #expect(failure == .referenceNotWritten)
        #expect(launches.entries.isEmpty, "ビューアを起動しない")
        #expect(prefetches.items.isEmpty, "先読みを始めない")
    }
}
