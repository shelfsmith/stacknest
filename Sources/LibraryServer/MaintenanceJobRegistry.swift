// SPDX-License-Identifier: MIT
import Foundation

/// per-library で同時 1 本のメンテナンスジョブを管理する actor。
///
/// - `start` は同一 library で既に実行中のジョブがあれば起動せず false（busy）を返す。
/// - `run` クロージャに渡す `isCancelled` は actor 隔離状態を読むため async。
///   コア（`fillMissingSeriesVolume`/`compressOversizedCovers`）の `isCancelled` 引数と
///   シグネチャを揃えている（`() async -> Bool`）。
/// - 進捗・完了は `onProgress`/`onFinished` コールバック経由でサーバ（Task 7）に通知し、SSE へ転送する。
/// - G27b: 直近の進捗（job 名・done/total・開始時刻）を `statuses` に保持し、`status(library:)` で
///   同期的に問い合わせられる。31 時間規模のフルスキャンを SSE を張り続けずに確認するため。
///   `emitProgress` は `statuses[l]?.job == j`（**その library で今 statuses が指しているジョブが
///   自分自身か**）を見てから書き込む — `progress(...)` は不構造 Task 経由で actor に届くため、
///   run 完了直後の最後の progress 呼び出しが finish() より後にこの actor 上で実行されることが
///   ある。ガードを `running.contains(l)`（**その library で何かが走っているか**）だけにすると、
///   ジョブ A 完了直後にジョブ B が同じ library で start された場合に取り漏らす: 「A の遅延
///   progress」が実行される時点では `running` は（B のせいで）true のままなので通過してしまい、
///   `statuses[l]` を A の古い done/total で**上書き**してしまう（レビューで指摘・実テストで再現）。
///
///   Codex 事前レビュー（G27b post-review）: 当初の実装はジョブ**名**（`statuses[l]?.job == j`）の
///   一致でガードしていたが、`full-scan` → cancel → `full-scan` のように**同じ名前のジョブを
///   連続起動する**運用（実運用の smoke で実際に行う手順そのもの）では、直前ジョブと今回ジョブの
///   名前が同じため取り違えを検出できない。`start` のたびに新規発行する一意なトークン
///   （`activeRun`）で識別し、ジョブ名が衝突しても正しく区別する。
public actor MaintenanceJobRegistry {
    /// `status(library:)` が返す進捗スナップショット。
    public struct JobStatus: Sendable, Equatable {
        public var job: String
        public var done: Int
        public var total: Int
        public var startedAt: Date
    }

    private var running: Set<String> = []
    private var cancelledLibs: Set<String> = []
    /// G27b: library ごとの最新進捗。`running` に居る間だけ値を持つ（完了/失敗/中断で必ず消す）。
    private var statuses: [String: JobStatus] = [:]
    /// Codex 事前レビュー: library ごとに「今 progress/finish を受理してよい実行」を一意に識別する
    /// トークン。`start` が呼ばれるたびに新規発行し、その実行のクロージャだけが捕捉する
    /// （ジョブ名は表示用の情報でしかなく、識別には使わない）。
    ///
    /// G27b Codex 事後レビュー（swift test ハング調査）: **`finish()` はこれをもう nil に戻さない。**
    /// `activeRun[l]` は「この library に対して最後に発行されたトークン（＝まだ次の `start` に
    /// 上書きされていない、supersede されていないトークン）」を表す値として、次の `start` が
    /// 新トークンで上書きするまで保持し続ける。理由: `progress(...)` は
    /// `Task { await self.emitProgress(...) }` という不構造 Task 経由で actor に届くため、
    /// `run` クロージャ最後の `progress(...)` 呼び出し（`return` 直前）に対応する
    /// `emitProgress` の actor 到達が、同じ実行の `finish()` の actor 到達より**後**になることが
    /// ある（両者は別々の不構造 Task で、finish 側の呼び出し元は既に actor 直行中なのに対し
    /// progress 側はまず自分の Task がスケジュールされるのを待ってから actor に来るため、
    /// 到達順の逆転が起こりうる）。もし `finish()` がここで `activeRun[l] = nil` にしていると、
    /// この「自分自身の最後の progress」が `emitProgress` の token ガードで
    /// **truly superseded（＝別の run に上書きされた）と誤認されて丸ごと握りつぶされる**
    /// ―― SSE の最終 progress イベントが永遠に来ないことになり、それを待つ側
    /// （実運用の購読者・テストの `AsyncStream` 消費側）を無期限に待たせてしまう
    /// （実機で `swift test` がハングした実例のうちの一つがこれ）。
    ///
    /// 「実行中かどうか」（=  `statuses` を書き換えてよいか）は別途 `running` で判定する
    /// （`emitProgress`/`finish` 参照）。`activeRun` は「誰の run か（identity）」、`running` は
    /// 「今も生きているか（liveness）」―― この 2 つを混同しないことが本修正の要点。
    private var activeRun: [String: UUID] = [:]
    private let onProgress: @Sendable (String, String, Int, Int) -> Void
    private let onFinished: @Sendable (String, String, String, Int) -> Void
    /// G27b: 開始時刻の取得元。テストから固定時刻を注入できるよう既定は `Date.init` を渡す。
    private let now: @Sendable () -> Date

    /// コールバックは construction 時に同期的に確定させる（Codex review Important #1）。
    /// 旧 setOnProgress/setOnFinished（async setter）は起動直後の Task 内で配線していたため、
    /// registry 構築〜配線 Task 実行までの間に完了したジョブの通知が失われるレースがあった。
    /// `statuses` の書き込みも同じ理由で `start` 内で Task 起動前に同期的に行う（下記参照）。
    public init(
        onProgress: @escaping @Sendable (String, String, Int, Int) -> Void,
        onFinished: @escaping @Sendable (String, String, String, Int) -> Void,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.onProgress = onProgress
        self.onFinished = onFinished
        self.now = now
    }

    private func isCancelledLib(_ library: String) -> Bool { cancelledLibs.contains(library) }
    private func emitProgress(_ l: String, _ j: String, _ token: UUID, _ d: Int, _ t: Int) {
        // 第一関門（identity）: truly superseded（別の run に `activeRun[l]` を上書きされた）
        // 進捗は丸ごと無視する ―― コールバック発火も statuses 書き込みもしない。
        // ジョブ**名**での一致判定（旧実装）は、同じ名前のジョブを連続起動する運用
        // （`full-scan` → cancel → `full-scan`）を区別できないため、`start` のたびに
        // 新規発行する一意なトークンで識別する（ファイル冒頭コメント参照）。
        guard activeRun[l] == token else { return }
        // ここまで来れば「superseded ではない」＝この library に対して最後に発行された
        // トークンからの進捗。まだ次の run に上書きされていない限り、その run が既に
        // finish() 済みであっても onProgress は発火してよい（SSE の最終 progress を
        // 取りこぼさないため。`activeRun` を finish() で nil に戻さない設計はこのため）。
        onProgress(l, j, d, t)
        // 第二関門（liveness）: `statuses`（`status(library:)` が返すスナップショット）を
        // 書き換えてよいのは、この run がまだ **running** の間だけ。finish() は
        // `statuses[l] = nil` にして「完了直後は idle」を保証しているため、finish() 後に
        // 遅れて届いた自分自身の最後の progress でそれを復活させてはならない
        // （さもないと `completedJobReturnsToIdle` が壊れる）。
        guard running.contains(l) else { return }
        let startedAt = statuses[l]?.startedAt ?? now()
        statuses[l] = JobStatus(job: j, done: d, total: t, startedAt: startedAt)
    }
    private func finish(_ l: String, _ j: String, _ token: UUID, _ count: Int, failed: Bool) {
        let outcome = failed ? "failed" : (cancelledLibs.contains(l) ? "cancelled" : "done")
        // 「library を解放する」（liveness の後始末）と「完了コールバックを発火する」
        // （identity ガード）は別々の関心事 ―― 混ぜて 1 個の guard の内側に入れると、
        // token が万一不一致でも解放だけは必ず起きてほしい場面で解放ごと止まってしまう
        // （`running` が二度と外れず、`waitForMaintenanceJobToFinish` 等の polling を
        // 無期限に待たせる）。`start()` が `running.contains` で同一 library の二重起動を
        // 防いでいるため、この finish 呼び出しの token は構造的に常に「現在 running な
        // その run 自身」と一致するはずだが、その前提が将来崩れても実害（busy のまま
        // 二度と解放されない）を出さないよう、解放は token 一致を問わず必ず行う。
        running.remove(l); cancelledLibs.remove(l); statuses[l] = nil
        // `activeRun[l]` はここでは変更しない（ファイル冒頭の `activeRun` コメント参照）―
        // 次の `start` が新トークンで上書きするまで「この run が最後に発行されたトークン」
        // であり続けさせ、この run 自身の遅延 progress が superseded 誤判定されないようにする。
        if activeRun[l] == token {
            onFinished(l, j, outcome, count)
        }
    }

    /// 起動できたら true。既に同 library で実行中なら false（busy）。
    /// run が throw した場合は outcome "failed" として通知する（Codex review Important #4）。
    /// `progress` は型上も `@escaping`（G27b テスト向け）: 実体は既に `Task { await self.emitProgress(...) }`
    /// を内包しており実質エスケープしている（呼び出し側で同期的に使い切る保証は無い）。この注釈は
    /// 実際の挙動を型に反映しただけで、production 呼び出し側（complete-metadata/compress-covers）の
    /// 挙動は変わらない。
    @discardableResult
    public func start(
        library: String, job: String,
        run: @escaping @Sendable (_ progress: @escaping @Sendable (Int, Int) -> Void, _ isCancelled: @Sendable () async -> Bool) async throws -> Int
    ) -> Bool {
        guard !running.contains(library) else { return false }
        running.insert(library); cancelledLibs.remove(library)
        // この実行だけを識別するトークン。同じ library に対して同じ job 名で連続起動しても
        // （`full-scan` → cancel → `full-scan` 等）、`token` は毎回新規発行されるため取り違えない
        // （詳細はファイル冒頭コメント・emitProgress のコメント参照）。
        let token = UUID()
        activeRun[library] = token
        // status(library:) が start() 直後から running:true を返せるよう、Task 起動前に
        // 同期的に確定させる（コールバックを init で固定した理由と同じレース回避。上記コメント参照）。
        statuses[library] = JobStatus(job: job, done: 0, total: 0, startedAt: now())
        Task { [weak self] in
            guard let self else { return }
            let progress: @Sendable (Int, Int) -> Void = { done, total in
                Task { await self.emitProgress(library, job, token, done, total) }
            }
            let isCancelled: @Sendable () async -> Bool = { await self.isCancelledLib(library) }
            do {
                let count = try await run(progress, isCancelled)
                await self.finish(library, job, token, count, failed: false)
            } catch {
                await self.finish(library, job, token, 0, failed: true)
            }
        }
        return true
    }

    public func cancel(library: String) { if running.contains(library) { cancelledLibs.insert(library) } }

    /// G27b: library の現在のジョブ状態を返す。実行中でなければ nil。
    public func status(library: String) -> JobStatus? { statuses[library] }
}
