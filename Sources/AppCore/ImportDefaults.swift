// SPDX-License-Identifier: MIT
import Foundation

/// 取り込み設定のグローバル既定アクセサと per-library override 解決。
/// グローバルは ViewerSettings と同じ UserDefaults キーを参照（二重管理回避）。nonisolated＝サーバから可。
public enum ImportDefaults {
    public static let autoClassifyKey = "autoClassifyEnabled"
    public static let thickThresholdKey = "thickBookThreshold"
    public static let libAutoClassifyKey = "import_auto_classify"
    public static let libThickThresholdKey = "import_thick_threshold"
    public static func globalAutoClassify(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: autoClassifyKey) == nil ? true : defaults.bool(forKey: autoClassifyKey)
    }
    public static func globalThickThreshold(defaults: UserDefaults = .standard) -> Int {
        let v = defaults.integer(forKey: thickThresholdKey); return (5...100).contains(v) ? v : 20
    }
    public static func setGlobalAutoClassify(_ v: Bool, defaults: UserDefaults = .standard) { defaults.set(v, forKey: autoClassifyKey) }
    public static func setGlobalThickThreshold(_ v: Int, defaults: UserDefaults = .standard) { defaults.set(max(5, min(100, v)), forKey: thickThresholdKey) }
    public static func effectiveAutoClassify(override: Bool?, defaults: UserDefaults = .standard) -> Bool { override ?? globalAutoClassify(defaults: defaults) }
    public static func effectiveThickThreshold(override: Int?, defaults: UserDefaults = .standard) -> Int { override ?? globalThickThreshold(defaults: defaults) }
}
