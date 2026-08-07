// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
import LibraryStore
import AppCore
@testable import LibraryServer

/// Codex 事前レビュー Blocker2 の回帰テスト（`LibraryServer` 側の半分）。
///
/// **背景**: `ServerController`（共有ネットワークサーバ）は `LibraryServerCore` 構築時に
/// `maintenanceRegistry:` を渡していなかったため、`LibraryServerCore` が自前で別インスタンスを
/// 作ってしまい、`LocalControlController`（CLI/MCP・GUI 整合性チェックウィンドウ）と busy 判定が
/// 割れていた ―― 同じライブラリに対して共有サーバ経由とローカル経由の 2 本のフルスキャンが
/// 並走でき、一方が確定させた `damaged` を他方の遅れた `ok` が上書きしうる実害があった。
///
/// この回帰は本質的には `LibraryServer` の性質（**同じ `MaintenanceJobRegistry` インスタンスを
/// 注入された 2 個の独立した `LibraryServerCore` は busy 判定を共有する**）であり、
/// `SharedMaintenanceRegistry`（App target のプロセス内シングルトン）そのものには依存しない。
/// そのため、ここでは registry をこのテスト内でローカルに 1 個作り、`ServerController`/
/// `LocalControlController` 相当の 2 個の独立した core へ**同じインスタンス**を注入して検証する。
///
/// 「App 側の両コントローラが実際に `SharedMaintenanceRegistry.shared` を注入しているか」の
/// 配線検証（App test target は `HummingbirdTesting` を持たないため、実サーバは起動せず
/// identity 比較のみで行う）は `App/StackNestTests/SharedMaintenanceRegistryTests.swift` が
/// 別途担う。
@Suite("MaintenanceJobRegistry shared across independent LibraryServerCore instances (Codex pre-merge Blocker2)", .serialized)
struct MaintenanceRegistrySharedAcrossCoresTests {

    private func makeCore(fixture: TestLibraryFixture, registry: MaintenanceJobRegistry) -> LibraryServerCore {
        LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W", adminTier: true),
            dataSource: StaticLibraryDataSource(libraries: [fixture.servedLibrary()]),
            maintenanceRegistry: registry)
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

    /// 本命: 1 個目の core（ServerController 相当）経由で起動したジョブが、
    /// 2 個目の独立した core（LocalControlController 相当）経由の起動を 409 で拒否する ――
    /// ただし両者に**同一の** `MaintenanceJobRegistry` インスタンスを注入したときに限る。
    /// 修正前（`ServerController` 側だけ独自 registry を持つ状況を模した場合）なら、
    /// 2 個目の core は「running:false」を見て起動できてしまい、この期待は満たされない。
    @Test func startingThroughOneCoreBlocksTheOtherCoreWithConflict() async throws {
        let fx = try TestLibraryFixture(name: "SharedRegCross", bookCount: 0)
        defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        let registry = MaintenanceJobRegistry(onProgress: { _, _, _, _ in }, onFinished: { _, _, _, _ in })
        let coreA = makeCore(fixture: fx, registry: registry)   // ServerController 相当
        let coreB = makeCore(fixture: fx, registry: registry)   // LocalControlController 相当

        // coreA/coreB は独立した LibraryServerCore インスタンスだが、同じ registry を
        // 注入されているため busy 判定を共有するはず。
        #expect(coreA.maintenanceRegistry === coreB.maintenanceRegistry,
                "両 core が同一の registry インスタンスを参照していない")

        // registry を直接占有して「実行中」を確定的に作る（実スキャンはタイミング制御できない
        // ため、既存の FullScanEndpointTests.secondStartWhileRunningReturnsConflict と同じ流儀）。
        let gate = AsyncGate()
        let started = await registry.start(library: lib.uuid, job: "full-scan") { progress, _ in
            progress(0, 1)
            await gate.wait()
            return 1
        }
        #expect(started == true)

        // coreA の HTTP 経由の POST は 409（自分自身の registry が busy）。
        try await coreA.buildApplication().test(.router) { client in
            let status = try await postFullScan(client, uuid: lib.uuid, mode: "unchecked")
            #expect(status == .conflict, "coreA 自身の視点でも busy のはず")
        }

        // coreB の HTTP 経由の POST も 409 でなければ、Blocker2 が再発している
        // （coreA が確定させる予定の結果を coreB が同時に上書きできてしまう状態）。
        try await coreB.buildApplication().test(.router) { client in
            let status = try await postFullScan(client, uuid: lib.uuid, mode: "unchecked")
            #expect(status == .conflict, "coreB が独自 registry を持っていると busy を見逃し 202 になる")
        }

        // 後片付け: 占有していたジョブを終わらせ、次のテストへ進む前に registry を idle に戻す。
        await gate.open()
        try await waitForMaintenanceJobToFinish(registry: registry, library: lib.uuid)
    }

    /// G27b Codex 2nd review Fix3 の回帰テスト。
    ///
    /// **背景**: `SharedMaintenanceRegistry.shared` の `onProgress`/`onFinished` はかつて no-op
    /// だった（「ローカル制御の `/events` は誰も購読していないから」という理屈）。しかし
    /// `ServerController`（**ネットワーク**共有サーバ。`/events` は他機の `RemoteLibraryState` が
    /// 実際に購読する）にも同じ no-op registry を注入するようになったことで、リモートクライアントは
    /// `complete-metadata`/`compress-covers`/`full-scan` の進捗・完了 SSE と、完了時に流れる
    /// `structureChanged`（`compress-covers` 後の表紙リフレッシュの引き金）を一切受け取れなく
    /// なっていた ―― 動いていた機能をこのブランチが壊した回帰。
    ///
    /// ここでは `SharedMaintenanceRegistry` と同じ構図（registry の固定コールバックが
    /// `MaintenanceEventFanout` へブロードキャストするだけ）をローカルに再現し、その registry と
    /// fanout の両方を注入された `LibraryServerCore` が、実際に自分の `eventHub` へ
    /// `maintenanceProgress`/`maintenanceFinished`/`structureChanged` を配信することを検証する。
    /// 修正前（`maintenanceEventFanout` という注入経路自体が存在しない状態）では、この購読が
    /// 一切イベントを受け取れず本テストは失敗する。
    @Test func injectedSharedRegistryDeliversProgressAndFinishedToCoresEventHub() async throws {
        let fx = try TestLibraryFixture(name: "SharedRegFanout", bookCount: 0)
        defer { fx.cleanup() }
        let lib = fx.servedLibrary()

        // SharedMaintenanceRegistry.shared と同じ構図: registry のコールバックは fanout への
        // ブロードキャストのみ。実際の配信は core が fanout に購読させるクロージャに委ねる。
        let fanout = MaintenanceEventFanout()
        let registry = MaintenanceJobRegistry(
            onProgress: { l, j, d, t in fanout.broadcastProgress(l, j, d, t) },
            onFinished: { l, j, o, c in fanout.broadcastFinished(l, j, o, c) }
        )
        let core = LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W", adminTier: true),
            dataSource: StaticLibraryDataSource(libraries: [lib]),
            maintenanceRegistry: registry,
            maintenanceEventFanout: fanout)

        let sub = await core.eventHub.subscribe(scope: .all)
        var it = sub.stream.makeAsyncIterator()

        // 1 発目の progress は「他に何も競合しない」状態で送るため、順序に依存せず検証できる。
        let gate = AsyncGate()
        let started = await registry.start(library: lib.uuid, job: "full-scan") { progress, _ in
            progress(1, 2)
            await gate.wait()
            progress(2, 2)
            return 2
        }
        #expect(started == true)
        #expect(await it.next() == .maintenanceProgress(library: lib.uuid, job: "full-scan", done: 1, total: 2))

        // 残り（2 発目の progress・finished・完了に伴う structureChanged）は、EventHub.publish
        // 自身のドキュメント（複数 publish の配信順は入れ替わりうる）どおり順序を仮定せず、
        // 3 件受け取って集合として検証する。
        await gate.open()
        try await waitForMaintenanceJobToFinish(registry: registry, library: lib.uuid)
        var remaining: [LiveEvent] = []
        for _ in 0..<3 { remaining.append(try #require(await it.next())) }

        #expect(remaining.contains(.maintenanceProgress(library: lib.uuid, job: "full-scan", done: 2, total: 2)),
                "2 発目の progress が core の eventHub に届いていない")
        #expect(remaining.contains(.maintenanceFinished(library: lib.uuid, job: "full-scan", outcome: "done", count: 2)),
                "完了通知が core の eventHub に届いていない")
        #expect(remaining.contains(.structureChanged(library: lib.uuid)),
                "完了に伴う structureChanged（表紙リフレッシュの引き金）が届いていない")

        await core.eventHub.unsubscribe(sub.id)
    }
}
