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

    @Test("running: true でも job/done/total が欠けていれば 0 埋め・空文字で返す（クラッシュしない）")
    func mapProgressRunningWithMissingFieldsDefaultsToZero() {
        let reply = MaintenanceStatusReply(running: true)
        let progress = RemoteIntegrityDataSource.mapProgress(reply)
        #expect(progress == IntegrityJobProgress(job: "", done: 0, total: 0))
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

    // MARK: - FullScanMode.wireValue（review Minor 2: サーバの parseFullScanMode と 1 文字でもずれると壊れる）

    @Test("FullScanMode の wire 文字列はサーバの parseFullScanMode と一致する")
    func fullScanModeWireValuesMatchServer() {
        #expect(FullScanMode.uncheckedOnly.wireValue == "unchecked")
        #expect(FullScanMode.all.wireValue == "all")
        #expect(FullScanMode.damagedOnly.wireValue == "damaged")
    }
}
