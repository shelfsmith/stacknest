// SPDX-License-Identifier: MIT
import Foundation
import LibraryStore

/// DB の library_setting から presetID に対応する FilenameFormat の raw 文字列を解決する。
/// nonisolated（サーバハンドラから MainActor 外で使う）。LibrarySettings(@MainActor) を構築しない。
public enum FilenameFormatResolver {
    private static let formatKey = "filename_format"
    private static let presetsKey = "filename_format_presets"

    public static func resolveRaw(database: Database, presetID: String?) -> String {
        let fallback = (try? database.getLibrarySetting(key: formatKey)).flatMap { $0 } ?? "@title"
        guard let presetID else { return fallback }
        if let json = (try? database.getLibrarySetting(key: presetsKey)).flatMap({ $0 }),
           let data = json.data(using: .utf8),
           let presets = try? JSONDecoder().decode([FilenameFormatPreset].self, from: data),
           let p = presets.first(where: { $0.id == presetID }) {
            return p.format
        }
        return fallback
    }
}
