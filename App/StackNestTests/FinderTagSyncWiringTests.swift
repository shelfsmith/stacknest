// SPDX-License-Identifier: MIT
import Testing
import Foundation
import AppCore
import LibraryStore
import StackroomFormat
@testable import StackNest

/// Phase G39 Task 7: App 層の配線（設定・ボリューム導出・結果の提示）。
///
/// **`swift test` は App ターゲットを一切見ない**ので、ここに置いたものだけが
/// `xcodebuild test` で守られる。同期本体（`FinderTagSync`）のテストは
/// `Tests/AppCoreTests/FinderTagSyncTests.swift` 側にある。
@Suite("G39 Task 7: Finder タグ同期の配線")
struct FinderTagSyncWiringTests {

    private func makeDatabase(bookCount: Int = 2) throws -> Database {
        let db = try Database.openInMemory()
        try db.migrate()
        for i in 1...max(bookCount, 1) {
            try db.insertBook(BookRecord(id: i, title: "Book \(i)",
                                         path: "/Volumes/comic/book\(i).zip",
                                         dateAdded: Date()))
        }
        return db
    }

    // MARK: - 設定キーの解釈

    /// UI に並べる 7 項目が、同期本体の whitelist と**同じ集合**であること。
    /// 片方だけ増減すると「選べるのに `unsupportedField` で失敗する」項目が生まれる。
    @Test("選択肢は FinderTagSync の whitelist と一致する")
    func theChoicesMatchTheSyncableFields() {
        #expect(Set(FinderTagSyncSetting.fields) == FinderTagSync.syncableFields)
        #expect(FinderTagSyncSetting.fields.count == 7)
    }

    @Test("未設定・空・whitelist 外はすべて『同期しない』に落ちる")
    func unknownValuesAreTreatedAsDisabled() {
        #expect(FinderTagSyncSetting.normalize(nil) == nil)
        #expect(FinderTagSyncSetting.normalize("") == nil)
        #expect(FinderTagSyncSetting.normalize("   ") == nil)
        #expect(FinderTagSyncSetting.normalize("rating") == nil, "whitelist 外（ファセットにはあるが同期対象外）")
        #expect(FinderTagSyncSetting.normalize("title") == nil)
        #expect(FinderTagSyncSetting.normalize("keyword_c") == "keyword_c")
        #expect(FinderTagSyncSetting.normalize(" genre ") == "genre", "前後の空白は落とす")
    }

    // MARK: - ★ 項目切替と前回同期値

    /// ★★ **これが本命。** 同期対象の項目を切り替えたら、前回同期値は全部消えていること。
    ///
    /// 残っていると 3 方向マージが**別項目の値を「前回のタグ」と誤認**し、
    /// 実在しない削除を検出して**ユーザーのタグを大量に消す**。非可逆の事故なので、
    /// `FinderTagSync.sync` 側の同等の保護とは独立にここでも縛る。
    ///
    /// 変異検証: `FinderTagSyncSetting.update` から `clearAllFinderTagBaselines()` を
    /// 取り除くとこのテストは落ちる（実測済み）。
    @Test("項目を切り替えると前回同期値が全部消える")
    func switchingTheFieldWipesEveryBaseline() throws {
        let db = try makeDatabase(bookCount: 3)
        try FinderTagSyncSetting.update(db, to: "genre")
        try db.setFinderTagBaselines([1: "赤, 青", 2: "緑"])
        try db.setFinderTagBaseline(bookID: 3, value: "")   // 「同期済みだが 0 件」も消えること
        #expect(try db.finderTagBaselines().count == 3, "前提: 前回同期値が 3 冊分ある")

        let changed = try FinderTagSyncSetting.update(db, to: "neta")

        #expect(changed)
        #expect(try db.finderTagBaselines().isEmpty,
                "項目を切り替えたのに前回同期値が残っている ―― 別項目の値を『前回のタグ』と誤認して大量削除する")
        #expect(FinderTagSyncSetting.current(db) == "neta")
    }

    /// 「同期しない」へ戻すのも切替。前回値は同じく無効になる。
    @Test("『同期しない』へ戻しても前回同期値は消える")
    func turningSyncOffAlsoWipesTheBaselines() throws {
        let db = try makeDatabase()
        try FinderTagSyncSetting.update(db, to: "author")
        try db.setFinderTagBaselines([1: "赤"])

        #expect(try FinderTagSyncSetting.update(db, to: nil))

        #expect(try db.finderTagBaselines().isEmpty)
        #expect(FinderTagSyncSetting.current(db) == nil)
    }

    /// ★ 逆側の縛り。**同じ項目を選び直しただけでは消してはいけない。**
    /// 設定シートを開いて閉じるたびに全消しされると、毎回が「初回同期」になり、
    /// Finder 側の削除が二度と伝わらなくなる（3 方向マージが前回値を持てないため）。
    @Test("同じ項目を選び直しただけでは前回同期値を消さない")
    func reselectingTheSameFieldKeepsTheBaselines() throws {
        let db = try makeDatabase()
        try FinderTagSyncSetting.update(db, to: "genre")
        try db.setFinderTagBaselines([1: "赤, 青"])

        let changed = try FinderTagSyncSetting.update(db, to: "genre")

        #expect(changed == false)
        #expect(try db.finderTagBaselines() == [1: "赤, 青"])
    }

    /// whitelist 外の値を渡しても「同期しない」と同じ扱いになり、設定が壊れないこと。
    @Test("whitelist 外を渡すと同期しない状態として保存される")
    func anUnsupportedFieldIsStoredAsDisabled() throws {
        let db = try makeDatabase()
        try FinderTagSyncSetting.update(db, to: "rating")
        #expect(FinderTagSyncSetting.current(db) == nil)
    }

    // MARK: - ボリュームの導出

    /// `mdutil -s` はマウントポイントしか受け付けない（サブディレクトリは
    /// `Error: unknown indexing state.`）ので、本のパスからボリュームの根まで遡る。
    @Test("本のパスからボリュームの根を求める")
    func derivesTheVolumeRootFromABookPath() {
        #expect(FinderTagVolumes.root(forPath: "/Volumes/comic/x/y.zip") == "/Volumes/comic")
        #expect(FinderTagVolumes.root(forPath: "/Volumes/comic") == "/Volumes/comic")
        #expect(FinderTagVolumes.root(forPath: "/Users/me/Books/a.cbz") == "/",
                "起動ボリュームの本は `/`（`mdfind -onlyin /` は /Users 配下も返す＝実測）")
        #expect(FinderTagVolumes.root(forPath: "/Volumes") == nil, "行き先が無い")
        #expect(FinderTagVolumes.root(forPath: "/") == nil)
        #expect(FinderTagVolumes.root(forPath: "") == nil)
        #expect(FinderTagVolumes.root(forPath: "relative/path.zip") == nil)
    }

    @Test("複数ボリュームに散った庫は重複なし・決定的な順序で返る")
    func collectsDistinctVolumesDeterministically() {
        let roots = FinderTagVolumes.roots(forPaths: [
            "/Volumes/ecomic/b.zip",
            "/Volumes/comic/a.zip",
            "/Volumes/comic/c.zip",
            "/Users/me/d.zip",
            "",
        ])
        #expect(roots.map(\.path) == ["/", "/Volumes/comic", "/Volumes/ecomic"])
    }

    @Test("本が 1 冊も無い庫ではボリュームが 0 個")
    func anEmptyLibraryYieldsNoVolume() {
        #expect(FinderTagVolumes.roots(forPaths: []).isEmpty)
    }

    // MARK: - 結果の提示

    private func outcome(lib: Int = 0, finder: Int = 0,
                         tags: [String] = [], books: [String] = [],
                         disabled: [String] = [], failure: String? = nil) -> FinderTagSyncOutcome {
        FinderTagSyncOutcome(updatedInLibrary: lib, updatedInFinder: finder,
                             skippedTags: tags, skippedBooks: books,
                             indexingDisabledVolumes: disabled, failure: failure)
    }

    /// 何も起きなかったときに、庫を開くたびバナーが出てはいけない。
    @Test("変化も警告も無ければ、庫を開いた契機では何も出さない")
    func staysQuietWhenNothingHappenedOnOpen() {
        #expect(FinderTagSyncNotice.make(outcome: outcome(), trigger: .libraryOpened,
                                         fieldLabel: "ジャンル") == nil)
    }

    /// 手動で押したのに無反応だと「効いていない」と読める。こちらは出す。
    @Test("手動再照合では『変更なし』を出す")
    func tellsTheUserWhenAManualRunChangedNothing() throws {
        let notice = try #require(FinderTagSyncNotice.make(outcome: outcome(), trigger: .manual,
                                                           fieldLabel: "ジャンル"))
        #expect(notice.kind == .info)
        #expect(notice.detail == nil)
    }

    /// ★ 索引が無効なら、変化が 0 件でも・庫を開いた契機でも必ず知らせる。
    /// **黙って同期されないのが最悪**（spec §3.3）。
    @Test("索引が無効なら、変化が無くても庫を開いた契機で警告する")
    func alwaysWarnsWhenIndexingIsDisabled() throws {
        let notice = try #require(FinderTagSyncNotice.make(
            outcome: outcome(disabled: ["comic"]), trigger: .libraryOpened, fieldLabel: "ジャンル"))
        #expect(notice.kind == .warning)
        #expect(notice.text.contains("comic"))
        #expect(notice.text.contains("Spotlight"))
    }

    /// スキップしたタグは件数をバナーに、名前は「詳細」に出す
    /// （名前が長い・多いときにバナーが画面を覆わないため）。
    @Test("スキップしたタグは件数を示し、名前は詳細に載せる")
    func reportsSkippedTagsWithTheirNamesInTheDetail() throws {
        let notice = try #require(FinderTagSyncNotice.make(
            outcome: outcome(tags: ["SF, ファンタジー"]), trigger: .libraryOpened, fieldLabel: "関連"))
        #expect(notice.kind == .warning)
        #expect(notice.text.contains("1 件"))
        #expect(notice.detail?.contains("SF, ファンタジー") == true)
    }

    @Test("諦めた本も件数を示し、パスは詳細に載せる")
    func reportsSkippedBooks() throws {
        let notice = try #require(FinderTagSyncNotice.make(
            outcome: outcome(books: ["/Volumes/comic/broken.zip"]),
            trigger: .libraryOpened, fieldLabel: "関連"))
        #expect(notice.kind == .warning)
        #expect(notice.detail?.contains("/Volumes/comic/broken.zip") == true)
    }

    @Test("同期に失敗したら理由ごと知らせる")
    func reportsAFailure() throws {
        let notice = try #require(FinderTagSyncNotice.make(
            outcome: outcome(failure: "ボリューム「/Volumes/comic」が見つかりません（未マウント？）。"),
            trigger: .libraryOpened, fieldLabel: "ジャンル"))
        #expect(notice.kind == .warning)
        #expect(notice.text.contains("/Volumes/comic"))
    }

    /// 変化があったときは両方向の件数を、選んだ項目の**表示名**で出す。
    @Test("変化があれば両方向の件数を項目名つきで出す")
    func summarisesBothDirections() throws {
        let notice = try #require(FinderTagSyncNotice.make(
            outcome: outcome(lib: 3, finder: 5), trigger: .libraryOpened, fieldLabel: "キーワード A"))
        #expect(notice.kind == .info)
        #expect(notice.text.contains("3"))
        #expect(notice.text.contains("5"))
        #expect(notice.text.contains("キーワード A"))
    }

    /// 変化と警告が同時に起きたら、警告として扱う（自動では消えない側に倒す）。
    @Test("変化と警告が同時なら警告扱いにする")
    func warningsWinOverPlainCounts() throws {
        let notice = try #require(FinderTagSyncNotice.make(
            outcome: outcome(finder: 2, disabled: ["comic"]), trigger: .libraryOpened,
            fieldLabel: "ジャンル"))
        #expect(notice.kind == .warning)
        #expect(notice.text.contains("2"))
        #expect(notice.text.contains("comic"))
    }

    // MARK: - 実行のガード

    /// 同期対象が未設定の庫では、`FinderTagSync` を呼ばずに終わること。
    /// （呼ぶと `unsupportedField` を投げるだけで、ユーザーには何も見えない。）
    @Test("同期対象が未設定なら何も走らない")
    @MainActor
    func doesNothingWhenNoFieldIsChosen() throws {
        let db = try makeDatabase()
        let state = AppState(bundleURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("g39-\(UUID().uuidString).stacknest"))
        state.database = db
        state.finderTagSyncField = nil

        state.startFinderTagSync(trigger: .libraryOpened)

        #expect(state.isFinderTagSyncRunning == false)
        #expect(state.finderTagSyncNotice == nil, "庫を開いた契機では黙っている")
        #expect(state.canStartFinderTagSync == false, "メニュー項目も無効")
    }

    /// 手動で押したときだけ「項目が選ばれていない」と知らせる。
    @Test("未設定のまま手動再照合を押したら、その旨を知らせる")
    @MainActor
    func explainsWhyAManualRunDidNothing() throws {
        let db = try makeDatabase()
        let state = AppState(bundleURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("g39-\(UUID().uuidString).stacknest"))
        state.database = db
        state.finderTagSyncField = nil

        state.startFinderTagSync(trigger: .manual)

        let notice = try #require(state.finderTagSyncNotice)
        #expect(notice.kind == .warning)
    }

    /// ★ 走行中は二重に走らせない（メニューを連打しても 1 本）。
    @Test("走行中の再入は無視される")
    @MainActor
    func doesNotStartTwice() throws {
        let db = try makeDatabase()
        let state = AppState(bundleURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("g39-\(UUID().uuidString).stacknest"))
        state.database = db
        state.finderTagSyncField = "genre"
        state.isFinderTagSyncRunning = true   // 走行中を模す

        #expect(state.canStartFinderTagSync == false)
        state.startFinderTagSync(trigger: .manual)
        #expect(state.finderTagSyncTask == nil, "再入で新しいタスクを起こしていない")
    }

    /// 設定の変更は `AppState` のキャッシュにも反映される（メニューの有効/無効がこれを見る）。
    @Test("項目を選ぶと AppState のキャッシュも追従する")
    @MainActor
    func settingTheFieldUpdatesTheCachedValue() throws {
        let db = try makeDatabase()
        let state = AppState(bundleURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("g39-\(UUID().uuidString).stacknest"))
        state.database = db

        state.setFinderTagSyncField("keyword_b")
        #expect(state.finderTagSyncField == "keyword_b")
        #expect(state.canStartFinderTagSync)

        state.setFinderTagSyncField(nil)
        #expect(state.finderTagSyncField == nil)
        #expect(state.canStartFinderTagSync == false)
    }
}

/// G39 追補: **CLI/MCP からの再照合**（`startFinderTagSync` が「始めたか・なぜ始めなかったか」を
/// 返し、始めたなら結果を渡すこと）。
///
/// なぜ返り値と完了通知が要るか —— ローカル制御の HTTP ハンドラは
/// 「変化が無かった」と「施錠されていたので断った」を区別して返す必要がある。
/// 件数だけを見て区別しようとすると**どちらも 0 件**なので必ず取り違える。
///
/// ★ **`.locked` はこのブランチで直したばかりの穴**（`canStartFinderTagSync` は施錠を見ておらず、
/// 庫を開いた後に外部から施錠されるとメニューが有効なまま走った）。修正時にテストが無かったので
/// ここで固定する。
@Suite("G39: 再照合の開始可否と結果の受け渡し")
struct FinderTagSyncStartOutcomeTests {

    /// 完了通知が呼ばれた回数を数える箱（`@Sendable` クロージャからローカル var は触れない）。
    @MainActor private final class CallCount {
        var value = 0
    }

    @MainActor
    private func makeState(db: Database?) -> AppState {
        let state = AppState(bundleURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("g39-\(UUID().uuidString).stacknest"))
        state.database = db
        return state
    }

    @Test("庫が開いていなければ .noLibrary")
    @MainActor
    func reportsNoLibrary() {
        let state = makeState(db: nil)
        state.finderTagSyncField = "genre"
        let calls = CallCount()
        #expect(state.startFinderTagSync(trigger: .manual) { _ in calls.value += 1 } == .noLibrary)
        #expect(calls.value == 0, "始まっていないのに完了通知が来たら、待っている側が二重に返る")
    }

    @Test("同期対象が未設定なら .noField")
    @MainActor
    func reportsNoField() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let state = makeState(db: db)
        state.finderTagSyncField = nil
        let calls = CallCount()
        #expect(state.startFinderTagSync(trigger: .manual) { _ in calls.value += 1 } == .noField)
        #expect(calls.value == 0)
    }

    @Test("走行中なら .alreadyRunning")
    @MainActor
    func reportsAlreadyRunning() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let state = makeState(db: db)
        state.finderTagSyncField = "genre"
        state.isFinderTagSyncRunning = true
        let calls = CallCount()
        #expect(state.startFinderTagSync(trigger: .manual) { _ in calls.value += 1 } == .alreadyRunning)
        #expect(calls.value == 0)
        #expect(state.finderTagSyncTask == nil, "再入で新しいタスクを起こしていない")
    }

    /// ★ 施錠中は**手動再照合でも**走らせない。
    /// 同期は庫のメタデータを Finder タグとして**ファイルに書き出す**ので、
    /// 解錠せずに中身が読めるのでは施錠の意味が無い。
    @Test("施錠中は .locked（メニューが有効でも走らせない）")
    @MainActor
    func reportsLocked() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let state = makeState(db: db)
        let settings = try LibrarySettings(database: db)
        _ = try settings.setLock(hash: "hash", salt: "salt", expectedHash: nil)
        state.librarySettings = settings
        state.finderTagSyncField = "genre"

        #expect(state.needsUnlock, "前提: この状態が『解錠待ち』であること")
        // メニューの有効/無効は施錠を見ていない ―― だからこそ実作業の側で止める必要がある。
        #expect(state.canStartFinderTagSync, "前提: メニューは有効に見えている")

        let calls = CallCount()
        #expect(state.startFinderTagSync(trigger: .manual) { _ in calls.value += 1 } == .locked)
        #expect(calls.value == 0)
        #expect(state.isFinderTagSyncRunning == false, "走行フラグを立てていない")
        #expect(state.finderTagSyncTask == nil)
    }

    /// 始まったら、終わったときに結果が渡ること。
    /// **本が 0 冊の庫**を使う ―― ボリュームが 1 つも導出されないので `mdfind` に触れず、
    /// 実マシンの Spotlight 状態に左右されずに完了まで走らせられる。
    @Test("始まったら完了時に結果が渡る")
    @MainActor
    func deliversTheOutcomeWhenItRuns() async throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let state = makeState(db: db)
        state.finderTagSyncField = "genre"

        let outcome: FinderTagSyncOutcome = await withCheckedContinuation { continuation in
            let start = state.startFinderTagSync(trigger: .manual) { continuation.resume(returning: $0) }
            #expect(start == .started)
        }
        #expect(outcome.updatedInLibrary == 0)
        #expect(outcome.updatedInFinder == 0)
        #expect(outcome.failure == nil)
    }
}

/// Codex レビュー 2 巡目（2026-08-25）: **項目を変える前に、走行中の同期を止める。**
///
/// `FinderTagSyncSetting.update` は前回同期値を全消しするが、飛行中のラウンドは
/// **古い項目のまま Finder のタグと図書の値を書き換えながら**進んでいる。止めずに変えると、
/// 古い項目の値が Finder に残り、次の照合で新しい項目へ流れ込む（非可逆の混入）。
///
/// `FinderTagSync` 側にも 64 冊ごとの関門があるが**あちらは最後の砦**で、
/// ここで止めるほうが速い（本 1 冊分で止まる）。
@Suite("項目を変えるときは走行中の同期を止める（G39・Codex 2 巡目）")
struct FinderTagSyncFieldChangeStopsRunTests {

    @MainActor
    private func makeState(_ db: Database) -> AppState {
        let state = AppState(bundleURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("g39-\(UUID().uuidString).stacknest"))
        state.database = db
        return state
    }

    @Test("走行中に項目を変えると、走行フラグとタスクが落ちる")
    @MainActor
    func changingTheFieldStopsARunningSync() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let state = makeState(db)
        state.finderTagSyncField = "genre"
        state.isFinderTagSyncRunning = true       // 走行中を模す

        state.setFinderTagSyncField("keyword_a")

        #expect(state.isFinderTagSyncRunning == false, "走行中のまま項目だけ変わってはいけない")
        #expect(state.finderTagSyncTask == nil)
        #expect(state.finderTagSyncChild == nil)
    }

    /// 止めた後にちゃんと新しい項目が入っていること（止めるだけで終わっていない）。
    @Test("止めたうえで新しい項目が反映される")
    @MainActor
    func theNewFieldIsStillApplied() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let state = makeState(db)
        state.finderTagSyncField = "genre"
        state.isFinderTagSyncRunning = true

        state.setFinderTagSyncField("keyword_a")

        #expect(state.finderTagSyncField == "keyword_a")
        #expect(FinderTagSyncSetting.current(db) == "keyword_a")
    }
}
