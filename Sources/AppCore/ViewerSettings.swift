// SPDX-License-Identifier: MIT
import CoreGraphics
import Foundation
import Observation
import LibraryStore
import EPUBAdapter

/// UserDefaults を 1〜2 キーでラップする @Observable @MainActor クラス。
/// テスト用に suite を注入できる。
///
/// - `externalViewerAppPath`: 全 category の default fallback (既存 API、UserDefaults key 維持)
/// - `categoryViewerPaths`: category 別の viewer override。未設定 category は default fallback を使う。
///   JSON-encoded `Data` として 1 key で保存。
/// - `epubViewerAppPath`: EPUB だけの専用 viewer override（`categoryViewerPaths` とは別 key）。
///   未設定なら default fallback に落ちる（`.text` の category override は経由しない）。
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
    /// G54-S4 Task 8: `ImportDefaults.preferEPUBTitleKey` と同じ文字列リテラル。`autoClassifyEnabled` と
    /// 同様、グローバル既定の UserDefaults キーを ImportDefaults と共有する（二重管理回避）。
    private let preferEPUBTitleKey = "importPreferEPUBTitle"
    private let useBuiltInViewerKey = "useBuiltInViewer"
    private let useBuiltInEPUBViewerKey = "useBuiltInEPUBViewer"
    private let pageDirectionKey = "viewerPageDirection"
    private let endOfBookBehaviorKey = "viewerEndOfBookBehavior"
    private let autoAdvanceIntervalKey = "viewerAutoAdvanceInterval"
    private let tabSkipPageCountKey = "viewerTabSkipPageCount"
    private let spreadByDefaultKey = "viewerSpreadByDefault"
    private let openFullScreenByDefaultKey = "viewerOpenFullScreenByDefault"
    private let openEPUBFullScreenByDefaultKey = "viewerOpenEPUBFullScreenByDefault"
    private let showBookIDInDetailKey = "showBookIDInDetail"
    private let allowMultipleViewerWindowsKey = "viewerAllowMultipleWindows"
    private let loupeMagnificationKey = "viewerLoupeMagnification"
    private let loupeShapeKey = "viewerLoupeShape"
    private let loupeSizeKey = "viewerLoupeSize"
    private let epubFontScaleKey = "epubFontScale"
    private let epubThemeKey = "epubTheme"
    private let epubViewerAppPathKey = "epubViewerAppPath"
    private let pageTurnStyleKey = "pageTurnStyle"
    private let showsEPUBFolioKey = "showsEPUBFolio"
    /// G56 の旧キー。移行元としてのみ `init` で読む（移行後は消す）。
    private let legacyEPUBFontFamilyKey = "epubFontFamily"
    private let epubJapaneseFontFamilyKey = "epubJapaneseFontFamily"
    private let epubLatinFontFamilyKey = "epubLatinFontFamily"
    private let epubLightPaletteKey = "epubLightPalette"
    private let epubDarkPaletteKey = "epubDarkPalette"
    private let epubForcesReadableColorsKey = "epubForcesReadableColors"
    private let epubLightCustomBackgroundKey = "epubLightCustomBackground"
    private let epubLightCustomTextKey = "epubLightCustomText"
    private let epubDarkCustomBackgroundKey = "epubDarkCustomBackground"
    private let epubDarkCustomTextKey = "epubDarkCustomText"
    private let epubHorizontalWheelTurnsPagesKey = "epubHorizontalWheelTurnsPages"
    private let epubReversesHorizontalWheelTurnKey = "epubReversesHorizontalWheelTurn"

    /// Phase 2.5g: 新規追加 book の bookType 自動分類を有効化するか (default true)。
    public var autoClassifyEnabled: Bool {
        didSet { defaults.set(autoClassifyEnabled, forKey: autoClassifyKey) }
    }

    /// G54-S4 Task 8: 取り込み時に EPUB の題名があればそれを使うか (default false ＝ ファイル名から
    /// 作った題名を使う)。`ImportDefaults.globalPreferEPUBTitle`/`setGlobalPreferEPUBTitle` と同じキーを
    /// 共有するので、サーバ側（`LibraryServerCore`）から書かれた値もこのプロパティにそのまま反映される。
    public var preferEPUBTitle: Bool {
        didSet { defaults.set(preferEPUBTitle, forKey: preferEPUBTitleKey) }
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
    /// G54-S2: **画像側**（アーカイブ・画像・フォルダ・PDF）だけを決める。
    /// UserDefaults のキーは `useBuiltInViewer` のまま据え置く（変えると既存の設定が消える）。
    public var useBuiltInImageViewer: Bool {
        didSet { defaults.set(useBuiltInImageViewer, forKey: useBuiltInViewerKey) }
    }

    /// G54-S2: EPUB を内蔵で開くか。キー不在のときは画像側の値を写して既定にする
    /// （外部を選んでいた人が、更新した途端に EPUB だけ内蔵へ戻る事故を防ぐ）。
    public var useBuiltInEPUBViewer: Bool {
        didSet { defaults.set(useBuiltInEPUBViewer, forKey: useBuiltInEPUBViewerKey) }
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

    /// G51（Q3=C-2）: EPUB の窓を全画面で開くか。画像ビューアの `openFullScreenByDefault` とは独立
    /// （EPUB は行長が伸びると読みにくいので使い分けたい）。key 不在で false。
    public var openEPUBFullScreenByDefault: Bool {
        didSet { defaults.set(openEPUBFullScreenByDefault, forKey: openEPUBFullScreenByDefaultKey) }
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

    /// G48-2 smoke fix: EPUB 内蔵リーダーのフォント倍率（app-global・既定 1.0）。範囲 0.5...3.0 を
    /// setter で強制する（`loupeMagnification` と同じ「再代入して didSet を再発火させる」方式）。
    public var epubFontScale: Double {
        didSet {
            let clamped = EPUBFontScale.clamp(epubFontScale)
            if clamped != epubFontScale {
                epubFontScale = clamped
                return
            }
            defaults.set(epubFontScale, forKey: epubFontScaleKey)
        }
    }

    /// G54-S2b: EPUB の配色（既定はシステムの外観に従う）。
    /// G56-S3: 変わったら開いている EPUB の窓へ知らせる（以前は開いている窓に反映しなかった）。
    public var epubTheme: EPUBReaderThemeValue {
        didSet {
            defaults.set(epubTheme.rawValue, forKey: epubThemeKey)
            NotificationCenter.default.post(name: .viewerEPUBPresentationChanged, object: nil)
        }
    }

    /// G57: EPUB の和文書体（フォントのファミリー名）。nil ＝本の指定に従う。機械に無い書体は窓の側で nil
    /// 扱いにする（保存値は残す）。G56 の単一書体キー（`epubFontFamily`）はここへ移行する（`init` 参照）。
    public var epubJapaneseFontFamily: String? {
        didSet {
            if let epubJapaneseFontFamily { defaults.set(epubJapaneseFontFamily, forKey: epubJapaneseFontFamilyKey) }
            else { defaults.removeObject(forKey: epubJapaneseFontFamilyKey) }
            NotificationCenter.default.post(name: .viewerEPUBPresentationChanged, object: nil)
        }
    }

    /// G57: EPUB の欧文書体。nil ＝本の指定に従う（片方だけ指定すると、もう片方は既定の書体になる。
    /// §1.2 の CSS 側の制約）。
    public var epubLatinFontFamily: String? {
        didSet {
            if let epubLatinFontFamily { defaults.set(epubLatinFontFamily, forKey: epubLatinFontFamilyKey) }
            else { defaults.removeObject(forKey: epubLatinFontFamilyKey) }
            NotificationCenter.default.post(name: .viewerEPUBPresentationChanged, object: nil)
        }
    }

    /// G56-S3: ライトのときの背景（と文字色）の組。
    public var epubLightPalette: EPUBLightPalette {
        didSet {
            defaults.set(epubLightPalette.rawValue, forKey: epubLightPaletteKey)
            NotificationCenter.default.post(name: .viewerEPUBPresentationChanged, object: nil)
        }
    }

    /// G56-S3: ダークのときの背景（と文字色）の組。
    public var epubDarkPalette: EPUBDarkPalette {
        didSet {
            defaults.set(epubDarkPalette.rawValue, forKey: epubDarkPaletteKey)
            NotificationCenter.default.post(name: .viewerEPUBPresentationChanged, object: nil)
        }
    }

    /// G56-S3: 本の配色より読みやすさを優先する（既定 false ＝本の配色を尊重）。
    public var epubForcesReadableColors: Bool {
        didSet {
            defaults.set(epubForcesReadableColors, forKey: epubForcesReadableColorsKey)
            NotificationCenter.default.post(name: .viewerEPUBPresentationChanged, object: nil)
        }
    }

    /// G57: ライトのカスタム背景色・文字色（`#RRGGBB`）。`epubLightPalette == .custom` のときに使う。
    /// 未設定（nil）のまま画面で「カスタム」を選んだ直後は `ensureCustomColors(dark:)` で埋める。
    public var epubLightCustomColors: EPUBPaletteColors? {
        didSet {
            persistCustomColors(epubLightCustomColors, backgroundKey: epubLightCustomBackgroundKey, textKey: epubLightCustomTextKey)
            NotificationCenter.default.post(name: .viewerEPUBPresentationChanged, object: nil)
        }
    }

    /// G57: ダークのカスタム背景色・文字色。`epubDarkPalette == .custom` のときに使う。
    public var epubDarkCustomColors: EPUBPaletteColors? {
        didSet {
            persistCustomColors(epubDarkCustomColors, backgroundKey: epubDarkCustomBackgroundKey, textKey: epubDarkCustomTextKey)
            NotificationCenter.default.post(name: .viewerEPUBPresentationChanged, object: nil)
        }
    }

    /// G57: 横方向のスクロール／トラックパッドの横振れでページを送るか（既定 true）。
    public var epubHorizontalWheelTurnsPages: Bool {
        didSet {
            defaults.set(epubHorizontalWheelTurnsPages, forKey: epubHorizontalWheelTurnsPagesKey)
            NotificationCenter.default.post(name: .viewerEPUBPresentationChanged, object: nil)
        }
    }

    /// G57: 横方向のページ送りの向きを反対にするか（既定 false）。`epubHorizontalWheelTurnsPages` が
    /// false のときは画面側で灰色にする（このプロパティ自体は独立して保存する）。
    public var epubReversesHorizontalWheelTurn: Bool {
        didSet {
            defaults.set(epubReversesHorizontalWheelTurn, forKey: epubReversesHorizontalWheelTurnKey)
            NotificationCenter.default.post(name: .viewerEPUBPresentationChanged, object: nil)
        }
    }

    /// G57: 画面が「カスタム」を選んだ直後に呼ぶ。カスタムの色が未設定なら、その時点のプリセットの色
    /// （標準や `.custom` 自身で色が無いときは `EPUBWashiDefaultColors`）で埋める。既に値があれば変えない。
    public func ensureCustomColors(dark: Bool) {
        if dark {
            guard epubDarkCustomColors == nil else { return }
            epubDarkCustomColors = epubDarkPalette.colors ?? EPUBWashiDefaultColors.dark
        } else {
            guard epubLightCustomColors == nil else { return }
            epubLightCustomColors = epubLightPalette.colors ?? EPUBWashiDefaultColors.light
        }
    }

    /// G56-S3: 窓が reader へ渡す見た目の一式。
    public var epubAppearance: EPUBAppearanceValue {
        EPUBAppearanceValue(theme: epubTheme, lightPalette: epubLightPalette, darkPalette: epubDarkPalette,
                            lightCustom: epubLightCustomColors, darkCustom: epubDarkCustomColors,
                            japaneseFontFamily: epubJapaneseFontFamily, latinFontFamily: epubLatinFontFamily,
                            forcesReadableColors: epubForcesReadableColors)
    }

    /// `#RRGGBB` の背景・文字の 2 キーへ書く（nil なら両方消す）。
    private func persistCustomColors(_ colors: EPUBPaletteColors?, backgroundKey: String, textKey: String) {
        if let colors {
            defaults.set(colors.background.hexString, forKey: backgroundKey)
            defaults.set(colors.text.hexString, forKey: textKey)
        } else {
            defaults.removeObject(forKey: backgroundKey)
            defaults.removeObject(forKey: textKey)
        }
    }

    /// `#RRGGBB` の背景・文字の 2 キーを読む。片方でも欠けている／壊れていれば nil（標準の見た目に倒す）。
    private static func loadCustomColors(from defaults: UserDefaults, backgroundKey: String, textKey: String) -> EPUBPaletteColors? {
        guard let backgroundHex = defaults.string(forKey: backgroundKey), let background = EPUBRGB(hexString: backgroundHex),
              let textHex = defaults.string(forKey: textKey), let text = EPUBRGB(hexString: textHex) else {
            return nil
        }
        return EPUBPaletteColors(background: background, text: text)
    }

    /// G54-S3: ページ送りの演出（画像ビューアと EPUB の両方に効く・既定は演出なし）。
    /// 画像ビューアは送りのたびにこの値を読む。EPUB の窓は通知を受けて開いている reader へ入れ直す。
    public var pageTurnStyle: PageTurnStyleValue {
        didSet {
            defaults.set(pageTurnStyle.rawValue, forKey: pageTurnStyleKey)
            NotificationCenter.default.post(name: .viewerEPUBPresentationChanged, object: nil)
        }
    }

    /// G54-S3: EPUB の各ページの下余白に章内のノンブルを出すか（既定 false）。
    /// 本全体の位置は窓の HUD が出すので、既定では消す。
    public var showsEPUBFolio: Bool {
        didSet {
            defaults.set(showsEPUBFolio, forKey: showsEPUBFolioKey)
            NotificationCenter.default.post(name: .viewerEPUBPresentationChanged, object: nil)
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

    /// G54-S2b: EPUB だけ別の外部ビューアを指定する。未設定なら既定へ落ちる（`.text` の指定は経由しない。
    /// smoke のコメント: テキスト用に選ぶアプリは EPUB を開けないことが多いため）。
    /// `BookCategory` は `pdf` `epub` `txt` `md` `rtf` をまとめて `.text` に入れるため、
    /// 分類を増やさずにここで分ける（分類を増やすと `ContentEndpoints.formatString` 経由で
    /// Web とリモートの通信内容まで変わってしまう）。
    /// `categoryViewerPaths` に鍵を足さないのは、あちらが未知の鍵 1 つでデコードごと失敗して
    /// 全カテゴリの指定が消える作りだから（上の TODO 参照）。
    /// 永続化は `externalViewerAppPath` と同じ書き方（nil のときだけキーを消す）に揃える。
    public var epubViewerAppPath: String? {
        didSet {
            if let value = epubViewerAppPath {
                defaults.set(value, forKey: epubViewerAppPathKey)
            } else {
                defaults.removeObject(forKey: epubViewerAppPathKey)
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
        self.epubViewerAppPath = defaults.string(forKey: epubViewerAppPathKey)
        // Phase 2.5g: default ON for autoClassifyEnabled. UserDefaults bool(forKey:) returns false
        // when the key is absent, so use object(forKey:) to detect first-run state.
        if defaults.object(forKey: autoClassifyKey) == nil {
            self.autoClassifyEnabled = true
        } else {
            self.autoClassifyEnabled = defaults.bool(forKey: autoClassifyKey)
        }
        // G54-S4 Task 8: preferEPUBTitle は既定 false なので、鍵が無いときに false を返す
        // `bool(forKey:)` をそのまま使える（`ImportDefaults.globalPreferEPUBTitle` と同じ考え方）。
        self.preferEPUBTitle = defaults.bool(forKey: preferEPUBTitleKey)
        // Phase 2.5g: clamp stored threshold to [5, 100]; reset to default 20 outside range or unset.
        let storedThreshold = defaults.integer(forKey: thickThresholdKey)
        self.thickBookThreshold = storedThreshold >= 5 && storedThreshold <= 100 ? storedThreshold : 20
        // Phase 2.6b: useBuiltInViewer は first-run (key 不在) で true。
        // G54-S2: Swift の 2 段階初期化では、他の格納プロパティが全て初期化されるまで
        // `self.useBuiltInImageViewer` を読み戻せない（直前に代入していても読めない）ため、
        // ローカル変数に確定値を持たせてから EPUB 側の写しに使う。
        let resolvedImageViewer: Bool
        if defaults.object(forKey: useBuiltInViewerKey) == nil {
            resolvedImageViewer = true
        } else {
            resolvedImageViewer = defaults.bool(forKey: useBuiltInViewerKey)
        }
        self.useBuiltInImageViewer = resolvedImageViewer
        // G54-S2: EPUB 側はキー不在のとき画像側を写し、**その場で書き戻す**（次回からは写さない）。
        // init 内の代入では didSet が走らないので、明示的に書く必要がある。
        if defaults.object(forKey: useBuiltInEPUBViewerKey) == nil {
            self.useBuiltInEPUBViewer = resolvedImageViewer
            defaults.set(resolvedImageViewer, forKey: useBuiltInEPUBViewerKey)
        } else {
            self.useBuiltInEPUBViewer = defaults.bool(forKey: useBuiltInEPUBViewerKey)
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
        // G51: openEPUBFullScreenByDefault は key 不在で false（defaults.bool の既定と一致）。
        self.openEPUBFullScreenByDefault = defaults.bool(forKey: openEPUBFullScreenByDefaultKey)
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
        // G48-2 smoke fix: 保存値が範囲外／未知でも畳んで読む。キー不在なら既定。
        if defaults.object(forKey: epubFontScaleKey) == nil {
            self.epubFontScale = EPUBFontScale.defaultValue
        } else {
            self.epubFontScale = EPUBFontScale.clamp(defaults.double(forKey: epubFontScaleKey))
        }
        // 壊れた値や未知の値はシステムに倒す（epubFontScale が範囲外を既定へ戻すのと同じ考え方）。
        self.epubTheme = defaults.string(forKey: epubThemeKey)
            .flatMap(EPUBReaderThemeValue.init(rawValue:)) ?? .system
        // G57: G56 の単一書体キーからの移行。和文のキーがまだ無く、旧キーに空でない値があるときだけ、
        // 和文へ写して旧キーを消す（和文のキーが既にあれば上書きしない）。
        if defaults.object(forKey: epubJapaneseFontFamilyKey) == nil,
           let legacy = defaults.string(forKey: legacyEPUBFontFamilyKey), !legacy.isEmpty {
            defaults.set(legacy, forKey: epubJapaneseFontFamilyKey)
            defaults.removeObject(forKey: legacyEPUBFontFamilyKey)
        }
        // G56-S3/G57: 空文字・非文字列は「本の指定」に倒す。
        self.epubJapaneseFontFamily = defaults.string(forKey: epubJapaneseFontFamilyKey).flatMap { $0.isEmpty ? nil : $0 }
        self.epubLatinFontFamily = defaults.string(forKey: epubLatinFontFamilyKey).flatMap { $0.isEmpty ? nil : $0 }
        self.epubLightPalette = defaults.string(forKey: epubLightPaletteKey)
            .flatMap(EPUBLightPalette.init(rawValue:)) ?? .standard
        self.epubDarkPalette = defaults.string(forKey: epubDarkPaletteKey)
            .flatMap(EPUBDarkPalette.init(rawValue:)) ?? .standard
        self.epubForcesReadableColors = defaults.bool(forKey: epubForcesReadableColorsKey)
        // G57: 壊れた／片方欠けの #RRGGBB は nil（標準の見た目）に倒す。
        self.epubLightCustomColors = Self.loadCustomColors(
            from: defaults, backgroundKey: epubLightCustomBackgroundKey, textKey: epubLightCustomTextKey)
        self.epubDarkCustomColors = Self.loadCustomColors(
            from: defaults, backgroundKey: epubDarkCustomBackgroundKey, textKey: epubDarkCustomTextKey)
        // G57: キー不在で true（既定は「送る」）。
        if defaults.object(forKey: epubHorizontalWheelTurnsPagesKey) == nil {
            self.epubHorizontalWheelTurnsPages = true
        } else {
            self.epubHorizontalWheelTurnsPages = defaults.bool(forKey: epubHorizontalWheelTurnsPagesKey)
        }
        // キー不在で false（defaults.bool の既定と一致）。
        self.epubReversesHorizontalWheelTurn = defaults.bool(forKey: epubReversesHorizontalWheelTurnKey)
        // G54-S3: 壊れた値や未知の値は演出なしに倒す。`PageTurnStyleValue.off` と型を明示する。
        self.pageTurnStyle = defaults.string(forKey: pageTurnStyleKey)
            .flatMap(PageTurnStyleValue.init(rawValue:)) ?? PageTurnStyleValue.off
        // キー不在で false（defaults.bool の既定と一致）。
        self.showsEPUBFolio = defaults.bool(forKey: showsEPUBFolioKey)
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

    /// G54-S2b: パスも見て解決する。分類が `.text` かつ拡張子が `epub` のときは**専用指定 → 既定**の順で、
    /// **`.text` の指定は経由しない**（smoke のコメント: テキスト用に選ぶアプリは EPUB を開けないことが多い）。
    /// `category` を先に見るのは、展開済み EPUB のディレクトリ（`BookCategory.classify` は `.folder` にする）
    /// を拡張子だけで EPUB 指定に引っぱらないため（`ViewerChoice.viewerSwitch(forPath:)` と同じ形に揃える）。
    public func resolvedViewerPath(forPath path: String, category: BookCategory) -> String? {
        if category == .text, (path as NSString).pathExtension.lowercased() == "epub" {
            if let epub = epubViewerAppPath, !epub.isEmpty { return epub }
            return externalViewerAppPath
        }
        return resolvedViewerPath(for: category)
    }
}

public extension Notification.Name {
    /// G40: ルーペの見た目（倍率・形）が変わった。開いているビューア窓が再描画するために使う。
    static let viewerLoupeAppearanceChanged =
        Notification.Name("app.shelfsmith.stacknest.viewerLoupeAppearanceChanged")

    /// G54-S3: EPUB の窓の見せ方（ページ送りの演出・ノンブル。G56-S3 で配色・書体・背景も）が変わった。
    /// 開いている EPUB の窓が reader へ入れ直す。
    static let viewerEPUBPresentationChanged =
        Notification.Name("app.shelfsmith.stacknest.viewerEPUBPresentationChanged")
}
