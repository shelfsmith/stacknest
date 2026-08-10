// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Darwin
@testable import AppCore

/// G34a Task A2: `ThrottledIOExecutor` が **実際に** I/O スロットリング下でブロックを実行することを確認する。
///
/// **「別スレッドで動く」ことではなく「スロットルが実際に掛かっている」ことを直接測る。**
/// `getiopolicy_np` で読み戻せるので、意図が実現されたかを推測せずに検証できる。
///
/// ★ このテストは実際に欠陥を捕まえた実績がある: 初版は `DispatchQueue` で実装していたが、
/// libdispatch のワーカースレッド上では `setiopolicy_np` が `EINVAL` で失敗するため
/// ポリシーが既定（0）のままだった。「設定したから効いているはず」で通していれば、
/// 走査は throttle されないまま「対処済み」として出荷されていた。
struct ThrottledIOExecutorTests {

    // MARK: - 1. ★ ブロック実行中に実際にスロットルが掛かっている

    @Test
    func bodyRunsUnderThrottledDiskPolicy() async throws {
        let executor = ThrottledIOExecutor()

        let policyInside = try await executor.run {
            ThrottledIOExecutor.currentThreadDiskPolicy()
        }

        #expect(policyInside == IOPOL_THROTTLE)
    }

    // MARK: - 2. 実行器自身が「効いたか」を観測値で持っている

    /// 効かなかった場合に「効いたつもり」で走らせないための性質。
    /// 未起動なら `nil`（＝分からない）を返し、それを「有効」と取り違えないこと。
    @Test
    func throttleActivationIsObservedNotAssumed() async throws {
        let executor = ThrottledIOExecutor()

        #expect(executor.isThrottleActive == nil)   // まだスレッドが起動していない

        _ = try await executor.run { 0 }

        #expect(executor.isThrottleActive == true)
    }

    // MARK: - 3. 呼び出し側のスレッドは汚染されない

    /// `setiopolicy_np` はスレッド単位なので、呼び出し側へ漏れると無関係な処理まで
    /// スロットルされてしまう。実行器は専用スレッドを持つので構造的に漏れない。
    @Test
    func callerThreadPolicyIsUnaffected() async throws {
        let before = ThrottledIOExecutor.currentThreadDiskPolicy()
        let executor = ThrottledIOExecutor()

        _ = try await executor.run { 42 }

        #expect(ThrottledIOExecutor.currentThreadDiskPolicy() == before)
    }

    // MARK: - 4. 戻り値が伝播する

    @Test
    func returnValuePropagates() async throws {
        let executor = ThrottledIOExecutor()
        let value = try await executor.run { "hello" }
        #expect(value == "hello")
    }

    // MARK: - 5. エラーが伝播する

    struct Boom: Error, Equatable { let code: Int }

    @Test
    func thrownErrorPropagates() async throws {
        let executor = ThrottledIOExecutor()

        await #expect(throws: Boom(code: 7)) {
            _ = try await executor.run { () -> Int in throw Boom(code: 7) }
        }
    }

    /// throw したあとも実行器は使える（スレッドループが壊れていない）。
    @Test
    func executorSurvivesAThrowingBody() async throws {
        let executor = ThrottledIOExecutor()

        await #expect(throws: Boom.self) {
            _ = try await executor.run { () -> Int in throw Boom(code: 1) }
        }
        let after = try await executor.run { 99 }

        #expect(after == 99)
    }

    // MARK: - 6. 連続実行しても壊れない・順序が保たれる

    @Test
    func repeatedRunsAllSucceedInOrder() async throws {
        let executor = ThrottledIOExecutor()
        var results: [Int] = []
        for i in 0..<10 {
            results.append(try await executor.run { i * 2 })
        }
        #expect(results == (0..<10).map { $0 * 2 })
    }

    // MARK: - 7. ポリシーは差し替えられる（走査が遅すぎた場合の緩和先）

    @Test
    func policyIsConfigurable() async throws {
        let executor = ThrottledIOExecutor(policy: IOPOL_UTILITY)

        let policyInside = try await executor.run {
            ThrottledIOExecutor.currentThreadDiskPolicy()
        }

        #expect(policyInside == IOPOL_UTILITY)
        #expect(executor.isThrottleActive == true)
    }

    // MARK: - 8. 実行はすべて同一スレッド上（＝専用スレッドである）

    /// 専用スレッドであることは「ポリシーを設定できる」ための前提条件そのもの
    /// （dispatch のワーカースレッドでは設定できない）。
    @Test
    func allWorkRunsOnTheSameDedicatedThread() async throws {
        let executor = ThrottledIOExecutor()

        let first = try await executor.run { Thread.current.name ?? "" }
        let second = try await executor.run { Thread.current.name ?? "" }

        // 名前が付いた専用スレッドであること（テスト実行スレッドがこの名前を持つことはない）。
        #expect(first == "app.shelfsmith.stacknest.throttled-io")
        #expect(first == second)
    }
}
