// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

/// G34a Task A3: 非同期の中断問い合わせを同期フラグへ写す仕組みの検証。
struct CancellationMirrorTests {

    // MARK: - 1. ★ 開始時点で既に中断されているケースを取りこぼさない

    /// 走査は 1 冊ごとに `mirroring` を通る。ここを取りこぼすと、中断してから実際に止まるまでに
    /// 残り全冊を読み切ってしまう（数万冊 × 数秒）。**ポーラの初回起床を待たずに**
    /// 判定できていなければならない。
    @Test
    func alreadyCancelledIsVisibleImmediately() async throws {
        // interval を長くしておく。ポーラ経由で反映されたのなら、この時間内には間に合わない。
        let seen = await CancellationMirror.mirroring(
            probe: { true },
            interval: .seconds(60)
        ) { isCancelled in
            isCancelled()
        }

        #expect(seen == true)
    }

    // MARK: - 2. 中断されていなければ false のまま

    @Test
    func notCancelledStaysFalse() async throws {
        let seen = await CancellationMirror.mirroring(
            probe: { false },
            interval: .seconds(60)
        ) { isCancelled in
            isCancelled()
        }

        #expect(seen == false)
    }

    // MARK: - 3. 実行中に中断されたらフラグへ伝わる

    @Test
    func cancellationDuringBodyPropagates() async throws {
        let flipped = CancellationMirror()   // probe の戻り値を後から変えるための入れ物

        let observed: Bool = await CancellationMirror.mirroring(
            probe: { flipped.isCancelled },
            interval: .milliseconds(20)
        ) { isCancelled in
            #expect(isCancelled() == false)   // 開始時点では未中断
            flipped.set(true)                 // ここで外部が中断した体にする
            // ポーラが写すのを待つ（20ms 間隔なので余裕を見て最大 3 秒ポーリング）
            for _ in 0..<300 {
                if isCancelled() { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return false
        }

        #expect(observed == true)
    }

    // MARK: - 4. body が throw してもポーラが止まる

    struct Boom: Error {}

    @Test
    func pollerStopsWhenBodyThrows() async throws {
        await #expect(throws: Boom.self) {
            _ = try await CancellationMirror.mirroring(
                probe: { false },
                interval: .milliseconds(10)
            ) { _ -> Int in
                throw Boom()
            }
        }
        // ポーラの停止自体は外から直接観測できないが、`defer` に載っていることは
        // ここで throw 経路を通しておくことで、少なくとも defer が実行される経路として担保される。
    }

    // MARK: - 5. ミラー単体の読み書き

    @Test
    func mirrorReadWrite() {
        let m = CancellationMirror()
        #expect(m.isCancelled == false)
        m.set(true)
        #expect(m.isCancelled == true)
        m.set(false)
        #expect(m.isCancelled == false)
    }

    @Test
    func mirrorHonorsInitialValue() {
        #expect(CancellationMirror(initialValue: true).isCancelled == true)
    }
}
