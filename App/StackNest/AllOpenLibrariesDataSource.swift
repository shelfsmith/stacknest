// SPDX-License-Identifier: MIT
import Foundation
import LibraryServer
import AppCore

/// 開いている全ライブラリを配信する（共有 ON 不問）。ローカル制御エンドポイント用。
struct AllOpenLibrariesDataSource: LibraryServerDataSource {
    func servedLibraries() async -> [ServedLibrary] {
        await MainActor.run {
            AppState.activeInstances.allObjects.compactMap { state in
                guard let db = state.database, let settings = state.librarySettings else { return nil }
                let uuid = settings.ensureLibraryUUID()
                return ServedLibrary(
                    uuid: uuid,
                    name: settings.resolvedName(fallback: state.bundleURL.deletingPathExtension().lastPathComponent),
                    bundleURL: state.bundleURL,
                    db: db,
                    isLocked: settings.lockPasswordHash != nil)
            }
        }
    }
}
