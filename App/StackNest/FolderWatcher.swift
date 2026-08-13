// SPDX-License-Identifier: MIT
import Foundation
import AppCore
import LibraryStore
import OSLog

/// 1 ライブラリの監視フォルダを監視し、新規ファイルを BookImporter で取り込む。
/// DispatchSource(vnode) リアルタイム + 60 秒定期再スキャン(NAS 安全網) + サイズ安定化デバウンス。
@MainActor
final class FolderWatcher {
    private let database: Database
    private let bundleURL: URL
    private let settings: LibrarySettings
    private let onImported: (BookImporter.ImportResult) -> Void

    private var sources: [DispatchSourceFileSystemObject] = []
    private var timer: Timer?
    private var lastSizes: [String: Int64] = [:]
    /// review follow-up Finding 2: フォルダゲート（`BookImportError.folderHasNoImportablePages`）で
    /// 拒否された候補の「拒否時サイズ」を記憶する（プロセス内メモリのみ・DB/ディスクへは書かない）。
    /// サイズが変わらない限り再試行を飛ばし、「1 件失敗」バナーが 60 秒ごとに無限リピートするのを防ぐ。
    /// サイズが変われば（実画像追加等）自動的に再試行対象へ戻る（詳細は WatchFolderScanner.filterRetry）。
    private var rejectedSizes: [String: Int64] = [:]
    private var scanning = false
    private var settleScheduled = false   // pending 候補の短時間 settle 再スキャンが予約済みか
    private static let settleInterval: TimeInterval = 3   // vnode 検知後にサイズ安定を確認する間隔
    private static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "FolderWatcher")

    init(database: Database, bundleURL: URL, settings: LibrarySettings,
         onImported: @escaping (BookImporter.ImportResult) -> Void) {
        self.database = database
        self.bundleURL = bundleURL
        self.settings = settings
        self.onImported = onImported
    }

    // 注: ライフサイクルは AppState が管理し、closeBundle() で必ず stop()→nil する。
    // deinit での安全網は Timer(非 Sendable) を nonisolated deinit から触れず Swift 6 隔離に
    // 反するため設けない（将来 isolated deinit 採用時に再検討）。

    func start() {
        stop()
        guard settings.folderWatchEnabled else { return }
        for folder in settings.watchedFolders where folder.enabled {
            attachSource(forPath: folder.path)
        }
        let t = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scanAll() }
        }
        timer = t
        scanAll()   // 起動時キャッチアップ
    }

    func stop() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        timer?.invalidate()
        timer = nil
    }

    func reload() { start() }
    func scanNow() { scanAll() }

    private func attachSource(forPath path: String) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            Self.logger.warning("watch open failed: \(path, privacy: .public)")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in Task { @MainActor in self?.scanAll() } }
        src.setCancelHandler { close(fd) }
        src.resume()
        sources.append(src)
    }

    /// 監視フォルダを走査し、安定した候補を取り込む。
    ///
    /// ## G35a-1: 重い部分はメインスレッドの外で走る
    ///
    /// DB 読み・ディレクトリ列挙・サイズ集計・安定判定は **MainActor を必要としない**のに、
    /// このクラスが `@MainActor` であるためメインスレッド上で走っていた ―― 60 秒タイマー＋
    /// vnode イベントで、**開いている庫ごとに**。ライブラリは USB HDD 上の暗号化ディスクイメージに
    /// あり 1 操作 36〜80ms かかるので、まとまった時間 UI が固まっていた。
    ///
    /// 判定は `WatchScanPlanner` へ移し、ここは
    /// **①入力のスナップショット → ②オフスレッドで判定 → ③MainActor で取り込みと UI 更新**
    /// の 3 段になっている。
    private func scanAll() {
        guard !scanning, settings.folderWatchEnabled else { return }
        scanning = true
        Task { @MainActor in
            defer { scanning = false }

            // ① 入力を MainActor 上でスナップショットする。
            // **1 回の走査は最初に見た設定で最後まで通す** ―― 途中で読み直すと、
            // 一部のフォルダだけ新しい設定で走査された中途半端な結果になる。
            let folders = settings.watchedFolders.filter(\.enabled)
            let snapshotLastSizes = lastSizes
            let snapshotRejectedSizes = rejectedSizes
            let db = database

            // ② 重い部分をメインスレッドの外で。
            let plan = await Self.makePlan(folders: folders, lastSizes: snapshotLastSizes,
                                           rejectedSizes: snapshotRejectedSizes, database: db)

            // ③ ここから再び MainActor。状態の書き戻しと取り込み。
            lastSizes = plan.pending

            // pending（前回サイズ未確定＝直近で出現/書き込み中の候補）が残るなら、60 秒タイマを待たず
            // 短時間で再スキャンして安定確認する。これにより vnode 検知 → 数秒で取込（実質リアルタイム）。
            if plan.hasPending { scheduleSettleScan() }

            let attemptable = plan.attemptable
            let candidatesByPath = plan.candidatesByPath
            let currentSizes = plan.currentSizes

            var grouped: [String: [URL]] = [:]
            var formatByKey: [String: FilenameFormat] = [:]
            for path in attemptable {
                guard let candidate = candidatesByPath[path] else { continue }
                let (url, folder) = (candidate.url, candidate.folder)
                let key = folder.presetID ?? ""
                grouped[key, default: []].append(url)
                if formatByKey[key] == nil {
                    let raw = settings.resolvedFilenameFormatRaw(forPresetID: folder.presetID)
                    formatByKey[key] = (try? FilenameFormat(raw: raw)) ?? (try! FilenameFormat(raw: "@title"))
                }
            }
            guard !grouped.isEmpty else { return }

            var total = BookImporter.ImportResult()
            for (key, urls) in grouped {
                let importer = BookImporter(database: database, bundleURL: bundleURL, format: formatByKey[key]!)
                let r = await importer.add(
                    urls: urls,
                    autoClassifyEnabled: ImportDefaults.effectiveAutoClassify(db: database),
                    thickThreshold: ImportDefaults.effectiveThickThreshold(db: database))
                total.addedIDs += r.addedIDs
                total.coverFailures += r.coverFailures
                total.alreadyPresent += r.alreadyPresent
                total.failed += r.failed
            }

            // review follow-up Finding 2: 今回フォルダゲートで落ちた候補のサイズを記憶し、次回以降
            // サイズ不変なら再試行を飛ばす。落ちなかった（成功/別理由で失敗）候補は記憶を持ち越さない
            // （サイズが変わって再挑戦し成功した場合に古い拒否記憶を残さないためのクリーンアップ）。
            let gateRejectedPaths = Set(total.failed.compactMap { url, error -> String? in
                guard let importErr = error as? BookImportError, importErr == .folderHasNoImportablePages else { return nil }
                return url.path
            })
            for path in attemptable {
                guard let size = currentSizes[path] else { continue }
                if gateRejectedPaths.contains(path) {
                    rejectedSizes[path] = size
                } else {
                    rejectedSizes.removeValue(forKey: path)
                }
            }
            // 監視フォルダから消えた（削除/リネームされた）パスの記録は捨てる。
            // 放置してもプロセス生存中の数十バイトだが、残しておく意味が無い（レビュー Minor）。
            rejectedSizes = rejectedSizes.filter { currentSizes[$0.key] != nil }

            if !total.addedIDs.isEmpty || !total.failed.isEmpty { onImported(total) }
        }
    }

    /// 走査の判定を**メインスレッドの外で**行う（G35a-1）。
    ///
    /// ★ `Task.detached(priority: .utility)` を使う理由。**非構造 `Task {}` は呼び出し元の
    /// 優先度を継承する**ので、`@MainActor` から起こすと user-interactive 相当になる ――
    /// G34a で走査が `PRI=46`（Finder / Safari のメインスレッド相当）で走っていた原因が
    /// まさにこれだった。定期的な保守処理をその優先度で走らせない。
    ///
    /// `Database` は `@unchecked Sendable`、`WatchedFolder` と各サイズ表は値型なので、
    /// そのままオフスレッドへ渡せる。**`lastSizes` / `rejectedSizes` はスナップショットを渡し、
    /// 書き戻しは呼び出し側が MainActor 上で行う**（オフスレッドから状態を触らない）。
    private static func makePlan(folders: [WatchedFolder],
                                 lastSizes: [String: Int64],
                                 rejectedSizes: [String: Int64],
                                 database: Database) async -> WatchScanPlanner.Plan {
        await Task.detached(priority: .utility) {
            WatchScanPlanner.plan(folders: folders, lastSizes: lastSizes,
                                  rejectedSizes: rejectedSizes,
                                  io: .live(database: database))
        }.value
    }

    /// pending 候補があるとき、60 秒タイマを待たず settleInterval 秒後に再スキャンして安定確認する。
    /// 多重予約は settleScheduled でガード。停止後（self 解放）は weak self で no-op。
    private func scheduleSettleScan() {
        guard !settleScheduled else { return }
        settleScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.settleInterval))
            guard let self else { return }
            self.settleScheduled = false
            self.scanAll()
        }
    }

}
