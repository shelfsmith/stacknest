// SPDX-License-Identifier: MIT
import Foundation

/// 監視フォルダ設定（per-library）。ライブラリバンドル設定 DB に JSON 永続。
public struct WatchedFolder: Identifiable, Codable, Sendable, Equatable {
    public let id: String          // 安定 ID（UUID 文字列）
    public var path: String        // 監視ディレクトリの絶対パス
    public var enabled: Bool       // このフォルダの有効/無効
    public var presetID: String?   // 取り込み時の FilenameFormatPreset.id（nil = ライブラリ既定）
    public var baseline: [String]  // 「既存スキップ」で除外する path 群（空 = 既存も取込対象）

    public init(id: String, path: String, enabled: Bool = true,
                presetID: String? = nil, baseline: [String] = []) {
        self.id = id; self.path = path; self.enabled = enabled
        self.presetID = presetID; self.baseline = baseline
    }
}
