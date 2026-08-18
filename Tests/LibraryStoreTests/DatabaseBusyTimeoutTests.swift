// SPDX-License-Identifier: MIT
import Testing
import Foundation
import GRDB
@testable import LibraryStore

/// G37 ①: リモート設定 DB だけ `SQLITE_BUSY` を待てるようにする。
///
/// リモートウィンドウは**窓ごとに別の `Database` 接続**で同じ `settings.db` に書く。
/// G36 の共有デバウンサでデバウンス対象の 3 設定は直列化されたが、
/// **残り 27 個の `persist*` は同期書き込みのまま**なので競合は残る。
///
/// **G36 でこの欠陥の性質が変わった。** 以前は 1 ドラッグ＝数百回の書き込みで、1 回落ちても
/// 次のイベントが書き直した（暗黙のリトライで自己修復）。**今は 1 ドラッグ＝1 回なので、
/// 落ちるとドラッグ内容が丸ごと恒久喪失する。**
///
/// **本庫 DB には入れない。** `LibraryOpenLock` が 1 インスタンスに限定していて競合が
/// ほぼ無く、書き込みは MainActor からも行われるため、待たせるとメインを止めてしまう。
@Suite("Database の busyTimeout（G37 ①）")
struct DatabaseBusyTimeoutTests {

    private func tempDBURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("g37-\(UUID().uuidString).sqlite")
    }

    /// 書き込み中の接続がある間に別接続が書くと、既定では即エラーになる。
    ///
    /// **保持側（トランザクションを抱えて `release` を待つ側）は生の `Thread` で動かす
    /// （G37 コントローラのレビューで判明した構造的ストールの回避。Task 3 の `Feeder`
    /// と同じ理由・同じ形）。** このテストの `#expect(holding.wait(...))` は
    /// `DispatchSemaphore.wait` で Swift Concurrency の**協調スレッドプールのスレッドを
    /// 同期ブロック**する。保持側を旧版のように `Task.detached` にすると同じプールを
    /// 要求するため、`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`（プールが極小に制限される
    /// モード）では「待ち手がプールを埋め尽くし、保持側に回すスレッドが無くなって
    /// 永久に進まない」という**決定論的なストール**が起きる（輻輳による確率的な遅延では
    /// ないので、待ち時間をいくら伸ばしても解消しない）。生の `Thread` は協調プールの
    /// 外側で実行されるため、待ち手が何本ブロックしていても保持側の進行に影響しない。
    @Test("busyTimeout を渡さなければ競合時に即失敗する（＝既定の挙動は不変）")
    func withoutTimeoutItFailsFast() throws {
        let url = tempDBURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let a = try Database.openFile(at: url, mode: .createOrFail)
        try a.migrate()
        defer { a.close() }
        let b = try Database.openExisting(at: url)
        defer { b.close() }

        let holding = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let failed = LockedBool()

        let holder = Thread {
            try? a.queue?.write { db in
                try db.execute(sql: "INSERT INTO library_settings (key, value) VALUES ('a','1') "
                                  + "ON CONFLICT(key) DO UPDATE SET value = excluded.value")
                holding.signal()          // 書き込みトランザクションを保持した
                release.wait()            // テストが指示するまで抱えたまま
            }
            finished.signal()
        }
        holder.start()
        #expect(holding.wait(timeout: .now() + 2) == .success, "A が書き込みを保持できること")

        do { try b.setLibrarySetting(key: "b", value: "1") }
        catch { failed.set(true) }

        release.signal()
        _ = finished.wait(timeout: .now() + 2)
        #expect(failed.get(), "既定（immediateError）では競合が即エラーになる")
    }

    /// `busyTimeout` を渡した接続は、相手が解放するまで待って成功する。
    ///
    /// 保持側を生の `Thread` にする理由は `withoutTimeoutItFailsFast` と同じ
    /// （協調スレッドプールの奪い合いを避ける）。
    @Test("busyTimeout を渡すと競合しても待って書き込める")
    func withTimeoutItWaitsAndSucceeds() throws {
        let url = tempDBURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let a = try Database.openFile(at: url, mode: .createOrFail)
        try a.migrate()
        defer { a.close() }
        let b = try Database.openExisting(at: url, busyTimeout: 5)
        defer { b.close() }

        let holding = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let holder = Thread {
            try? a.queue?.write { db in
                try db.execute(sql: "INSERT INTO library_settings (key, value) VALUES ('a','1') "
                                  + "ON CONFLICT(key) DO UPDATE SET value = excluded.value")
                holding.signal()
                Thread.sleep(forTimeInterval: 0.3)   // 0.3 秒だけ抱える
            }
            finished.signal()
        }
        holder.start()
        #expect(holding.wait(timeout: .now() + 2) == .success)

        // 待てば通る。例外が飛んだらテスト失敗。
        try b.setLibrarySetting(key: "b", value: "1")
        _ = finished.wait(timeout: .now() + 2)

        #expect(try b.getLibrarySetting(key: "b") == "1")
    }

    /// ★ 本庫 DB の既定が変わっていないこと（`busyTimeout` を渡さない全経路）。
    @Test("busyTimeout を渡さない経路は従来どおり")
    func defaultPathsAreUnchanged() throws {
        let url = tempDBURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try Database.openFile(at: url, mode: .createOrFail)
        defer { db.close() }
        try db.migrate()
        try db.setLibrarySetting(key: "k", value: "v")
        #expect(try db.getLibrarySetting(key: "k") == "v")

        let mem = try Database.openInMemory()
        defer { mem.close() }
        try mem.migrate()
        try mem.setLibrarySetting(key: "k", value: "v")
        #expect(try mem.getLibrarySetting(key: "k") == "v")
    }
}

/// `@Sendable` クロージャからも触れる Bool の箱。
/// **Swift 6 の strict concurrency はローカルの `var` の変更をエラーにする。**
final class LockedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    func set(_ x: Bool) { lock.lock(); v = x; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return v }
}
