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

    private func scanAll() {
        guard !scanning, settings.folderWatchEnabled else { return }
        scanning = true
        Task { @MainActor in
            defer { scanning = false }
            let existing = (try? Set(database.fetchAllBooks().map { $0.path ?? "" })) ?? []
            var currentSizes: [String: Int64] = [:]
            var candidatesByPath: [String: (URL, WatchedFolder)] = [:]
            for folder in settings.watchedFolders where folder.enabled {
                let dir = URL(fileURLWithPath: folder.path)
                let top = (try? FileManager.default.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                    options: [.skipsHiddenFiles])) ?? []
                let importable = WatchFolderScanner.importable(
                    topLevel: top,
                    existingLibraryPaths: existing,
                    baseline: Set(folder.baseline))
                for url in importable {
                    currentSizes[url.path] = Self.totalSize(of: url)
                    candidatesByPath[url.path] = (url, folder)
                }
            }
            let decision = WatchFolderScanner.decideStable(previous: lastSizes, current: currentSizes)
            lastSizes = decision.pending

            // pending（前回サイズ未確定＝直近で出現/書き込み中の候補）が残るなら、60 秒タイマを待たず
            // 短時間で再スキャンして安定確認する。これにより vnode 検知 → 数秒で取込（実質リアルタイム）。
            if !decision.pending.isEmpty { scheduleSettleScan() }

            var grouped: [String: [URL]] = [:]
            var formatByKey: [String: FilenameFormat] = [:]
            for path in decision.stable {
                guard let (url, folder) = candidatesByPath[path] else { continue }
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
                    autoClassifyEnabled: ViewerSettings.shared.autoClassifyEnabled,
                    thickThreshold: ViewerSettings.shared.thickBookThreshold)
                total.addedIDs += r.addedIDs
                total.coverFailures += r.coverFailures
                total.alreadyPresent += r.alreadyPresent
                total.failed += r.failed
            }
            if !total.addedIDs.isEmpty || !total.failed.isEmpty { onImported(total) }
        }
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

    private static func totalSize(of url: URL) -> Int64 {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if !isDir.boolValue {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        var sum: Int64 = 0
        if let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in en {
                sum += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        }
        return sum
    }
}
