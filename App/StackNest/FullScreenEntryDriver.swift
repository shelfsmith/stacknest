// SPDX-License-Identifier: MIT
import AppKit
import os

/// G54-S3cd smoke fix: 巻送りでビューア種別が切り替わるとき（EPUB→画像ビューア／画像ビューア→EPUB）、
/// 旧窓を閉じた直後に新窓を全画面化しようとすると AppKit が `toggleFullScreen` を無視することがある
/// （旧窓の全画面 Space が退出アニメーション中のため）。
///
/// アプリ全体で「いまどの窓が全画面遷移の途中か」を窓ごとに持つ軽量トラッカー。
/// `willEnterFullScreen`/`willExitFullScreen` でその窓を集合へ挿入、対になる
/// `didEnterFullScreen`/`didExitFullScreen` で取り除く。各窓コントローラ自身の
/// `windowDidEnterFullScreen`（resume シート表示に使う）とは別の独立したオブザーバなので、
/// 既存の表示順序には影響しない。
///
/// G54-S3e smoke fix (自由記載): 以前は窓を区別しない単純なカウンタだった。`will*` に対応する `did*`
/// が来ない場面（窓が全画面のまま閉じられた／退出アニメーション中に AppKit が遷移を中断し再試行した）では
/// カウントが 0 に戻らず、以後ずっと `isOtherTransitionInProgress` が真になり続け、巻送りのたびに
/// 1.5 秒待ってから通常表示→全画面という劣化した見え方になっていた（`FullScreenEntryDriver.Config.
/// transitionWaitTimeout`）。窓ごとの `Set<ObjectIdentifier>` にすることで、同じ窓への重複した `will*` は
/// 冪等（集合への再挿入）になり、`NSWindow.willCloseNotification` でも取り除くことで「did* が永遠に来ない」
/// 経路を塞ぐ。
///
/// G54-S3e ハードニング（レビュー Minor）: 「窓ごとの集合」だけでは、なお AppKit の通知の到着順序
/// （`will*`→`did*` が必ず対になって来る／`willClose` が必ず来る）に依存していた。加えて
/// `ObjectIdentifier` はアドレスの同一性でしかないので、窓が解放された後に別のオブジェクトが同じ
/// アドレスへ再利用されると、無関係な新しい窓が「まだ遷移中」と誤認されうる。そこで集合の要素を
/// 弱参照の窓そのものに変え、`isTransitioning` 系のクエリのたびに「弱参照が生きていて、かつ
/// 登録から古すぎない」窓だけへ絞り込む（`prune()`）。これにより、通知が一切来ない経路や、窓が
/// 解放されて `willClose` を送れない経路でも、次にクエリされた時点で自己修復する。
///
/// G54-S3e ハードニング fix round 1（controller ruling）: 当初は「`isVisible == false` なら
/// 取り除く」という条件だった。だが全画面 Space のアニメーション中はウィンドウサーバー側の可視性が
/// 一時的に反転することがあり、これだと本当に遷移中の窓を誤って取り除いてしまい、S3c で直した
/// 窓間のレースを再発させかねない（controller の判断で `!isVisible` 条件は撤回）。代わりに
/// 「`will*` から `staleAge`（既定 3 秒——全画面アニメーションは 1 秒未満で終わる）を過ぎても
/// 対応する `did*`/`willClose` が来ない」ことを壊れた遷移の判定に使う。`staleAge` と時計は
/// `init` から注入できる（テストがスリープせずに済むように）。
@MainActor
final class FullScreenTransitionTracker {
    static let shared = FullScreenTransitionTracker()

    /// 全画面遷移が始まってから「`did*`/`willClose` が永遠に来ない壊れた遷移」とみなすまでの猶予。
    /// 全画面遷移のアニメーションは通常 1 秒未満で終わるので、これより十分長い値にしてある。
    static let defaultStaleAge: TimeInterval = 3.0

    /// G54-S3e beep fix: 全画面のまま窓が閉じられてから「Space 退出アニメーションが終わった」と
    /// みなすまでの猶予（`NSWorkspace.activeSpaceDidChangeNotification` が来ない場合の保険）。
    /// `beep-diag-m4.log` の実測では、旧窓の `didExit` から実際に Space 退出アニメーションが
    /// 終わるまで 0.6〜0.75 秒かかっていた。これより十分長い値にしてある。
    static let defaultSpaceExitTimeout: TimeInterval = 1.2

    /// G54-S3e beep 診断: `log show` で追えるよう `.notice`（`.debug` は永続化されない）。
    /// タグ "fs.tracker" で grep できる。件数・真偽値・通知種別だけ（窓のタイトル・パスは出さない）。
    private static let diagLogger = Logger(subsystem: "app.shelfsmith.stacknest", category: "Diag")

    /// 遷移中と見なしている窓への弱参照＋開始時刻。トラッカーは AppKit 通知に応じてだけ生きる
    /// 補助オブジェクトなので、窓を強参照して生存期間を延ばしてはいけない。
    private struct WeakWindow {
        weak var window: NSWindow?
        /// 直近の `will*`（同じ窓への 2 回目以降は上書きされる＝冪等な「リフレッシュ」）。
        var beganAt: TimeInterval
    }

    /// `note.object` を `NSWindow` そのものとして取り出すための薄い箱。中身は `@unchecked Sendable` だが
    /// 実際に別スレッドへ送るわけではない——`MainActor.assumeIsolated` の隔離クロージャへ渡すために
    /// コンパイラの静的な「sending」チェックを通すだけの入れ物（同期に同じメインスレッド上で開ける）。
    private struct UncheckedWindowBox: @unchecked Sendable {
        let window: NSWindow
    }

    private var transitioningWindows: [ObjectIdentifier: WeakWindow] = [:]
    private var pendingCompletions: [(excludedID: ObjectIdentifier?, handler: () -> Void)] = []
    private var observers: [NSObjectProtocol] = []
    /// `NSWorkspace.shared.notificationCenter` へ登録したオブザーバ。`NotificationCenter.default` とは
    /// 別のインスタンスなので、`removeObserver` も別に呼ぶ必要がある（`observers` とは分けて持つ）。
    private var workspaceObservers: [NSObjectProtocol] = []

    private let staleAge: TimeInterval
    private let spaceExitTimeout: TimeInterval
    private let now: () -> TimeInterval

    /// G54-S3e beep fix: 全画面のまま窓が閉じられた（`closeWindow(_:wasFullScreen: true)`）直後から
    /// 「Space 退出保留」とみなす時刻。`nil` なら保留無し。`NSWorkspace.activeSpaceDidChangeNotification`
    /// か `spaceExitTimeout` の経過のどちらか早い方で `nil` に戻る。
    ///
    /// 保留中は `isTransitioning`/`isTransitioning(excluding:)` を**どの窓についても**真にする
    /// （全画面のまま窓を閉じたことで動く Space 退出アニメーションは、閉じた窓自身だけでなく
    /// デスクトップ全体に影響するため、`excluding:` で除外しても無関係ではない）。これにより
    /// `FullScreenEntryDriver` の「他窓の遷移中は待つ」ロジックが Space 退出アニメーションの
    /// 完了も自然に待つようになり、退出アニメーション中の `toggleFullScreen` 失敗（AppKit の
    /// ビープ）を防ぐ（root cause は `beep-diag-m4.log` で確認済み: `beep-fix-brief.md` 参照）。
    private var spaceExitPendingAt: TimeInterval?

    /// クエリのたびに `prune()` してから答える——`will*`/`did*` の到着順序にも `ObjectIdentifier` の
    /// アドレス再利用にも頼らない（`prune()` のドキュメント参照）。
    var isTransitioning: Bool { isTransitioningIgnoring(nil) }

    /// `excluding` の窓自身は「他の窓」に数えない——自窓の遷移で自窓のドライバが待つのを防ぐ。
    func isTransitioning(excluding id: ObjectIdentifier) -> Bool { isTransitioningIgnoring(id) }

    /// - Parameters:
    ///   - staleAge: `prune()` が壊れた遷移とみなす経過時間。既定は `defaultStaleAge`。
    ///   - spaceExitTimeout: Space 退出保留を `prune()` が諦めるまでの経過時間。既定は
    ///     `defaultSpaceExitTimeout`。
    ///   - now: 現在時刻を返すクロージャ。既定は `ProcessInfo.processInfo.systemUptime`
    ///     （単調増加でスリープ等の影響を受けにくい）。テストは偽の時計を注入してスリープを避ける。
    init(staleAge: TimeInterval = FullScreenTransitionTracker.defaultStaleAge,
         spaceExitTimeout: TimeInterval = FullScreenTransitionTracker.defaultSpaceExitTimeout,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.staleAge = staleAge
        self.spaceExitTimeout = spaceExitTimeout
        self.now = now
        let nc = NotificationCenter.default
        // レビュー Minor: `queue: .main` により実行は必ずメインスレッドだが、NotificationCenter の
        // `using:` クロージャの型自体は `@Sendable`（非隔離）なので、コンパイラは MainActor 隔離の
        // `begin()`/`end()` をここから直接は呼ばせない。`MainActor.assumeIsolated` で
        // 「実際にはメインスレッドで呼ばれる」という事実を型に伝える。
        // レビュー Minor（G54-S3e smoke fix）: `Notification`/`NSWindow` は非 Sendable なので、
        // `MainActor.assumeIsolated` の隔離クロージャへそのまま渡すと「sending risks causing data
        // races」で弾かれる。`will*` は弱参照として保存するため窓そのものが要る——`UncheckedWindowBox`
        // に包んで渡す。`did*`/`willClose` は id だけで足りるので、そちらは従来どおり
        // `ObjectIdentifier`（Sendable な値型）だけを隔離前に取り出して渡す。
        observers = [
            nc.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: nil, queue: .main) { [weak self] note in
                guard let box = Self.windowBox(note) else { return }
                MainActor.assumeIsolated { self?.begin(box.window, source: "willEnter") }
            },
            nc.addObserver(forName: NSWindow.willExitFullScreenNotification, object: nil, queue: .main) { [weak self] note in
                guard let box = Self.windowBox(note) else { return }
                MainActor.assumeIsolated { self?.begin(box.window, source: "willExit") }
            },
            nc.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: nil, queue: .main) { [weak self] note in
                guard let id = Self.windowID(note) else { return }
                MainActor.assumeIsolated { self?.end(id, source: "didEnter") }
            },
            nc.addObserver(forName: NSWindow.didExitFullScreenNotification, object: nil, queue: .main) { [weak self] note in
                guard let id = Self.windowID(note) else { return }
                MainActor.assumeIsolated { self?.end(id, source: "didExit") }
            },
            // G54-S3e smoke fix: did* を待たずに窓が閉じられた場合の取りこぼし対策。
            // G54-S3e beep 診断: 「閉じた窓が全画面のままだったか」も窓自身（box.window）から読む
            // ——集合に入っているかどうかとは独立に、beep の手がかりとして残す。
            nc.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
                guard let box = Self.windowBox(note) else { return }
                // `styleMask` は MainActor 隔離のプロパティなので、`assumeIsolated` の中で読む。
                MainActor.assumeIsolated {
                    let id = ObjectIdentifier(box.window)
                    let wasFullScreen = box.window.styleMask.contains(.fullScreen)
                    self?.closeWindow(id, wasFullScreen: wasFullScreen)
                }
            },
        ]
        // G54-S3e beep fix: `NSWorkspace.shared.notificationCenter` は `NotificationCenter.default` とは
        // 別インスタンスなので observers とは別の配列で保持する（deinit で別々に removeObserver する）。
        workspaceObservers = [
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.spaceDidChange() }
            },
        ]
    }

    /// `note.object` を `NSWindow` として `ObjectIdentifier` に落とす。`nonisolated` のままでよい
    /// （オブジェクトの同一性を読むだけで、隔離されたプロパティには触れない）。
    private nonisolated static func windowID(_ note: Notification) -> ObjectIdentifier? {
        (note.object as? NSWindow).map(ObjectIdentifier.init)
    }

    /// `note.object` を `NSWindow` そのものとして取り出す（弱参照の保存用）。
    private nonisolated static func windowBox(_ note: Notification) -> UncheckedWindowBox? {
        (note.object as? NSWindow).map(UncheckedWindowBox.init)
    }

    @MainActor
    deinit {
        let nc = NotificationCenter.default
        for o in observers { nc.removeObserver(o) }
        let wnc = NSWorkspace.shared.notificationCenter
        for o in workspaceObservers { wnc.removeObserver(o) }
    }

    /// 現在進行中の遷移が 1 つも無くなった時点で一度だけ呼ばれる。
    /// 呼び出し時点で既に進行中の遷移が無ければ、次の tick で即座に呼ぶ
    /// （`schedule` 越しに呼ぶのは呼び出し側の責務。ここでは同期に呼んでよい）。
    /// G54-S3e ハードニング: `excluding` を渡すと、その窓自身の遷移は「まだ遷移中」に数えない
    /// （`isTransitioning(excluding:)` と対称——ドライバは自分自身の遷移完了を待って
    /// 自分自身を待つことがあってはならない）。
    func onNextTransitionEnd(excluding id: ObjectIdentifier? = nil, _ handler: @escaping () -> Void) {
        if !isTransitioningIgnoring(id) {
            handler()
            return
        }
        pendingCompletions.append((excludedID: id, handler: handler))
    }

    private func isTransitioningIgnoring(_ excludedID: ObjectIdentifier?) -> Bool {
        prune()
        return stillTransitioning(excluding: excludedID)
    }

    private func stillTransitioning(excluding excludedID: ObjectIdentifier?) -> Bool {
        // G54-S3e beep fix: Space 退出保留は特定の窓の遷移ではなく、デスクトップ全体（Space の
        // アニメーション）に効くので、`excludedID` の除外に関係なく真になる。
        if spaceExitPendingAt != nil { return true }
        guard let excludedID else { return !transitioningWindows.isEmpty }
        return transitioningWindows.keys.contains { $0 != excludedID }
    }

    /// - Parameter source: どの通知から呼ばれたか（"willEnter"/"willExit"、テスト経由なら既定の "test"）。
    ///   ログのタグにしか使わない。
    private func begin(_ window: NSWindow, source: String = "test") {
        // 同じ窓への 2 回目以降の will*（辞書キーの上書き）は beganAt も更新する＝リフレッシュされる。
        transitioningWindows[ObjectIdentifier(window)] = WeakWindow(window: window, beganAt: now())
        Self.diagLogger.notice("fs.tracker begin notification=\(source, privacy: .public) transitioning=\(self.transitioningWindows.count, privacy: .public)")
    }

    private func end(_ id: ObjectIdentifier, source: String = "test") {
        transitioningWindows.removeValue(forKey: id)
        Self.diagLogger.notice("fs.tracker end notification=\(source, privacy: .public) transitioning=\(self.transitioningWindows.count, privacy: .public)")
        fireReadyCompletions()
    }

    /// - Parameter wasFullScreen: 閉じる窓自身（呼び出し側が通知の object から直接読む）が、
    ///   閉じる時点で全画面 styleMask を持っていたか。beep 診断の手がかり（テスト経由の既定は false）。
    ///   G54-S3e beep fix: 真なら「Space 退出保留」に入る（`spaceExitPendingAt` セット）——
    ///   全画面のまま窓が閉じると、Space 退出アニメーションが `didExit`/`willClose` の後もしばらく
    ///   続き、その間に他窓が `toggleFullScreen` すると AppKit がビープ付きで失敗させる
    ///   （`beep-diag-m4.log` で確認済みの root cause）。
    private func closeWindow(_ id: ObjectIdentifier, wasFullScreen: Bool = false) {
        transitioningWindows.removeValue(forKey: id)
        if wasFullScreen {
            spaceExitPendingAt = now()
            Self.diagLogger.notice("fs.space exitPending set")
        }
        Self.diagLogger.notice("fs.tracker close wasFullScreen=\(wasFullScreen, privacy: .public) transitioning=\(self.transitioningWindows.count, privacy: .public)")
        fireReadyCompletions()
    }

    /// `NSWorkspace.activeSpaceDidChangeNotification` のハンドラ（`nonisolated` の受信クロージャから
    /// `MainActor.assumeIsolated` 越しに呼ばれる）。Space 退出保留を解除する（保留が無ければ何もしない）。
    private func spaceDidChange() {
        let wasPending = spaceExitPendingAt != nil
        Self.diagLogger.notice("fs.space didChange pending=\(wasPending, privacy: .public)")
        guard wasPending else { return }
        spaceExitPendingAt = nil
        Self.diagLogger.notice("fs.space exitPending cleared(reason: space)")
        fireReadyCompletions()
    }

    /// G54-S3e ハードニング（fix round 1 で `!isVisible` 条件を撤回・置換）: `will*`/`did*` の対応や
    /// `willCloseNotification` の到着に頼らず、集合をクエリするたび（`isTransitioning` 系・
    /// `onNextTransitionEnd`）に「本当にまだ生きていて遷移中と扱ってよい窓」だけへ絞り込む。
    /// 取り除く条件は次のどちらか:
    /// - 弱参照が `nil`（解放済み）——`ObjectIdentifier` は解放されたアドレスが再利用されうるので、
    ///   弱参照そのものを保持して生死を確かめる（アドレスの同一性だけでは判定しない）。
    /// - `beganAt` から `staleAge` を超えて経過している（壊れた遷移）——`isVisible` は使わない。
    ///   全画面 Space のアニメーション中はウィンドウサーバー側の可視性が一時的に反転しうるため、
    ///   `isVisible` で判定すると本当に遷移中の窓まで誤って取り除き、S3c で直した窓間のレースを
    ///   再発させかねない（controller ruling, fix round 1）。
    /// 取り除いた結果として集合が変化したら、保留中の完了ハンドラを再評価する
    /// （プルーニングだけで空になった＝`did*`/`willClose` どちらも来なかった経路の取りこぼし対策）。
    /// 取り除いた件数を理由別（released/stale）にログへ残す。件数のみで、窓のタイトル・パスは出さない。
    private func prune() {
        let before = transitioningWindows.count
        let hadSpaceExitPending = spaceExitPendingAt != nil
        let nowValue = now()
        var releasedCount = 0
        var staleCount = 0
        transitioningWindows = transitioningWindows.filter { _, entry in
            guard entry.window != nil else {
                releasedCount += 1
                return false
            }
            if nowValue - entry.beganAt > staleAge {
                staleCount += 1
                return false
            }
            return true
        }
        if releasedCount > 0 || staleCount > 0 {
            Self.diagLogger.notice("fs.tracker prune released=\(releasedCount, privacy: .public) stale=\(staleCount, privacy: .public)")
        }
        // G54-S3e beep fix: `NSWorkspace.activeSpaceDidChangeNotification` が来ない経路（保険）。
        // 壊れた遷移のプルーニングと同じ「クエリのたびに自己修復する」設計に合わせる。
        if let pendingAt = spaceExitPendingAt, nowValue - pendingAt > spaceExitTimeout {
            spaceExitPendingAt = nil
            Self.diagLogger.notice("fs.space exitPending cleared(reason: timeout)")
        }
        if transitioningWindows.count != before || (hadSpaceExitPending && spaceExitPendingAt == nil) {
            fireReadyCompletions()
        }
    }

    /// G54-S3e ハードニング fix round 1: ハンドラがトラッカーを再入的に操作しても
    /// （新たな `onNextTransitionEnd` を登録する・別窓の `end`/`closeWindow` を誘発する等）
    /// 二重発火・取りこぼしが起きないよう、「これから発火するもの(`ready`)」と
    /// 「まだ待つもの(`remaining`)」を**先に確定**させ、`pendingCompletions` を
    /// `remaining` へ**ハンドラを呼ぶ前に**書き換えてから `ready` を呼ぶ。こうすることで:
    /// - ハンドラが新規登録した保留分は（`remaining` の上に）素直に積み増され、上書きで消えない。
    /// - ハンドラが誘発した再入的な `fireReadyCompletions()` は、既に `remaining` に入れ替わった
    ///   `pendingCompletions` を見るので、`ready` に入っているものを二重に処理しない。
    private func fireReadyCompletions() {
        guard !pendingCompletions.isEmpty else { return }
        var ready: [(excludedID: ObjectIdentifier?, handler: () -> Void)] = []
        var remaining: [(excludedID: ObjectIdentifier?, handler: () -> Void)] = []
        for entry in pendingCompletions {
            if stillTransitioning(excluding: entry.excludedID) {
                remaining.append(entry)
            } else {
                ready.append(entry)
            }
        }
        pendingCompletions = remaining   // ハンドラを呼ぶ前に確定させる
        for entry in ready {
            entry.handler()
        }
    }

    /// テスト用: 実ウィンドウを渡して集合を直接動かす。弱参照プルーニングを検証するには
    /// 実際に `weak` で保持できる `NSWindow` が要る——`ObjectIdentifier` だけでは弱参照を作れないため、
    /// 以前の `testBeginTransition(id:)`（任意の `NSObject` の識別子で足りた）から変更している。
    func testBeginTransition(window: NSWindow) { begin(window) }
    func testEndTransition(id: ObjectIdentifier) { end(id) }
    func testCloseWindow(id: ObjectIdentifier, wasFullScreen: Bool = false) { closeWindow(id, wasFullScreen: wasFullScreen) }
    /// テスト用: 実際に `NSWorkspace` 通知を投げず（`queue: .main` の実配送は非同期でテストが
    /// スリープせずには待てない）、ハンドラを直接同期に呼ぶ。
    func testActiveSpaceDidChange() { spaceDidChange() }
}

/// G54-S3cd smoke fix: 「全画面化を要求 → 検証 → 必要なら待つ／リトライ」の決定ロジック。
/// AppKit 呼び出し（実際の `toggleFullScreen`・`styleMask` 読み取り・タイマー・通知監視）は
/// すべて呼び出し側が注入するクロージャに追い出してあるので、本体はテストで実ウィンドウ無しに検証できる。
///
/// 手順:
/// 1. 既に全画面なら何もしない。
/// 2. 最初の試行だけ、他の窓が全画面遷移の途中なら、その遷移が終わるまで待ってから要求する
///    （待っている間はリトライ回数を消費しない）。
/// 3. 要求のたびに `retryInterval` 後に検証し、全画面になっていなければ再試行する
///    （`maxAttempts` 回まで）。
@MainActor
final class FullScreenEntryDriver {
    /// G54-S3e beep 診断: `.notice`（`log show` で追える）・タグ "fs.driver"。
    private static let diagLogger = Logger(subsystem: "app.shelfsmith.stacknest", category: "Diag")
    /// 1 回の窓オープンにつき 1 個作られる `FullScreenEntryDriver` を、ログの上でグループ化するための
    /// 短い連番。値そのものに意味は無い（本の ID・窓のタイトルではない）。
    private static var nextDriverID = 0
    private let driverID: Int

    struct Config {
        var maxAttempts: Int = 3
        var retryInterval: TimeInterval = 0.3
        /// レビュー Important（Fix round 1）: 他窓の全画面遷移完了を待つ上限。
        /// `FullScreenTransitionTracker`（G54-S3e ハードニングで窓ごとの弱参照集合＋クエリ時の
        /// released/stale プルーニングへ強化済み）は通知の到着順序にもアドレス再利用にも頼らず
        /// 自己修復するが、その自己修復自体が `staleAge`（既定 3 秒）を上限に働くものなので、
        /// この `transitionWaitTimeout`（既定 1.5 秒）はそれとは独立に働く別の安全網——
        /// トラッカー側の判定を待たずに、ドライバ自身の判断で通知待ちを打ち切る役目を持つ。
        /// G54-S3e beep fix: `FullScreenTransitionTracker.defaultSpaceExitTimeout`（既定 1.2 秒）以上を
        /// 保つこと——Space 退出保留を待っている間にこちらが先に切り上げてしまうと、退出アニメーション
        /// 中に `toggleFullScreen` してビープの再発を招く。1.5 秒は 1.2 秒より十分長いのでそのままでよい。
        var transitionWaitTimeout: TimeInterval = 1.5
    }

    private let config: Config
    private let isFullScreen: () -> Bool
    private let isOtherTransitionInProgress: () -> Bool
    private let toggle: () -> Void
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let observeTransitionEnd: (@escaping () -> Void) -> Void

    private(set) var attemptsUsed = 0
    private var isRunning = false
    /// G54-S3e beep fix: `entryFailed()`（controller の `windowDidFailToEnterFullScreen` 経由）が
    /// 立てる。次の `proceed()` では、最初の試行と同じく「他窓の遷移完了（Space 退出保留を含む）」を
    /// 待ってから次を試す——盲目に `retryInterval` 間隔で連打すると、Space 退出アニメーション中は
    /// 何度でも失敗し、失敗のたびに AppKit がビープを鳴らす（root cause は `beep-diag-m4.log` で確認済み）。
    private var pendingEntryFailure = false

    init(config: Config = Config(),
         isFullScreen: @escaping () -> Bool,
         isOtherTransitionInProgress: @escaping () -> Bool,
         toggle: @escaping () -> Void,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void,
         observeTransitionEnd: @escaping (@escaping () -> Void) -> Void) {
        self.config = config
        self.isFullScreen = isFullScreen
        self.isOtherTransitionInProgress = isOtherTransitionInProgress
        self.toggle = toggle
        self.schedule = schedule
        self.observeTransitionEnd = observeTransitionEnd
        Self.nextDriverID += 1
        self.driverID = Self.nextDriverID
    }

    /// 便利イニシャライザ: 実際の `NSWindow` とアプリ共有のトラッカーを使う。
    /// G54-S3e smoke fix: `isOtherTransitionInProgress` は自分が駆動している窓自身を除外する
    /// （`ObjectIdentifier` は値なので窓を強参照しない——弱参照の `window` とは別に保持してよい）。
    convenience init(window: NSWindow, config: Config = Config(),
                      tracker: FullScreenTransitionTracker = .shared) {
        let windowID = ObjectIdentifier(window)
        self.init(
            config: config,
            isFullScreen: { [weak window] in window?.styleMask.contains(.fullScreen) ?? true },
            isOtherTransitionInProgress: { tracker.isTransitioning(excluding: windowID) },
            toggle: { [weak window] in window?.toggleFullScreen(nil) },
            // レビュー Minor: `block`（`() -> Void`）は非 Sendable なので、そのまま `asyncAfter(execute:)`
            // （`@Sendable` を要求）へは渡せない。実行は必ずメインスレッドなので `MainActor.assumeIsolated`
            // で実行時に隔離を assert する薄いラッパーに包んで渡す。
            schedule: { delay, block in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    MainActor.assumeIsolated { block() }
                }
            },
            // G54-S3e ハードニング: `onNextTransitionEnd` にも自窓の `windowID` を渡し、
            // `isOtherTransitionInProgress` と対称にする——自分自身の遷移完了を待って
            // 自分自身を待つことがないようにする（対称性が崩れていると、自窓に何らかの理由で
            // 古い遷移中エントリが残っていた場合、待ちが永遠に終わらなくなりうる）。
            observeTransitionEnd: { completion in tracker.onNextTransitionEnd(excluding: windowID, completion) }
        )
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        attemptsUsed = 0
        // G54-S3e beep 診断: 開始時点の判断材料（既に全画面か／他窓が遷移中か）を記録する。
        // 直後に proceed() が同じ 2 つを読み直すが、ログ専用の追加呼び出しは副作用が無い
        // （isOtherTransitionInProgress はトラッカーの自己修復クエリで冪等）。
        let alreadyFullScreen = isFullScreen()
        let otherInProgress = isOtherTransitionInProgress()
        Self.diagLogger.notice("fs.driver id=\(self.driverID, privacy: .public) start alreadyFullScreen=\(alreadyFullScreen, privacy: .public) otherTransitionInProgress=\(otherInProgress, privacy: .public)")
        proceed()
    }

    /// テスト用: 実行を止めて以後のクロージャ呼び出しを無視させる。
    func stop() {
        isRunning = false
    }

    /// G54-S3e beep fix: controller の `windowDidFailToEnterFullScreen`（AppKit が `toggleFullScreen`
    /// を拒否した経路。対応する通知が無いため、controller のデリゲートフックからここへ橋渡しする）から
    /// 呼ばれる。次の `proceed()` を「最初の試行」と同じ待ち合わせ扱いにする。
    func entryFailed() {
        guard isRunning else { return }
        pendingEntryFailure = true
        Self.diagLogger.notice("fs.driver id=\(self.driverID, privacy: .public) entryFailed")
    }

    private func proceed() {
        guard isRunning else { return }
        if isFullScreen() {
            isRunning = false
            return
        }
        if attemptsUsed >= config.maxAttempts {
            isRunning = false
            Self.diagLogger.notice("fs.driver id=\(self.driverID, privacy: .public) giveUp attempts=\(self.attemptsUsed, privacy: .public)")
            return
        }
        // G54-S3e beep fix: `pendingEntryFailure` が立っていれば、2 回目以降の試行でも
        // 「他窓の遷移完了（Space 退出保留を含む）」を待ってから次を試す（盲目の retryInterval 連打で
        // 同じ失敗を繰り返しビープしないため）。待つ必要が無ければ（already false から）
        // 通常どおり即座に attemptToggle する。
        if (attemptsUsed == 0 || pendingEntryFailure) && isOtherTransitionInProgress() {
            pendingEntryFailure = false
            waitForOtherTransitionThenToggle()
            return
        }
        pendingEntryFailure = false
        attemptToggle()
    }

    /// レビュー Important（Fix round 1）: 他窓の遷移完了通知と `transitionWaitTimeout` の期限の
    /// どちらか先に来た方で 1 回だけ前進する。`did*` 通知が永遠に来ない場合でも、期限を過ぎれば
    /// 通知を待たずに `attemptToggle()` へ進むので、待ちが無期限になることはない。
    /// 両方が来ても二重に進まないよう `hasProceeded` フラグで 1 回だけに絞る。
    private func waitForOtherTransitionThenToggle() {
        Self.diagLogger.notice("fs.driver id=\(self.driverID, privacy: .public) wait begin")
        var hasProceeded = false
        let proceedOnce: (String) -> Void = { [weak self] source in
            guard !hasProceeded else { return }
            hasProceeded = true
            if let self {
                Self.diagLogger.notice("fs.driver id=\(self.driverID, privacy: .public) wait end source=\(source, privacy: .public)")
            }
            self?.attemptToggle()
        }
        observeTransitionEnd { proceedOnce("transitionEnd") }
        schedule(config.transitionWaitTimeout) { proceedOnce("timeout") }
    }

    private func attemptToggle() {
        guard isRunning else { return }
        // Codex P2: 他窓の遷移を待つ間にユーザーが手で全画面にしていることがある。`toggleFullScreen` は
        // トグルなので、ここで改めて確かめずに呼ぶと達成済みの全画面を解除してしまう。
        if isFullScreen() {
            isRunning = false
            return
        }
        attemptsUsed += 1
        Self.diagLogger.notice("fs.driver id=\(self.driverID, privacy: .public) attemptToggle attempt=\(self.attemptsUsed, privacy: .public)")
        toggle()
        schedule(config.retryInterval) { [weak self] in self?.verify() }
    }

    private func verify() {
        guard isRunning else { return }
        let isFS = isFullScreen()
        Self.diagLogger.notice("fs.driver id=\(self.driverID, privacy: .public) verify isFullScreen=\(isFS, privacy: .public)")
        if isFS {
            isRunning = false
            return
        }
        proceed()
    }
}

/// G54-S3e beep 診断: `ViewerWindowController`/`EPUBReaderWindowController` が作る窓をこのサブクラスに
/// することで、「キー入力の行き先が無くて AppKit が既定のビープ（`NSBeep`）を鳴らす」経路をフックする。
/// `noResponder(for:)` はこの経路で AppKit が呼ぶ（`keyDown:` のときだけ既定実装がビープする）——
/// 挙動は変えず（`super` を必ず呼ぶ＝ビープはそのまま鳴る）、その直前の状態だけをログに残す。
/// パス・題名・入力文字は出さない（キーコード・真偽値・クラス名だけ、すべて `.public`）。
@MainActor
final class DiagnosticViewerWindow: NSWindow {
    /// `present()` が確定させる窓の種別（"image"/"epub"）。ログのタグにしか使わない。
    var diagnosticKind: String = "image"

    private static let diagLogger = Logger(subsystem: "app.shelfsmith.stacknest", category: "Diag")

    override func noResponder(for eventSelector: Selector) {
        // `NSApp.currentEvent` はベストエフォートの「今ディスパッチ中らしいイベント」であって、
        // 必ずしもキーイベントとは限らない（システムの KitDefined イベント等が入っていることがある）。
        // `.keyCode`/`.isARepeat` はキー系イベント（keyDown/keyUp/flagsChanged）以外に送ると
        // アサーション違反で落ちる（`-[NSEvent keyCode]` は型を検査する）ので、`event.type == .keyDown`
        // まで確認してから読む。
        if eventSelector == #selector(NSResponder.keyDown(with:)),
           let event = NSApp.currentEvent, event.type == .keyDown {
            let responderClass = firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            Self.diagLogger.notice("key.noResponder keyCode=\(event.keyCode, privacy: .public) isARepeat=\(event.isARepeat, privacy: .public) kind=\(self.diagnosticKind, privacy: .public) firstResponder=\(responderClass, privacy: .public) isKeyWindow=\(self.isKeyWindow, privacy: .public)")
        }
        super.noResponder(for: eventSelector)
    }
}
