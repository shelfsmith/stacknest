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

    // MARK: - 7b. UserDefaults による上書き

    private func makeDefaults(_ value: String?) -> UserDefaults {
        let name = "g34a-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        if let value { d.set(value, forKey: "stacknest.scanIOPolicy") }
        return d
    }

    @Test("未設定なら既定の THROTTLE")
    func configuredPolicyDefaultsToThrottle() {
        #expect(ThrottledIOExecutor.configuredPolicy(makeDefaults(nil)) == IOPOL_THROTTLE)
    }

    @Test("utility / standard へ切り替えられる（A/B 測定と体感調整のため）")
    func configuredPolicyHonoursKnownValues() {
        #expect(ThrottledIOExecutor.configuredPolicy(makeDefaults("utility")) == IOPOL_UTILITY)
        #expect(ThrottledIOExecutor.configuredPolicy(makeDefaults("standard")) == IOPOL_STANDARD)
        #expect(ThrottledIOExecutor.configuredPolicy(makeDefaults("UTILITY")) == IOPOL_UTILITY)
    }

    /// ★ 打ち間違いで**無効化**されては困る。未知の値は既定へ倒す
    /// （「効いているつもり」で走るのが最悪の結果なので、安全側は throttle）。
    @Test("未知の値は既定へ倒す（無効化しない）")
    func configuredPolicyFallsBackToTheSafeDefault() {
        #expect(ThrottledIOExecutor.configuredPolicy(makeDefaults("throttle_typo")) == IOPOL_THROTTLE)
        #expect(ThrottledIOExecutor.configuredPolicy(makeDefaults("")) == IOPOL_THROTTLE)
        #expect(ThrottledIOExecutor.configuredPolicy(makeDefaults("off")) == IOPOL_THROTTLE)
    }

    // MARK: - 7c. ★ 使い終わった実行器はスレッドごと片付く（Codex レビュー P2 の回帰ガード）

    /// 初版はスレッドのクロージャが `self?.threadLoop()` を呼んでおり、呼び出しの間ずっと
    /// executor を強参照していた。`threadLoop` は `isStopped` が立つまで返らず、`isStopped` は
    /// `deinit` でしか立たない ―― 所有が循環して `deinit` が永久に走らず、
    /// **走査のたびにネイティブスレッドが 1 本ずつ漏れていた**。
    ///
    /// `liveDependencies` は走査 1 回につき executor を 1 個作るので、
    /// 「参照が切れたらスレッドも終わる」は運用上の必須条件。
    @Test("実行器が解放されるとワーカースレッドも終了する")
    func releasingTheExecutorTerminatesItsThread() async throws {
        // worker だけを手元に残し、executor は解放させる。
        let worker: ThrottledIOExecutor.Worker
        do {
            let executor = ThrottledIOExecutor()
            worker = executor.worker
            _ = try await executor.run { 1 }        // スレッドを起動させる
            #expect(worker.hasExited == false)      // 使用中は当然まだ生きている
        }
        // ここで executor は解放され、deinit が worker.stop() を呼ぶ。

        for _ in 0..<200 {
            if worker.hasExited { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(worker.hasExited == true)
    }

    /// 停止時に積まれていた仕事は**捨てない**。捨てると `run` の continuation が
    /// resume されないまま消え、`withCheckedContinuation` がリークとして落ちる。
    @Test("停止しても積まれた仕事は捌かれる（continuation を宙に浮かせない）")
    func pendingWorkStillRunsAfterStop() async throws {
        let executor = ThrottledIOExecutor()
        let value = try await executor.run { 7 }
        #expect(value == 7)
        executor.worker.stop()
        // stop 後に積んだ分も resume される（ハングしないことがこのテストの主眼）
        let after = try await executor.run { 8 }
        #expect(after == 8)
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
