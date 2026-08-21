// SPDX-License-Identifier: MIT
import CoreGraphics
import Foundation
import Observation
import LibraryStore

/// UserDefaults を 1〜2 キーでラップする @Observable @MainActor クラス。
/// テスト用に suite を注入できる。
///
/// - `externalViewerAppPath`: 全 category の default fallback (既存 API、UserDefaults key 維持)
/// - `categoryViewerPaths`: category 別の viewer override。未設定 category は default fallback を使う。
///   JSON-encoded `Data` として 1 key で保存。
@Observable
@MainActor
public final class ViewerSettings {
    /// プロセス全体で 1 instance のみ。SettingsView と各 LibraryWindow が同じ
    /// instance を bind する必要があるため (別 instance だと UserDefaults には書かれても
    /// 動作中の HelperLauncher が古い state を見続けて「再起動するまで反映されない」になる)。
    public static let shared = ViewerSettings()

    private let defaults: UserDefaults
    private let defaultKey = "externalViewerAppPath"
    private let categoryKey = "categoryViewerPaths"
    private let autoClassifyKey = "autoClassifyEnabled"
    private let thickThresholdKey = "thickBookThreshold"
    private let useBuiltInViewerKey = "useBuiltInViewer"
    private let pageDirectionKey = "viewerPageDirection"
    private let endOfBookBehaviorKey = "viewerEndOfBookBehavior"
    private let autoAdvanceIntervalKey = "viewerAutoAdvanceInterval"
    private let tabSkipPageCountKey = "viewerTabSkipPageCount"
    private let spreadByDefaultKey = "viewerSpreadByDefault"
    private let openFullScreenByDefaultKey = "viewerOpenFullScreenByDefault"
    private let showBookIDInDetailKey = "showBookIDInDetail"
    private let allowMultipleViewerWindowsKey = "viewerAllowMultipleWindows"
    private let loupeMagnificationKey = "viewerLoupeMagnification"
    private let loupeShapeKey = "viewerLoupeShape"
    private let loupeSizeKey = "viewerLoupeSize"

    /// Phase 2.5g: 新規追加 book の bookType 自動分類を有効化するか (default true)。
    public var autoClassifyEnabled: Bool {
        didSet { defaults.set(autoClassifyEnabled, forKey: autoClassifyKey) }
    }

    /// Phase 2.5g: archive の page 数閾値 (default 20)。範囲 5...100 を Settings UI + setter で強制。
    /// Phase 2.5g+h+i fixup v3: setter 内 clamp + 再代入ガード。
    /// 200 等の範囲外を代入すると、即時 5 または 100 に clamp され、@Observable 経由で
    /// UI (TextField 等) に通知される。
    public var thickBookThreshold: Int {
        didSet {
            let clamped = max(5, min(100, thickBookThreshold))
            if clamped != thickBookThreshold {
                // 範囲外なら clamped 値で再代入 → didSet が再発火 → else 経路で persist
                thickBookThreshold = clamped
                return
            }
            defaults.set(thickBookThreshold, forKey: thickThresholdKey)
        }
    }

    /// Phase 2.6b: 内蔵ビューアを使うか (default true)。false なら外部ビューア。
    public var useBuiltInViewer: Bool {
        didSet { defaults.set(useBuiltInViewer, forKey: useBuiltInViewerKey) }
    }

    /// Phase 2.6b: ページ送り方向 (default .rightToLeft)。
    public var pageDirection: PageDirection {
        didSet { defaults.set(pageDirection.rawValue, forKey: pageDirectionKey) }
    }

    /// Phase 2.6b: 最終ページの「次」の挙動 (default .stop)。UI 解放は 2.6b-2。
    public var endOfBookBehavior: EndOfBookBehavior {
        didSet { defaults.set(endOfBookBehavior.rawValue, forKey: endOfBookBehaviorKey) }
    }


    /// Phase 2.6b-2: スライドショー（自動進行）の間隔（秒）。既定 5.0。Settings で変更可（グローバル）。
    public var autoAdvanceInterval: Double {
        didSet { defaults.set(autoAdvanceInterval, forKey: autoAdvanceIntervalKey) }
    }

    /// Phase 2.6b-2-3: Tab/⇧Tab スキップ時のページ数。既定 10。範囲 1...100 を強制。
    public var tabSkipPageCount: Int {
        didSet {
            let clamped = max(1, min(100, tabSkipPageCount))
            if clamped != tabSkipPageCount {
                tabSkipPageCount = clamped
                return
            }
            defaults.set(tabSkipPageCount, forKey: tabSkipPageCountKey)
        }
    }

    /// Phase 2.6b-2 T5: per-book 見開き設定が未保存のとき内蔵ビューアで見開き表示をデフォルトにするか。
    /// UserDefaults key "viewerSpreadByDefault"、T-S1 fixup により初期値 true (= 見開き)。
    public var spreadByDefault: Bool {
        didSet { defaults.set(spreadByDefault, forKey: spreadByDefaultKey) }
    }

    /// Phase 2.6b-2 T-F1: 内蔵ビューアを全画面で開くか（全 book 共通グローバル設定）。
    /// UserDefaults key "viewerOpenFullScreenByDefault"、初期値 false。
    public var openFullScreenByDefault: Bool {
        didSet { defaults.set(openFullScreenByDefault, forKey: openFullScreenByDefaultKey) }
    }

    /// G13 F2a: 詳細ペインに book ID を表示するか（app-global・ローカル/リモート共有・既定 false）。
    public var showBookIDInDetail: Bool {
        didSet { defaults.set(showBookIDInDetail, forKey: showBookIDInDetailKey) }
    }

    /// G15 V1: 内蔵ビューアで別々の本を複数ウィンドウで開くのを許可するか（app-global・既定 false）。
    /// false=別の本を開くと既存ビューアを閉じて1つに保つ／true=別の本は別ウィンドウ。同一本は常に1つに集約。
    public var allowMultipleViewerWindows: Bool {
        didSet { defaults.set(allowMultipleViewerWindows, forKey: allowMultipleViewerWindowsKey) }
    }

    /// G40: ルーペの倍率。範囲 1.5...8.0、既定 2.0。setter で clamp する
    /// （`thickBookThreshold` と同じ「再代入して didSet を再発火させる」方式）。
    public var loupeMagnification: Double {
        didSet {
            let clamped = Double(LoupeMagnification.clamp(CGFloat(loupeMagnification)))
            if clamped != loupeMagnification {
                loupeMagnification = clamped
                return
            }
            defaults.set(loupeMagnification, forKey: loupeMagnificationKey)
            NotificationCenter.default.post(name: .viewerLoupeAppearanceChanged, object: nil)
        }
    }

    /// G40: ルーペの形（円 / 正方形）。グローバル設定。
    public var loupeShape: LoupeShape {
        didSet {
            defaults.set(loupeShape.rawValue, forKey: loupeShapeKey)
            NotificationCenter.default.post(name: .viewerLoupeAppearanceChanged, object: nil)
        }
    }

    /// G40: ルーペの大きさ（小 / 中 / 大）。グローバル設定。
    public var loupeSize: LoupeSize {
        didSet {
            defaults.set(loupeSize.rawValue, forKey: loupeSizeKey)
            NotificationCenter.default.post(name: .viewerLoupeAppearanceChanged, object: nil)
        }
    }

    /// 現在の設定から ViewerOptions を組み立てる（ViewerModel に渡す）。
    public var viewerOptions: ViewerOptions {
        ViewerOptions(pageDirection: pageDirection, endOfBookBehavior: endOfBookBehavior)
    }

    /// 全 category の fallback。既存 UserDefaults key (`externalViewerAppPath`) をそのまま維持。
    public var externalViewerAppPath: String? {
        didSet {
            if let value = externalViewerAppPath {
                defaults.set(value, forKey: defaultKey)
            } else {
                defaults.removeObject(forKey: defaultKey)
            }
        }
    }

    /// category 別 viewer override。nil の category は `externalViewerAppPath` に fallback。
    /// JSON-encoded Data として 1 key で保存。
    public var categoryViewerPaths: [BookCategory: String] {
        didSet {
            if categoryViewerPaths.isEmpty {
                defaults.removeObject(forKey: categoryKey)
            } else if let data = try? JSONEncoder().encode(categoryViewerPaths) {
                defaults.set(data, forKey: categoryKey)
            }
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.externalViewerAppPath = defaults.string(forKey: defaultKey)
        // Phase 2.5g: default ON for autoClassifyEnabled. UserDefaults bool(forKey:) returns false
        // when the key is absent, so use object(forKey:) to detect first-run state.
        if defaults.object(forKey: autoClassifyKey) == nil {
            self.autoClassifyEnabled = true
        } else {
            self.autoClassifyEnabled = defaults.bool(forKey: autoClassifyKey)
        }
        // Phase 2.5g: clamp stored threshold to [5, 100]; reset to default 20 outside range or unset.
        let storedThreshold = defaults.integer(forKey: thickThresholdKey)
        self.thickBookThreshold = storedThreshold >= 5 && storedThreshold <= 100 ? storedThreshold : 20
        // Phase 2.6b: useBuiltInViewer は first-run (key 不在) で true。
        if defaults.object(forKey: useBuiltInViewerKey) == nil {
            self.useBuiltInViewer = true
        } else {
            self.useBuiltInViewer = defaults.bool(forKey: useBuiltInViewerKey)
        }
        if let raw = defaults.string(forKey: pageDirectionKey),
           let dir = PageDirection(rawValue: raw) {
            self.pageDirection = dir
        } else {
            self.pageDirection = .defaultValue
        }
        if let raw = defaults.string(forKey: endOfBookBehaviorKey),
           let beh = EndOfBookBehavior(rawValue: raw) {
            self.endOfBookBehavior = beh
        } else {
            self.endOfBookBehavior = .defaultValue
        }
        // Phase 2.6b-2: autoAdvanceInterval は key 不在で 5.0。
        if defaults.object(forKey: autoAdvanceIntervalKey) == nil {
            self.autoAdvanceInterval = 5.0
        } else {
            self.autoAdvanceInterval = defaults.double(forKey: autoAdvanceIntervalKey)
        }
        // Phase 2.6b-2-3: tabSkipPageCount は key 不在または範囲外で 10。
        let storedSkip = defaults.integer(forKey: tabSkipPageCountKey)
        self.tabSkipPageCount = (storedSkip >= 1 && storedSkip <= 100) ? storedSkip : 10
        // Phase 2.6b-2 T5 / T-S1 fixup: spreadByDefault は key 不在で true（見開きをデフォルト ON）。
        // 明示的に false が保存されている場合は false を維持する。
        if defaults.object(forKey: spreadByDefaultKey) == nil {
            self.spreadByDefault = true
        } else {
            self.spreadByDefault = defaults.bool(forKey: spreadByDefaultKey)
        }
        // Phase 2.6b-2 T-F1: openFullScreenByDefault は key 不在で false。
        if defaults.object(forKey: openFullScreenByDefaultKey) == nil {
            self.openFullScreenByDefault = false
        } else {
            self.openFullScreenByDefault = defaults.bool(forKey: openFullScreenByDefaultKey)
        }
        // G13 F2a: showBookIDInDetail は key 不在で false (defaults.bool(forKey:) の既定と一致するため
        // first-run 特別扱い不要)。
        self.showBookIDInDetail = defaults.bool(forKey: showBookIDInDetailKey)
        // G15 V1: allowMultipleViewerWindows は key 不在で false (defaults.bool(forKey:) の既定と一致するため
        // first-run 特別扱い不要)。
        self.allowMultipleViewerWindows = defaults.bool(forKey: allowMultipleViewerWindowsKey)
        // G40: 保存値が範囲外／未知でも畳んで読む。キー不在なら既定。
        if defaults.object(forKey: loupeMagnificationKey) == nil {
            self.loupeMagnification = Double(LoupeMagnification.defaultValue)
        } else {
            self.loupeMagnification = Double(LoupeMagnification.clamp(
                CGFloat(defaults.double(forKey: loupeMagnificationKey))))
        }
        if let raw = defaults.string(forKey: loupeShapeKey), let shape = LoupeShape(rawValue: raw) {
            self.loupeShape = shape
        } else {
            self.loupeShape = .defaultValue
        }
        if let raw = defaults.string(forKey: loupeSizeKey), let size = LoupeSize(rawValue: raw) {
            self.loupeSize = size
        } else {
            self.loupeSize = .defaultValue
        }
        // TODO(2.5e+): silent decode failure here resets the entire categoryViewerPaths map.
        // Consider decoding into [String: String] first and skipping unknown keys to preserve
        // partial state when a BookCategory case is later renamed/removed.
        if let data = defaults.data(forKey: categoryKey),
           let decoded = try? JSONDecoder().decode([BookCategory: String].self, from: data) {
            self.categoryViewerPaths = decoded
        } else {
            self.categoryViewerPaths = [:]
        }
    }

    /// 指定 category の有効な viewer path を返す。
    /// category override → default fallback の順で解決。両方 nil なら nil を返す。
    public func resolvedViewerPath(for category: BookCategory) -> String? {
        if let override = categoryViewerPaths[category], !override.isEmpty {
            return override
        }
        return externalViewerAppPath
    }
}

public extension Notification.Name {
    /// G40: ルーペの見た目（倍率・形）が変わった。開いているビューア窓が再描画するために使う。
    static let viewerLoupeAppearanceChanged =
        Notification.Name("app.shelfsmith.stacknest.viewerLoupeAppearanceChanged")
}
