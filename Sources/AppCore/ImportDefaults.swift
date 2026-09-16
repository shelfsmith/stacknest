// SPDX-License-Identifier: MIT
import Foundation
import LibraryStore

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

    // MARK: - per-library override を DB(source of truth) から解決（全取り込み経路で統一・C-④b）
    public static func autoClassifyOverride(db: Database) -> Bool? {
        ((try? db.getLibrarySetting(key: libAutoClassifyKey)) ?? nil).map { $0 == "1" || $0 == "true" }
    }
    public static func thickThresholdOverride(db: Database) -> Int? {
        ((try? db.getLibrarySetting(key: libThickThresholdKey)) ?? nil).flatMap { Int($0) }
    }
    public static func effectiveAutoClassify(db: Database, defaults: UserDefaults = .standard) -> Bool {
        effectiveAutoClassify(override: autoClassifyOverride(db: db), defaults: defaults)
    }
    public static func effectiveThickThreshold(db: Database, defaults: UserDefaults = .standard) -> Int {
        effectiveThickThreshold(override: thickThresholdOverride(db: db), defaults: defaults)
    }

    // MARK: - G54-S4: EPUB の題名を使うか（取り込み設定）
    /// EPUB に題名があればそれを使うか（既定 false ＝ ファイル名から作った題名を使う）。
    /// 既定が false なので、鍵が無いときに false を返す `bool(forKey:)` をそのまま使える
    /// （`autoClassify` は既定 true なので `object(forKey:)` で first-run を見分けている）。
    public static let preferEPUBTitleKey = "importPreferEPUBTitle"
    public static let libPreferEPUBTitleKey = "import_prefer_epub_title"
    public static func globalPreferEPUBTitle(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: preferEPUBTitleKey)
    }
    public static func setGlobalPreferEPUBTitle(_ v: Bool, defaults: UserDefaults = .standard) {
        defaults.set(v, forKey: preferEPUBTitleKey)
    }
    public static func effectivePreferEPUBTitle(override: Bool?, defaults: UserDefaults = .standard) -> Bool {
        override ?? globalPreferEPUBTitle(defaults: defaults)
    }
    public static func preferEPUBTitleOverride(db: Database) -> Bool? {
        ((try? db.getLibrarySetting(key: libPreferEPUBTitleKey)) ?? nil).map { $0 == "1" || $0 == "true" }
    }
    public static func effectivePreferEPUBTitle(db: Database, defaults: UserDefaults = .standard) -> Bool {
        effectivePreferEPUBTitle(override: preferEPUBTitleOverride(db: db), defaults: defaults)
    }
}
