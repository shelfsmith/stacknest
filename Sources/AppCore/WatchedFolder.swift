// SPDX-License-Identifier: MIT
import Foundation

/// 監視フォルダ設定（per-library）。ライブラリバンドル設定 DB に JSON 永続。
public struct WatchedFolder: Identifiable, Codable, Sendable, Equatable {
    /// サブフォルダの扱い（G9 → G9b で 3-way 化）。raw 値は後方互換のため topLevelOnly/recurse を維持
    /// （archive は新規追加）。意味: topLevelOnly=サブフォルダを取り込まない（ignore）／
    /// archive=直下サブフォルダを各1冊／recurse=中のファイルを個別取込。
    public enum SubfolderMode: String, Codable, Sendable, Hashable, CaseIterable {
        case topLevelOnly   // ignore: 監視フォルダ直下のファイルのみ取込（サブフォルダは無視・既定）
        case archive        // 直下サブフォルダを1つ=1冊として取込（孫には降りない）＋直下の素ファイルも個別取込
        case recurse        // サブフォルダを再帰走査し中のファイルを個別取込
    }

    public let id: String          // 安定 ID（UUID 文字列）
    public var path: String        // 監視ディレクトリの絶対パス
    public var enabled: Bool       // このフォルダの有効/無効
    public var presetID: String?   // 取り込み時の FilenameFormatPreset.id（nil = ライブラリ既定）
    public var baseline: [String]  // 「既存スキップ」で除外する path 群（空 = 既存も取込対象）
    public var subfolderMode: SubfolderMode   // G9: サブフォルダの扱い

    public init(id: String, path: String, enabled: Bool = true,
                presetID: String? = nil, baseline: [String] = [],
                subfolderMode: SubfolderMode = .topLevelOnly) {
        self.id = id; self.path = path; self.enabled = enabled
        self.presetID = presetID; self.baseline = baseline
        self.subfolderMode = subfolderMode
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, enabled, presetID, baseline, subfolderMode
    }

    // 後方互換: 旧 JSON（subfolderMode 欠落）は .topLevelOnly。他フィールドの欠落も従来既定に。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        presetID = try c.decodeIfPresent(String.self, forKey: .presetID)
        baseline = try c.decodeIfPresent([String].self, forKey: .baseline) ?? []
        subfolderMode = try c.decodeIfPresent(SubfolderMode.self, forKey: .subfolderMode) ?? .topLevelOnly
    }
    // encode(to:) は全プロパティ Codable のため合成に任せる（CodingKeys を共有）。
}
