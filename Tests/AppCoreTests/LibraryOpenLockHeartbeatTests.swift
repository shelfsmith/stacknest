// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

/// G35a-2 Task A4: `LibraryOpenLock.heartbeat` の契約。
///
/// `LibraryOpenLockManager` は毎回この戻り値だけを見て
/// 「false ならロックを失った → `release`」を決めている。**ロック喪失の検出はこの経路にしかない。**
/// G35a-2 でこの呼び出しをメインスレッドの外へ移すため、**移す前に契約を固定しておく**。
///
/// 既存の `LibraryOpenLockTests` は `evaluate` の純ロジックだけを見ており、
/// **`heartbeat` の実ファイル I/O は未検証だった。**
@Suite("LibraryOpenLock.heartbeat の契約（G35a-2）")
struct LibraryOpenLockHeartbeatTests {

    private func makeBundle() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("g35-\(UUID().uuidString).stacknest")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func info(instance: String, now: Double = 1000) -> LibraryOpenLockInfo {
        LibraryOpenLockInfo(
            hostUUID: "HOST-A", hostName: "mac", pid: 4242, processStartTime: 900,
            appInstanceUUID: instance, acquiredAt: now, heartbeatAt: now)
    }

    // MARK: - 1. 自分が持っているロック

    @Test("自分が持っているロックなら true を返し、heartbeatAt が進む")
    func ownedLockIsRefreshed() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }
        #expect(LibraryOpenLock.forceAcquire(bundleURL: bundle, ourInfo: info(instance: "ME")))

        let alive = LibraryOpenLock.heartbeat(bundleURL: bundle, instanceUUID: "ME", now: 2000)

        #expect(alive == true)
        #expect(LibraryOpenLock.readLock(bundleURL: bundle)?.heartbeatAt == 2000)
    }

    // MARK: - 2. ★ 失っているとき（これが release を起こす条件）

    /// 他インスタンスに奪われた場合。**他人のハートビートを上書きしてはならない。**
    @Test("他インスタンスが持っていれば false を返し、相手の記録を書き換えない")
    func lockOwnedByAnotherInstance() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }
        #expect(LibraryOpenLock.forceAcquire(bundleURL: bundle, ourInfo: info(instance: "OTHER")))

        let alive = LibraryOpenLock.heartbeat(bundleURL: bundle, instanceUUID: "ME", now: 2000)

        #expect(alive == false)
        #expect(LibraryOpenLock.readLock(bundleURL: bundle)?.appInstanceUUID == "OTHER")
        #expect(LibraryOpenLock.readLock(bundleURL: bundle)?.heartbeatAt == 1000)   // 触っていない
    }

    /// ロックファイルごと消えた場合（外部から削除された・ボリュームが外れた等）。
    @Test("ロックファイルが無ければ false を返す")
    func missingLockFile() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }

        #expect(LibraryOpenLock.heartbeat(bundleURL: bundle, instanceUUID: "ME", now: 2000) == false)
    }

    /// ★ ロックを取り、その後ファイルを消された、という実際に起こりうる遷移。
    /// ここで false が返らないと、失ったロックを持っているつもりで走り続ける。
    @Test("取得後にロックファイルを消されたら false へ変わる")
    func losesOwnershipWhenFileDisappears() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }
        #expect(LibraryOpenLock.forceAcquire(bundleURL: bundle, ourInfo: info(instance: "ME")))
        #expect(LibraryOpenLock.heartbeat(bundleURL: bundle, instanceUUID: "ME", now: 1500) == true)

        try FileManager.default.removeItem(at: LibraryOpenLock.lockFileURL(bundleURL: bundle))

        #expect(LibraryOpenLock.heartbeat(bundleURL: bundle, instanceUUID: "ME", now: 2000) == false)
    }

    // MARK: - 3. 呼び出しスレッドに依存しない

    /// G35a-2 はこの呼び出しをメインスレッドの外へ移す。**どのスレッドから呼んでも同じ結果**
    /// であることを固定しておく（`FileManager` ベースなので本来スレッド非依存だが、
    /// 移設の前提なので明示的に押さえる）。
    @Test("メインスレッド以外から呼んでも同じ結果になる")
    func worksOffTheMainThread() async throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }
        #expect(LibraryOpenLock.forceAcquire(bundleURL: bundle, ourInfo: info(instance: "ME")))

        let alive = await Task.detached(priority: .utility) {
            LibraryOpenLock.heartbeat(bundleURL: bundle, instanceUUID: "ME", now: 2000)
        }.value

        #expect(alive == true)
        #expect(LibraryOpenLock.readLock(bundleURL: bundle)?.heartbeatAt == 2000)
    }
}
