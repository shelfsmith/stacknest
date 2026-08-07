// SPDX-License-Identifier: MIT
import Foundation

/// `MaintenanceJobRegistry` は construction 時に固定された 1 組の `onProgress`/`onFinished`
/// しか持てない。複数の `LibraryServerCore`（それぞれ独立した `eventHub` を持つ）が**同じ**
/// registry インスタンスを共有する構成（G27b Codex 2nd review 以降の `ServerController`／
/// `LocalControlController` = `SharedMaintenanceRegistry.shared`）では、registry 自身の
/// コールバックだけでは「どの core の eventHub へ配るか」を表現できない。
///
/// この型は registry の外側に立つ薄いファンアウトで、任意個の sink（core ごとの
/// 進捗/完了ハンドラ）を購読させ、`broadcastProgress`/`broadcastFinished` で購読中の
/// 全員に配る。`SharedMaintenanceRegistry.shared` の `onProgress`/`onFinished` はこの
/// fanout の broadcast をそのまま呼ぶだけにし、`LibraryServerCore.init` は注入された
/// registry と対になる fanout へ、自分の `eventHub` へ publish するクロージャを購読させる。
///
/// **所有権とライフタイム**: `subscribe` が返す `Subscription` が購読解除の唯一の手段であり、
/// 明示的な unsubscribe 呼び出しは不要 ―― 最後に保持しているコピーが解放されると
/// `Subscription.deinit` が自動的に `unsubscribe` する。`LibraryServerCore`（struct）は
/// これを `let` プロパティとして持つだけでよく、struct の最後のコピーが消える自然な
/// アプリのシャットダウン経路（`app`/ルートクロージャの解放）に乗って購読が外れる。
///
/// 購読クロージャは **`eventHub` だけを捕捉し、`LibraryServerCore` 自身（`self`）を
/// 捕捉してはならない**。self を捕捉すると、`fanout`（プロセス寿命で永続する static
/// シングルトン）がクロージャを保持し続ける限り struct 全体（Subscription を含む）が
/// 生き続けてしまい、`unsubscribe` の引き金（Subscription の deinit）が永久に引かれない
/// 循環になる ―― これは「core が消えても購読が残り続ける」という Fix3 が禁じているまさに
/// その leak を作ってしまう。
///
/// スレッド安全性は内部の `NSLock` で保証する（actor にしなかったのは、`subscribe` を
/// `LibraryServerCore.init`（同期コンテキスト）から呼び切りたいため ―― actor にすると
/// `init` から `await` が必要になり、job 開始とのレースを生む）。
public final class MaintenanceEventFanout: @unchecked Sendable {
    public typealias ProgressSink = @Sendable (String, String, Int, Int) -> Void
    public typealias FinishedSink = @Sendable (String, String, String, Int) -> Void

    /// 購読を表すハンドル。deinit で自動的に unsubscribe する。
    public final class Subscription: @unchecked Sendable {
        fileprivate let id = UUID()
        private weak var fanout: MaintenanceEventFanout?
        fileprivate init(fanout: MaintenanceEventFanout) { self.fanout = fanout }
        deinit { fanout?.unsubscribe(id) }
    }

    private let lock = NSLock()
    private var progressSinks: [UUID: ProgressSink] = [:]
    private var finishedSinks: [UUID: FinishedSink] = [:]

    public init() {}

    /// `onProgress`/`onFinished` を購読させ、解除用の `Subscription` を返す。
    /// 呼び出し側はこれを自分の生存期間だけ保持すればよい。
    public func subscribe(onProgress: @escaping ProgressSink, onFinished: @escaping FinishedSink) -> Subscription {
        let subscription = Subscription(fanout: self)
        lock.lock()
        progressSinks[subscription.id] = onProgress
        finishedSinks[subscription.id] = onFinished
        lock.unlock()
        return subscription
    }

    private func unsubscribe(_ id: UUID) {
        lock.lock()
        progressSinks.removeValue(forKey: id)
        finishedSinks.removeValue(forKey: id)
        lock.unlock()
    }

    /// 購読中の全 sink へ進捗を配る。
    public func broadcastProgress(_ library: String, _ job: String, _ done: Int, _ total: Int) {
        lock.lock()
        let sinks = Array(progressSinks.values)
        lock.unlock()
        for sink in sinks { sink(library, job, done, total) }
    }

    /// 購読中の全 sink へ完了を配る。
    public func broadcastFinished(_ library: String, _ job: String, _ outcome: String, _ count: Int) {
        lock.lock()
        let sinks = Array(finishedSinks.values)
        lock.unlock()
        for sink in sinks { sink(library, job, outcome, count) }
    }
}
