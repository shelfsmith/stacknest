// SPDX-License-Identifier: MIT
import Foundation
import SwiftUI
import LibraryServer
import AppCore

/// 127.0.0.1 専用のローカル制御エンドポイント（CLI/MCP 用）。ネットワーク共有とは独立。
@Observable
@MainActor
final class LocalControlController {
    static let shared = LocalControlController()
    private(set) var isRunning = false
    private var serverTask: Task<Void, Never>?

    func startIfEnabled() {
        guard ServerPreferences.localAutomationEnabled() else { return }
        guard !isRunning else { return }
        let config = LibraryServerConfig(
            host: "127.0.0.1",
            port: ServerPreferences.localControlPort(),
            token: UUID().uuidString,                          // 使い捨て read（誰も使わない）
            editToken: ServerPreferences.localControlToken(),  // CLI が提示する RW
            transcoder: ImageIOTranscoder(),
            defaultPageDirection: ViewerSettings.shared.pageDirection,
            onBookChanged: { uuid, bookID in
                Task { @MainActor in
                    for state in AppState.activeInstances.allObjects
                    where state.librarySettings?.libraryUUID == uuid {
                        state.handleExternalBookChange(bookID: bookID)
                    }
                }
            },
            onLibrarySettingsChanged: { uuid in
                Task { @MainActor in
                    for state in AppState.activeInstances.allObjects
                    where state.librarySettings?.libraryUUID == uuid {
                        state.librarySettings?.reloadStampDefinitions()
                        state.librarySettings?.reloadCustomLabels()
                    }
                }
            },
            autoClassifyEnabled: ViewerSettings.shared.autoClassifyEnabled,
            thickThreshold: ViewerSettings.shared.thickBookThreshold,
            trashFile: { url in try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        )
        let core = LibraryServerCore(config: config, dataSource: AllOpenLibrariesDataSource())
        let app = core.buildApplication()
        isRunning = true
        serverTask = Task {
            do { try await app.runService() } catch { /* loopback shutdown は無視 */ }
            await MainActor.run { self.isRunning = false }
        }
    }

    func stop() {
        serverTask?.cancel()
        serverTask = nil
        isRunning = false
    }

    func reload() { stop(); startIfEnabled() }
}
