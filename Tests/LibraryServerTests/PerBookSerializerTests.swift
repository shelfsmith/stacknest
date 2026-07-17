// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryServer

/// G16 Codex Medium: PerBookSerializer の直接ユニットテスト。PATCH ハンドラの HTTP レベル
/// テスト（PatchBookEndpointTests.concurrentPatchesToSameBookSerializePreImage）はスケジューリング
/// 依存で「実際に競合が起きるか」を保証しないため、こちらはロック自体の FIFO 直列化／
/// 別 key の非ブロッキングを決定的に検証する。
actor OrderRecorder {
    private(set) var order: [Int] = []
    func append(_ x: Int) { order.append(x) }
}

@Suite("PerBookSerializer")
struct PerBookSerializerTests {
    /// 同じ key への 2 件目の acquire は、1 件目が release するまで一時停止し、
    /// release 後に FIFO で解放される（lost update を防ぐ直列化そのものの検証）。
    @Test func serializesAcquireForSameKey() async throws {
        let lock = PerBookSerializer()
        let recorder = OrderRecorder()

        await lock.acquire(uuid: "lib", bookID: 1)   // 1 件目は即時取得
        let waiter = Task {
            await lock.acquire(uuid: "lib", bookID: 1)   // 2 件目は release まで一時停止するはず
            await recorder.append(2)
            await lock.release(uuid: "lib", bookID: 1)
        }
        // waiter が acquire で確実に一時停止してから 1 件目の記録・release を行う。
        try await Task.sleep(nanoseconds: 100_000_000)
        await recorder.append(1)
        await lock.release(uuid: "lib", bookID: 1)
        await waiter.value

        let order = await recorder.order
        #expect(order == [1, 2])   // 2 件目は 1 件目の release より前に進めていない
    }

    /// 別の key（別の本）への acquire は、他 key が使用中でも待たされない
    /// （別の本への PATCH が並行のままであることの検証）。
    @Test func differentKeysDoNotBlockEachOther() async throws {
        let lock = PerBookSerializer()
        await lock.acquire(uuid: "lib", bookID: 1)
        // key=2 の acquire が key=1 の release を待って一時停止するなら、このテストはハングする。
        await lock.acquire(uuid: "lib", bookID: 2)
        await lock.release(uuid: "lib", bookID: 1)
        await lock.release(uuid: "lib", bookID: 2)
    }

    /// release は「待機者がいなければ busy を解放するだけ」。次の acquire は再び即時取得できる
    /// （同じ key を release→acquire で再利用しても取り残しが無いことの検証）。
    @Test func keyIsFullyReleasedWhenNoWaiters() async throws {
        let lock = PerBookSerializer()
        await lock.acquire(uuid: "lib", bookID: 1)
        await lock.release(uuid: "lib", bookID: 1)
        // 待機者がいなかったので busy は解放されているはず。ハングすればここで検出できる。
        await lock.acquire(uuid: "lib", bookID: 1)
        await lock.release(uuid: "lib", bookID: 1)
    }
}
