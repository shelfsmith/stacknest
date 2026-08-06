// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
import LibraryStore
import AppCore
@testable import LibraryServer

/// POST libraries/:lib/integrity/full-scan（G27b Task5）。
/// complete-metadata/compress-covers と同じ形（同じ maintenanceRegistry・同じ admin 権限・
/// 202/409 の使い分け）であることを確認する。実ジョブは 31 時間規模なので、テストでは
/// 小さな fixture（bookCount 0〜数冊）に対して実行し、完走を待たず 202/409 の応答と
/// registry の status のみを見る。
@Suite("POST/GET full-scan (G27b Task5)", .serialized)
struct FullScanEndpointTests {

    private func makeCore(fixture: TestLibraryFixture, adminTier: Bool) -> LibraryServerCore {
        LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W", adminTier: adminTier),
            dataSource: StaticLibraryDataSource(libraries: [fixture.servedLibrary()])
        )
    }

    private func postFullScan(
        _ client: some TestClientProtocol, uuid: String, mode: String
    ) async throws -> HTTPResponse.Status {
        let body = try JSONEncoder().encode(FullScanStartRequest(mode: mode))
        var status: HTTPResponse.Status = .internalServerError
        try await client.execute(
            uri: "/api/v1/libraries/\(uuid)/integrity/full-scan",
            method: .post,
            headers: [.authorization: "Bearer W", .contentType: "application/json"],
            body: .init(bytes: Array(body))
        ) { resp in status = resp.status }
        return status
    }

    /// 1) 起動は 202。
    @Test func startingReturnsAccepted() async throws {
        let fx = try TestLibraryFixture(name: "FSStart", bookCount: 2)
        defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        let core = makeCore(fixture: fx, adminTier: true)
        try await core.buildApplication().test(.router) { client in
            let status = try await postFullScan(client, uuid: lib.uuid, mode: "unchecked")
            #expect(status == .accepted)
        }
        // 実ジョブがバックグラウンドで fixture の DB に触れ続けているので、
        // 確実に完走してから defer の cleanup() へ進む（Task.sleep の当てずっぽうにしない）。
        try await waitForMaintenanceJobToFinish(registry: core.maintenanceRegistry, library: lib.uuid)
    }

    /// 2) 実行中に再度起動すると 409。
    @Test func secondStartWhileRunningReturnsConflict() async throws {
        let fx = try TestLibraryFixture(name: "FSConflict", bookCount: 2)
        defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        let core = makeCore(fixture: fx, adminTier: true)

        // registry を直接占有して「実行中」を作る（実スキャンはタイミング制御できないため、
        // MaintenanceJobStatusTests と同じやり方で registry の公開 API を直接使う）。
        let gate = AsyncGate()
        let started = await core.maintenanceRegistry.start(library: lib.uuid, job: "full-scan") { progress, _ in
            progress(0, 1)
            await gate.wait()
            return 1
        }
        #expect(started == true)

        try await core.buildApplication().test(.router) { client in
            let status = try await postFullScan(client, uuid: lib.uuid, mode: "unchecked")
            #expect(status == .conflict)
        }
        await gate.open()
        // gate.open() 後の完了は registry 内の非構造 Task 経由で非同期に進むため、
        // 完了を確定的に確認してから defer の cleanup() へ進む。
        try await waitForMaintenanceJobToFinish(registry: core.maintenanceRegistry, library: lib.uuid)
    }

    /// 3) status エンドポイントが実行中の full-scan ジョブを報告する。
    ///
    /// G27b 最終レビュー Fix 検証時の追記: fixture が bookCount 2 のみで即完走しうるため、
    /// もともと「POST 直後の 1 回きりの GET」はレース（フルテストスイート並列実行下の
    /// スケジューリング次第で、GET が届く前に registry.finish() が呼ばれ running:false に
    /// 戻ってしまう）を内包していた。ジョブ自体は `registry.start()` 内で Task 起動前に
    /// 同期的に running へ確定するため、GET を短時間だけリトライすれば本質を損なわずに
    /// このレースを吸収できる……はずだったが、フルスイート並列実行下（322 suites 同時）の
    /// 実測では bookCount 2 は候補 2 冊とも path なし＝即 `missing` 確定（実ファイル I/O を
    /// 経ない）ため、スケジューラの混雑次第で「POST 応答から最初の GET が飛ぶまでの間」に
    /// スキャン自体が丸ごと終わってしまうことがあり、40 回×5ms のリトライでは救えない
    /// （リトライは「まだ start していない」を待つには効くが、「もう終わった」は待っても
    /// 覆らない）。`Task.sleep` を継ぎ足す代わりに、候補数を増やして
    /// `database.upsertIntegrity` 等の実ディスク書き込みを冊ごとに発生させ、スキャン自体に
    /// 観測可能な実時間を持たせることでレースの窓を実質的に塞ぐ（当てずっぽうの sleep 延長
    /// ではなく、実作業量を増やすことによる決定性の底上げ）。
    @Test func statusEndpointReportsRunningFullScan() async throws {
        let fx = try TestLibraryFixture(name: "FSStatus", bookCount: 400)
        defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        let core = makeCore(fixture: fx, adminTier: true)

        try await core.buildApplication().test(.router) { client in
            let postStatus = try await postFullScan(client, uuid: lib.uuid, mode: "unchecked")
            #expect(postStatus == .accepted)

            var lastDTO: MaintenanceStatusReply?
            for attempt in 0..<40 {
                var dto: MaintenanceStatusReply?
                try await client.execute(
                    uri: "/api/v1/libraries/\(lib.uuid)/maintenance/status",
                    method: .get, headers: [.authorization: "Bearer W"]
                ) { resp in
                    #expect(resp.status == .ok)
                    dto = try JSONDecoder().decode(MaintenanceStatusReply.self, from: Data(buffer: resp.body))
                }
                lastDTO = dto
                if dto?.running == true { break }
                if attempt < 39 { try await Task.sleep(for: .milliseconds(5)) }
            }
            #expect(lastDTO?.running == true, "running な状態を一度も観測できなかった")
            #expect(lastDTO?.job == "full-scan")
        }
        // fixture は bookCount 2 のみで即完走しうる。cleanup() 前に完走を確定的に確認する
        // （後続テストへの汚染防止・Task.sleep の当てずっぽうにしない）。
        try await waitForMaintenanceJobToFinish(registry: core.maintenanceRegistry, library: lib.uuid)
    }

    /// 4) 読み取り専用トークン（edit tier）は起動できない（403）。
    @Test func readOnlyTokenCannotStart() async throws {
        let fx = try TestLibraryFixture(name: "FSReadOnly", bookCount: 2)
        defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        let core = makeCore(fixture: fx, adminTier: false)
        try await core.buildApplication().test(.router) { client in
            let status = try await postFullScan(client, uuid: lib.uuid, mode: "unchecked")
            #expect(status == .forbidden)
        }
        let running = await core.maintenanceRegistry.status(library: lib.uuid)
        #expect(running == nil)
    }

    /// 5) mode は実際に候補選定へ反映される。不明な mode は黙って既定へ落とさず 400 で拒否する。
    @Test func unknownModeIsRejectedNotDefaulted() async throws {
        let fx = try TestLibraryFixture(name: "FSBadMode", bookCount: 2)
        defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        let core = makeCore(fixture: fx, adminTier: true)
        try await core.buildApplication().test(.router) { client in
            let status = try await postFullScan(client, uuid: lib.uuid, mode: "bogus")
            #expect(status == .badRequest)
        }
        // 400 で拒否されたのでジョブは起動していない。
        let running = await core.maintenanceRegistry.status(library: lib.uuid)
        #expect(running == nil)
    }

    /// 5続: "damaged" モードは damagedOnly の候補（method 不問・前回 damaged のみ）を選ぶ。
    /// bookCount 0（damaged 実績なし）では候補が空になるため即完了する ―― これは
    /// FullIntegrityScanner.scan 自体の単体テスト（Tests/AppCoreTests）で担保済みの分岐であり、
    /// ここでは「mode 文字列が badRequest にならず受理され、ジョブとして起動できる」ことのみ確認する。
    @Test func damagedModeIsAcceptedAsAValidMode() async throws {
        let fx = try TestLibraryFixture(name: "FSDamagedMode", bookCount: 0)
        defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        let core = makeCore(fixture: fx, adminTier: true)
        try await core.buildApplication().test(.router) { client in
            let status = try await postFullScan(client, uuid: lib.uuid, mode: "damaged")
            #expect(status == .accepted)
        }
        // 候補が空でも即完了するとは限らないため、確定的に完走を待ってから cleanup() へ進む。
        try await waitForMaintenanceJobToFinish(registry: core.maintenanceRegistry, library: lib.uuid)
    }
}
