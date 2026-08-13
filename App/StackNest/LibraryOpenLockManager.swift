// App/StackNest/LibraryOpenLockManager.swift
// SPDX-License-Identifier: MIT
import Foundation
import AppCore
import Darwin
import OSLog

/// App-layer wrapper over `LibraryOpenLock`: supplies host identity / PID liveness,
/// runs a heartbeat timer, and tracks which bundles this process holds.
/// One shared instance for the whole app process.
@MainActor
final class LibraryOpenLockManager {
    static let shared = LibraryOpenLockManager()

    private static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "OpenLock")
    /// Allowed drift between a recorded and re-read process start time (clock granularity / tv_usec rounding).
    private static let pidStartTimeTolerance: TimeInterval = 2.0
    private let instanceUUID = UUID().uuidString
    private let hostUUID = LibraryOpenLockManager.currentHostUUID()
    private let hostName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    private let pid = ProcessInfo.processInfo.processIdentifier
    // Fallback only if sysctl fails for our own PID; then the recorded start time won't match a peer's
    // sysctl re-read, weakening same-host liveness detection (acceptable: sysctl effectively always succeeds for self).
    private let ownStartTime = LibraryOpenLockManager.processStartTime(pid: ProcessInfo.processInfo.processIdentifier) ?? Date().timeIntervalSince1970

    private var timers: [URL: Timer] = [:]   // bundleURL → heartbeat timer

    /// Exposed for the same-host check in the conflict dialog.
    var currentHostUUIDString: String { hostUUID }

    enum Acquire: Equatable {
        case acquired
        case conflict(LibraryOpenLockInfo)
        case unprotected
    }

    private func makeInfo(now: Double) -> LibraryOpenLockInfo {
        LibraryOpenLockInfo(hostUUID: hostUUID, hostName: hostName, pid: pid,
                            processStartTime: ownStartTime, appInstanceUUID: instanceUUID,
                            acquiredAt: now, heartbeatAt: now)
    }

    /// Try to acquire. On `.acquired` a heartbeat timer is started.
    func acquire(bundleURL: URL) -> Acquire {
        let now = Date().timeIntervalSince1970
        let outcome = LibraryOpenLock.acquire(bundleURL: bundleURL, ourInfo: makeInfo(now: now),
                                              now: now, isPidAlive: Self.isPidAlive)
        switch outcome {
        case .acquired: startHeartbeat(bundleURL: bundleURL); return .acquired
        case .conflict(let info): return .conflict(info)
        case .unprotected:
            Self.logger.warning("Opening WITHOUT lock protection (could not write \(LibraryOpenLock.fileName)) for \(bundleURL.lastPathComponent, privacy: .public)")
            return .unprotected
        }
    }

    /// User chose "force open": overwrite and start the heartbeat.
    func forceAcquire(bundleURL: URL) {
        LibraryOpenLock.forceAcquire(bundleURL: bundleURL, ourInfo: makeInfo(now: Date().timeIntervalSince1970))
        startHeartbeat(bundleURL: bundleURL)
    }

    func release(bundleURL: URL) {
        let hadTimer = timers[bundleURL] != nil
        timers[bundleURL]?.invalidate()
        timers[bundleURL] = nil
        LibraryOpenLock.release(bundleURL: bundleURL, instanceUUID: instanceUUID)
        // Balance the disableSuddenTermination() taken in startHeartbeat for this held lock.
        if hadTimer { ProcessInfo.processInfo.enableSuddenTermination() }
    }

    func releaseAll() {
        // Snapshot the keys: `release` mutates `timers`, so iterate a copy to avoid "mutated while iterating".
        for url in Array(timers.keys) { release(bundleURL: url) }
    }

    private func startHeartbeat(bundleURL: URL) {
        let isNew = timers[bundleURL] == nil
        timers[bundleURL]?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: LibraryOpenLock.heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // ★ ここは意図的に同期のまま（G35 Codex P1 を受けて一度オフスレッド化したものを戻した）。
                //
                // オフスレッド化すると `release(bundleURL:)` と競合する: ハートビートが
                // 「ロックを読んだ後・書く前」に release が走ると、**削除したロックファイルを
                // 書き戻してしまう**。残った stale ロックは `staleThreshold`（90 秒）まで
                // 他マシンをブロックする ―― **クロスマシンのロックはこの機能の存在理由そのもの**。
                //
                // 一方、メインスレッド占有は実測 **0.34%**（45 秒窓で 103/約 30,000 サンプル。
                // 間隔は 30 秒・庫ごと）にすぎず、G35 の成果（実働 2.7% → 0.0%）はほぼ全部が
                // `FolderWatcher` 側だった。**この交換は割に合わない。**
                //
                // 正しくオフスレッド化するにはロックファイル I/O を直列化する必要があり
                // （release の削除がハートビートの書き込みより後に来ることを保証する）、
                // それは独立した設計。Backlog へ。
                let alive = LibraryOpenLock.heartbeat(bundleURL: bundleURL,
                                                      instanceUUID: self.instanceUUID,
                                                      now: Date().timeIntervalSince1970)
                if !alive {
                    Self.logger.warning("Lost lock ownership for \(bundleURL.lastPathComponent, privacy: .public); stopping heartbeat")
                    self.release(bundleURL: bundleURL)   // clears timer + re-enables sudden termination; on-disk release no-ops (not ours)
                }
            }
        }
        timers[bundleURL] = t
        // Hold off macOS sudden termination while we own a lock, so applicationWillTerminate
        // (→ releaseAll) is guaranteed to run on ⌘Q and delete the lock file.
        if isNew { ProcessInfo.processInfo.disableSuddenTermination() }
    }

    // MARK: - Environment helpers

    private static func currentHostUUID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        var wait = timespec(tv_sec: 5, tv_nsec: 0)
        _ = bytes.withUnsafeMutableBufferPointer { gethostuuid($0.baseAddress, &wait) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func isPidAlive(_ pid: Int32, recordedStartTime: Double) -> Bool {
        if pid <= 0 { return false }
        if kill(pid, 0) != 0 { return errno == EPERM }   // ESRCH → dead; EPERM → alive (other user)
        guard let actual = processStartTime(pid: pid), recordedStartTime > 0 else { return true }
        return abs(actual - recordedStartTime) < pidStartTimeTolerance   // mismatch → PID was reused → treat as dead
    }

    static func processStartTime(pid: Int32) -> Double? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let r = mib.withUnsafeMutableBufferPointer { mibp in
            sysctl(mibp.baseAddress, 4, &info, &size, nil, 0)
        }
        guard r == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
    }
}
