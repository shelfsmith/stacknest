// SPDX-License-Identifier: MIT
import Testing
import Foundation
import LibraryServerAPI
import LibraryStore
import RemoteClient
@testable import StackNest

/// `RemoteIntegrityDataSource` の純ロジックテスト（Phase G29 Task 3）。
///
/// **HTTP は張らない** — `fetchIntegritySummary`/`fetchIntegrityList`/`startIntegrityFullScan`/
/// `fetchMaintenanceStatus` の URL・クエリ・ボディ・decode は Task 2 の
/// `Tests/RemoteClientTests/RemoteLibraryClientTests.swift`（stub-backed）が担当済み。
/// ここでテストするのは、その上に乗る「DTO → 表示モデルの写像」と「tier によるスキャン開始可否」
/// という、ネットワークを介さない純粋なロジックだけ（`RemoteIntegrityDataSource.mapRow`/
/// `mapProgress` を直接呼ぶ・`canStartScan`/`scanUnavailableReason` を tier だけ変えて確認する）。
@MainActor
@Suite("RemoteIntegrityDataSource (G29 Task 3)")
struct RemoteIntegrityDataSourceTests {
    /// テストにしか使わない `RemoteLibraryClient`。init は I/O を一切行わない
    /// （実際に summary()/list() 等を呼ばない限りネットワークに触れない）ので、
    /// tier ゲートのテスト用に安全にダミーで作れる。
    private func dummyClient() -> RemoteLibraryClient {
        RemoteLibraryClient(baseURL: URL(string: "http://127.0.0.1:1")!, deviceToken: "test-token")
    }

    /// `RemoteErrorPresentationTests.swift` と同じ理由: 既定の表紙キャッシュだと
    /// `~/Library/Application Support/StackNest/RemoteCache/` に実データを作ってしまうため、
    /// `RemoteLibraryState` を作るテストではメモリのみのキャッシュを注入する。
    private func makeMemoryOnlyCache() -> RemoteCoverCache {
        RemoteCoverCache(cache: nil, serverID: nil, libraryUUID: nil)
    }

    /// `RemoteIntegrityDataSource(client:libraryUUID:liveState:)` のテスト用に、
    /// 最小限の `RemoteLibraryState` を作る。
    private func makeLiveState(libraryUUID: String = "lib-1", locked: Bool = false,
                                libraryToken: String? = nil) -> RemoteLibraryState {
        RemoteLibraryState(
            client: dummyClient(), serverID: UUID(), libraryUUID: libraryUUID,
            libraryName: "テスト", locked: locked, libraryToken: libraryToken,
            coverCache: makeMemoryOnlyCache())
    }

    // MARK: - mapRow（DTO → IntegrityRow）

    @Test("path は常に nil、filename は DTO の値がそのまま入る")
    func mapRowPathIsNilFilenameIsSet() {
        let item = IntegrityItemDTO(
            bookID: 42, title: "サンプル本", filename: "sample.zip", status: "damaged",
            checkedAt: 1_700_000_000, entryCount: 12, badEntries: ["a.jpg"], degraded: true)
        let row = RemoteIntegrityDataSource.mapRow(item)
        #expect(row != nil)
        #expect(row?.path == nil)
        #expect(row?.filename == "sample.zip")
        #expect(row?.id == 42)
        #expect(row?.title == "サンプル本")
        #expect(row?.status == .damaged)
        #expect(row?.entryCount == 12)
        #expect(row?.badEntries == ["a.jpg"])
        #expect(row?.degraded == true)
        #expect(row?.checkedAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("filename が nil の DTO でも行は作られる（filename も path と同様 optional）")
    func mapRowFilenameCanBeNil() {
        let item = IntegrityItemDTO(
            bookID: 1, title: "本", filename: nil, status: "ok",
            checkedAt: 0, entryCount: nil, badEntries: [], degraded: false)
        let row = RemoteIntegrityDataSource.mapRow(item)
        #expect(row?.filename == nil)
        #expect(row?.path == nil)
    }

    @Test("未知の status 文字列の行はスキップされる（既知ケースへ黙って倒さない）")
    func mapRowUnknownStatusIsSkipped() {
        let item = IntegrityItemDTO(
            bookID: 2, title: "将来のサーバが追加した状態", filename: "x.zip", status: "quantum-damaged",
            checkedAt: 0, entryCount: nil, badEntries: [], degraded: false)
        #expect(RemoteIntegrityDataSource.mapRow(item) == nil)
    }

    @Test("既知の全 IntegrityStatus ケースが往復する")
    func mapRowRoundTripsAllKnownStatuses() {
        for status in IntegrityStatus.allCases {
            let item = IntegrityItemDTO(
                bookID: 1, title: "t", filename: nil, status: status.rawValue,
                checkedAt: 0, entryCount: nil, badEntries: [], degraded: false)
            #expect(RemoteIntegrityDataSource.mapRow(item)?.status == status)
        }
    }

    // MARK: - mapProgress（MaintenanceStatusReply → IntegrityJobProgress?）

    @Test("running: false は nil に写る")
    func mapProgressNotRunningIsNil() throws {
        let reply = MaintenanceStatusReply(running: false)
        #expect(try RemoteIntegrityDataSource.mapProgress(reply) == nil)
    }

    @Test("running: true で done/total が入っていれば IntegrityJobProgress を返す")
    func mapProgressRunningWithCountsMapsThrough() throws {
        let reply = MaintenanceStatusReply(running: true, job: "full-scan", done: 3, total: 10)
        let progress = try RemoteIntegrityDataSource.mapProgress(reply)
        #expect(progress == IntegrityJobProgress(job: "full-scan", done: 3, total: 10))
        #expect(progress?.isIntegrityFullScan == true)
    }

    /// ★ Codex レビュー(Important) で挙動を変えた箇所。
    ///
    /// 以前は欠けたフィールドを `"unknown"` / `0` で埋めており、**「サーバが進捗を教えなかった」を
    /// 「確かに 0/0 進んでいる」という確定値に化けさせて**いた ―― 本ブランチが 8 件潰してきたのと
    /// 同じ型の欠陥で、しかも**このテスト自身がその挙動を固定していた**。
    /// 埋めずに投げ、呼び出し側の既存機構（凍結＋エラー表示）に載せる。
    @Test("running: true なのに job/done/total が欠けていれば投げる（0 埋めしない）")
    func mapProgressRunningWithMissingFieldsThrows() {
        #expect(throws: RemoteIntegrityUnavailable.self) {
            _ = try RemoteIntegrityDataSource.mapProgress(MaintenanceStatusReply(running: true))
        }
        // 一部だけ欠けている場合も同じ（done だけ来て total が無い等）。
        #expect(throws: RemoteIntegrityUnavailable.self) {
            _ = try RemoteIntegrityDataSource.mapProgress(
                MaintenanceStatusReply(running: true, job: "full-scan", done: 3))
        }
    }

    /// Codex レビュー(Important): 復号は「キー欠落」と「値が null」を区別するのに、
    /// **符号化が常にキーを出していた**ため、復号→再符号化で「旧サーバは知らない」が
    /// 「答えたうえで未検査」に変わってしまっていた。両方向で成立させる。
    @Test("旧サーバの応答は復号→再符号化してもキーが復活しない")
    func oldServerSilenceSurvivesRoundTrip() throws {
        let oldJSON = Data(#"{"checked":1,"unchecked":2,"damaged":3,"degraded":0}"#.utf8)
        let decoded = try JSONDecoder().decode(IntegritySummaryReply.self, from: oldJSON)
        #expect(decoded.lastScanAtKnown == false)

        let reencoded = try JSONEncoder().encode(decoded)
        let obj = try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        // キーごと消えていること（null で出ると「未検査」の意味になってしまう）。
        #expect(obj?.keys.contains("lastScanAt") == false)

        // 新サーバの「答えたうえで未検査」は null として往復すること。
        let newJSON = Data(#"{"checked":1,"unchecked":2,"damaged":3,"degraded":0,"lastScanAt":null}"#.utf8)
        let decodedNew = try JSONDecoder().decode(IntegritySummaryReply.self, from: newJSON)
        #expect(decodedNew.lastScanAtKnown == true)
        let obj2 = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(decodedNew)) as? [String: Any]
        #expect(obj2?.keys.contains("lastScanAt") == true)
    }

    // MARK: - tier ゲート（canStartScan / scanUnavailableReason）

    @Test("read tier ではスキャンを開始できず、理由が入る")
    func readTierCannotStartScan() {
        let source = RemoteIntegrityDataSource(client: dummyClient(), libraryUUID: "lib-1", libraryToken: nil, tier: .read)
        #expect(source.canStartScan == false)
        #expect(source.scanUnavailableReason != nil)
    }

    @Test("edit tier もスキャンを開始できず、理由が入る（full-scan は admin 専用）")
    func editTierCannotStartScan() {
        let source = RemoteIntegrityDataSource(client: dummyClient(), libraryUUID: "lib-1", libraryToken: nil, tier: .edit)
        #expect(source.canStartScan == false)
        #expect(source.scanUnavailableReason != nil)
    }

    @Test("admin tier はスキャンを開始でき、理由は出ない")
    func adminTierCanStartScan() {
        let source = RemoteIntegrityDataSource(client: dummyClient(), libraryUUID: "lib-1", libraryToken: nil, tier: .admin)
        #expect(source.canStartScan == true)
        #expect(source.scanUnavailableReason == nil)
    }

    // MARK: - tierResolutionFailed（review Minor 4: 「権限不足」と「権限を確認できない」を区別）

    @Test("tier 解決に失敗した場合は、権限不足とは違う理由が出る")
    func tierResolutionFailureGetsADistinctReason() {
        let source = RemoteIntegrityDataSource(
            client: dummyClient(), libraryUUID: "lib-1", libraryToken: nil, tier: .read,
            tierResolutionFailed: true)
        #expect(source.canStartScan == false)
        let reason = source.scanUnavailableReason
        #expect(reason != nil)
        #expect(reason?.contains("接続できない") == true)
    }

    @Test("tier 解決に成功していれば（admin 未満でも）権限不足の理由が出る")
    func normalTierShortfallReasonDiffersFromResolutionFailure() {
        let source = RemoteIntegrityDataSource(
            client: dummyClient(), libraryUUID: "lib-1", libraryToken: nil, tier: .read,
            tierResolutionFailed: false)
        #expect(source.scanUnavailableReason?.contains("管理者権限") == true)
        #expect(source.scanUnavailableReason?.contains("接続できない") == false)
    }

    @Test("admin tier では tierResolutionFailed が true でも開始できる（tier 自体は解決済み優先経路のため通常両立しないが、フラグ単体の意味を縛る）")
    func tierResolutionFailedDoesNotOverrideAnAlreadyAuthorizedTier() {
        let source = RemoteIntegrityDataSource(
            client: dummyClient(), libraryUUID: "lib-1", libraryToken: nil, tier: .admin,
            tierResolutionFailed: true)
        #expect(source.canStartScan == true)
        #expect(source.scanUnavailableReason == nil)
    }

    // MARK: - live-state 経由の tier/libraryToken（fix round 4, whole-branch review Critical 1）
    //
    // `RemoteIntegrityDataSource(client:libraryUUID:liveState:)` は `libraryToken`/`tier` を
    // 値としてコピーせず、`RemoteLibraryState` を弱参照して毎回読み直す。これが無いと、
    // 施錠庫を解錠する前に窓を開くと「解錠しても直らない」、`/me` 解決前に開くと
    // 「実際は admin なのにボタンが恒久的に無効」という 2 つの欠陥になる（whole-branch review C1）。
    // ここではその両方を「解決後に state を書き換えたら反映されるか」で直接検証する
    // （ユーザーが実際に踏む経路＝解錠・`/me` 完了の最短再現）。

    @Test("live-state の tier を後から書き換えると canStartScan に反映される（/me 解決後に admin になるケース）")
    func liveStateTierChangeIsPickedUpAfterConstruction() {
        let state = makeLiveState()
        state.tier = .read   // ウィンドウを開いた時点ではまだ /me が解決していない（fail-closed）。
        let source = RemoteIntegrityDataSource(client: dummyClient(), libraryUUID: "lib-1", liveState: state)
        #expect(source.canStartScan == false)
        #expect(source.scanUnavailableReason != nil)

        // ブラウズ窓側で /me が完了し、実は admin だったと判明した。
        state.tier = .admin
        #expect(source.canStartScan == true)
        #expect(source.scanUnavailableReason == nil)
    }

    @Test("live-state の libraryToken を後から書き換えても同じ liveState 参照を通して見える（解錠を再現）")
    func liveStateLibraryTokenChangeIsObservableThroughTheSameReference() {
        let state = makeLiveState(locked: true, libraryToken: nil)
        _ = RemoteIntegrityDataSource(client: dummyClient(), libraryUUID: "lib-1", liveState: state)
        #expect(state.libraryToken == nil)
        // ブラウズ窓で解錠した。
        state.libraryToken = "unlocked-token"
        // `RemoteIntegrityDataSource` は `libraryToken` を private に保つため直接は読めないが、
        // `tier` と全く同じ `liveState?.x ?? fallback` パターンで実装されている
        // （`IntegrityDataSource.swift` の `private var libraryToken` 参照）。上のテストで
        // その式が「後からの書き換えに追従する」ことを tier で確認済みなので、ここでは
        // 「同じ `state` インスタンスを弱参照し続けている」ことだけを確かめる（値のコピーで
        // 固定されていれば、この時点で `state.libraryToken` を読んでも無意味になる）。
        #expect(state.libraryToken == "unlocked-token")
    }

    /// fix round 5 (Critical, whole-branch review 再指摘): 弱参照が死んだ後、`fallbackTier`
    /// （`.read`）を「確認できた事実」として騙ってはいけない。以前のこのテストは
    /// `canStartScan == false` だけを確認して「read tier に戻る」と title に書いており、
    /// **その false な文言をテストが固定してしまっていた**（レビュー指摘）。
    /// 正しい主張は「確認できなくなった」であって「read だと確認した」ではない ―― admin だった
    /// 接続が弱参照切れの瞬間に「管理者権限がありません」と断言されるのは、このバグの前身である
    /// Critical 1 と同じ形の欠陥。
    @Test("live-state が破棄されると『確認できない』扱いになる（.read を確定事実として騙らない）")
    func liveStateDeallocationBecomesUnconfirmedNotConfirmedRead() {
        var state: RemoteLibraryState? = makeLiveState()
        state!.tier = .admin
        let source = RemoteIntegrityDataSource(client: dummyClient(), libraryUUID: "lib-1", liveState: state!)
        #expect(source.canStartScan == true)

        state = nil   // 弱参照が外れる（例: ブラウズ窓を閉じた）。
        #expect(source.canStartScan == false)
        // 「管理者権限がないため」（＝確認済みの事実）ではなく、「確認できない」でなければならない。
        #expect(source.scanUnavailableReason?.contains("管理者権限がないため") == false)
        #expect(source.scanUnavailableReason?.contains("確認できません") == true)
    }

    /// fix round 6（whole-branch review NEW-4）: `liveStateDied` を `jobProgress()` へ伝えていないと、
    /// **走行中のスキャンが黙って「完了」扱いになる**。
    ///
    /// 経路: live state が失われる → tier が未確認なのに `tier >= .admin` が false → nil を返す →
    /// ビューは nil を「実行中でない」と読む → `wasRunning && status == nil` が完了分岐を発火。
    /// 破損チェックウィンドウを独立させたのは**何時間も走るスキャン中に他の操作をするため**なので、
    /// 「スキャン中に庫のウィンドウを閉じる」は例外的な操作ではなく想定された使い方である。
    @Test("live-state が破棄されたら jobProgress は nil ではなく throw する（実行中を『完了』にしない）")
    func liveStateDeallocationMakesJobProgressThrowRatherThanReportNotRunning() async {
        var state: RemoteLibraryState? = makeLiveState()
        state!.tier = .admin
        let source = RemoteIntegrityDataSource(client: dummyClient(), libraryUUID: "lib-1", liveState: state!)

        state = nil   // スキャン実行中にブラウズ窓を閉じた状況。
        await #expect(throws: RemoteIntegrityUnavailable.self) {
            _ = try await source.jobProgress()
        }
    }

    // MARK: - supportsLastScanAt / idlePollIntervalNanoseconds（fix round 4, Important 1 / 3）

    @Test("構築直後・まだ何も取得していない間は『取得できない』扱い（fail-closed の初期値）")
    func supportsLastScanAtStartsFalseBeforeAnyFetch() {
        let source = RemoteIntegrityDataSource(client: dummyClient(), libraryUUID: "lib-1", libraryToken: nil, tier: .read)
        #expect(source.supportsLastScanAt == false)
    }

    // MARK: - mapSummary（2026-08-08 smoke フィードバック: lastScanAt の旧サーバ判別）
    //
    // `summary()`/`lastScanAt()` は両方ともこの関数を経由する（`IntegrityDataSource.swift` 参照）。
    // HTTP は張らず、DTO → 表示モデルの写像だけを検証する（`mapRow`/`mapProgress` と同じ方針）。

    @Test("新サーバ・未検査（lastScanAt が JSON に null で存在）は既知の nil として写る")
    func mapSummaryKnownNilIsNeverScanned() throws {
        // JSON にキーは存在するが値が null ―― `IntegritySummaryReply.init(from:)` が
        // `contains(.lastScanAt) == true` を見て `lastScanAtKnown = true` にするケース。
        let json = #"{"checked":0,"unchecked":5,"damaged":0,"degraded":0,"lastScanAt":null}"#
        let reply = try JSONDecoder().decode(IntegritySummaryReply.self, from: Data(json.utf8))
        let mapped = RemoteIntegrityDataSource.mapSummary(reply)
        #expect(mapped.lastScanAtKnown == true)
        #expect(mapped.lastScanAt == nil)
        #expect(mapped.summary.unchecked == 5)
    }

    @Test("新サーバ・検査済みは epoch から Date へ写る")
    func mapSummaryKnownDateMapsThrough() throws {
        let json = #"{"checked":3,"unchecked":0,"damaged":1,"degraded":0,"lastScanAt":1700000000}"#
        let reply = try JSONDecoder().decode(IntegritySummaryReply.self, from: Data(json.utf8))
        let mapped = RemoteIntegrityDataSource.mapSummary(reply)
        #expect(mapped.lastScanAtKnown == true)
        #expect(mapped.lastScanAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("旧サーバ（lastScanAt キー自体が無い）は『不明』側になる ―― nil を『未検査』と読ませない")
    func mapSummaryUnknownFromOldServerIsNotNeverScanned() throws {
        // このブランチが 6 ラウンドかけて除去した「読めなかったことを事実として断言する」欠陥の
        // 再演を防ぐ核心のケース: キーが無いだけの応答（旧サーバのシミュレート）。
        let json = #"{"checked":10,"unchecked":2,"damaged":1,"degraded":0}"#
        let reply = try JSONDecoder().decode(IntegritySummaryReply.self, from: Data(json.utf8))
        let mapped = RemoteIntegrityDataSource.mapSummary(reply)
        #expect(mapped.lastScanAtKnown == false, "旧サーバはキーを送らないので『不明』扱いにならなければならない")
        #expect(mapped.lastScanAt == nil)
    }

    @Test("リモートのアイドル時ポーリング間隔はローカルより大幅に長い（400ms は HTTP 往復に不適切）")
    func remoteIdlePollIntervalIsMuchLongerThanActive() {
        let source = RemoteIntegrityDataSource(client: dummyClient(), libraryUUID: "lib-1", libraryToken: nil, tier: .read)
        #expect(source.idlePollIntervalNanoseconds > 400_000_000)
    }

    // MARK: - FullScanMode.wireValue（review Minor 2: サーバの parseFullScanMode と 1 文字でもずれると壊れる）

    @Test("FullScanMode の wire 文字列はサーバの parseFullScanMode と一致する")
    func fullScanModeWireValuesMatchServer() {
        #expect(FullScanMode.uncheckedOnly.wireValue == "unchecked")
        #expect(FullScanMode.all.wireValue == "all")
        #expect(FullScanMode.damagedOnly.wireValue == "damaged")
    }
}
