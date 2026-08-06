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
        try await Task.sleep(for: .milliseconds(50))
    }

    /// 3) status エンドポイントが実行中の full-scan ジョブを報告する。
    @Test func statusEndpointReportsRunningFullScan() async throws {
        let fx = try TestLibraryFixture(name: "FSStatus", bookCount: 2)
        defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        let core = makeCore(fixture: fx, adminTier: true)

        try await core.buildApplication().test(.router) { client in
            let postStatus = try await postFullScan(client, uuid: lib.uuid, mode: "unchecked")
            #expect(postStatus == .accepted)

            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/maintenance/status",
                method: .get, headers: [.authorization: "Bearer W"]
            ) { resp in
                #expect(resp.status == .ok)
                let dto = try JSONDecoder().decode(MaintenanceStatusReply.self, from: Data(buffer: resp.body))
                #expect(dto.running == true)
                #expect(dto.job == "full-scan")
            }
        }
        // fixture は bookCount 2 のみで即完走しうるため、後始末に少し待つ（後続テストへの汚染防止）。
        try await Task.sleep(for: .milliseconds(200))
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
        try await Task.sleep(for: .milliseconds(100))
    }
}
