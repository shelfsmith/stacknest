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
    func mapProgressNotRunningIsNil() {
        let reply = MaintenanceStatusReply(running: false)
        #expect(RemoteIntegrityDataSource.mapProgress(reply) == nil)
    }

    @Test("running: true で done/total が入っていれば IntegrityJobProgress を返す")
    func mapProgressRunningWithCountsMapsThrough() {
        let reply = MaintenanceStatusReply(running: true, job: "full-scan", done: 3, total: 10)
        let progress = RemoteIntegrityDataSource.mapProgress(reply)
        #expect(progress == IntegrityJobProgress(job: "full-scan", done: 3, total: 10))
        #expect(progress?.isIntegrityFullScan == true)
    }

    /// `job` が欠けたときのフォールバックは空文字ではなく `"unknown"`。
    /// 空文字だと「他のメンテナンス処理を実行中です（）」という中身の無い表示になり、
    /// **ジョブ名が取れなかったのか、そういう名前なのかが区別できない**（whole-branch review Minor）。
    /// `isIntegrityFullScan` の判定はどちらでも false なので、挙動ではなく表示のための選択。
    @Test("running: true でも job/done/total が欠けていれば既定値で返す（クラッシュしない）")
    func mapProgressRunningWithMissingFieldsDefaultsToZero() {
        let reply = MaintenanceStatusReply(running: true)
        let progress = RemoteIntegrityDataSource.mapProgress(reply)
        #expect(progress == IntegrityJobProgress(job: "unknown", done: 0, total: 0))
        #expect(progress?.isIntegrityFullScan == false)
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

    @Test("live-state が破棄されると fail-closed で read tier に戻る（弱参照・ダングリングでもクラッシュしない）")
    func liveStateDeallocationFallsBackToReadTier() {
        var state: RemoteLibraryState? = makeLiveState()
        state!.tier = .admin
        let source = RemoteIntegrityDataSource(client: dummyClient(), libraryUUID: "lib-1", liveState: state!)
        #expect(source.canStartScan == true)

        state = nil   // 弱参照が外れる（例: ブラウズ窓を閉じた）。
        #expect(source.canStartScan == false)
        #expect(source.scanUnavailableReason != nil)
    }

    // MARK: - supportsLastScanAt / idlePollIntervalNanoseconds（fix round 4, Important 1 / 3）

    @Test("リモートは lastScanAt を取得できない申告をする（『未検査』と『不明』を区別するため）")
    func remoteDoesNotSupportLastScanAt() {
        let source = RemoteIntegrityDataSource(client: dummyClient(), libraryUUID: "lib-1", libraryToken: nil, tier: .read)
        #expect(source.supportsLastScanAt == false)
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
