// SPDX-License-Identifier: MIT
import Foundation

/// 内蔵ビューワの操作意図。keyDown / ゾーンクリックはこの値に解決してから実行する。
/// 将来 rotate / toggleSpread 等を足す拡張点。
public enum ViewerAction: String, Codable, Sendable, CaseIterable {
    /// 論理（方向非依存）: Space / PageDown など。
    case nextPage, previousPage
    /// 空間（読む方向に追従）: ←/→・左右ゾーンクリック。controller が pageDirection で advance/goBack に解決。
    case pageLeftward, pageRightward
    case firstPage, lastPage
    case zoomIn, zoomOut, fitToWindow
    case toggleFullScreen, close
    /// Phase 2.6b-2: 見開き・スライドショー・末挙動・横長レイアウト・巻移動。
    case toggleSpread, toggleCoverOffset, toggleAutoAdvance, cyclePageLayout
    case nextVolume, prevVolume, cycleEndOfBookBehavior
    /// Phase 2.6b-2-2: キーバインドヘルプオーバーレイを表示する（? / h）。
    case showHelp
    /// Phase 2.6b-2-3: 数字キー 0〜9 でパーセント位置ジャンプ（0%/10%/…/90%）。
    case jumpToPercent0, jumpToPercent10, jumpToPercent20, jumpToPercent30, jumpToPercent40
    case jumpToPercent50, jumpToPercent60, jumpToPercent70, jumpToPercent80, jumpToPercent90
    /// Phase 2.6b-2-3: Tab/⇧Tab でページスキップ（tabSkipPageCount ページ分）。
    case skipForward, skipBackward
    /// Phase 2.6b-2 D3: 現在の本のページ方向を rtl ↔ ltr で切り替え、永続化する。
    case togglePageDirection

    /// このアクション実行後に HUD（ページ進捗）を一時表示すべきか。
    /// ナビゲーション系は true、ズーム/全画面/終了は false。
    /// 新規 ViewerAction を足したらここで必ず分類する（exhaustive switch なので付け忘れはコンパイルエラー）。
    public var showsHUD: Bool {
        switch self {
        case .nextPage, .previousPage, .pageLeftward, .pageRightward, .firstPage, .lastPage,
             .toggleSpread, .toggleCoverOffset, .toggleAutoAdvance, .cyclePageLayout,
             .nextVolume, .prevVolume, .cycleEndOfBookBehavior,
             .togglePageDirection:
            return true
        case .zoomIn, .zoomOut, .fitToWindow, .toggleFullScreen, .close:
            return false
        case .showHelp:
            return false  // 独自オーバーレイを持つ; progress HUD は表示しない
        case .jumpToPercent0, .jumpToPercent10, .jumpToPercent20, .jumpToPercent30, .jumpToPercent40,
             .jumpToPercent50, .jumpToPercent60, .jumpToPercent70, .jumpToPercent80, .jumpToPercent90,
             .skipForward, .skipBackward:
            return true
        }
    }
}

/// keyCode + 修飾キー。Codable（将来ユーザー設定で永続化）。
/// modifiers は NSEvent.ModifierFlags.rawValue のうち下記4ビットのみを正規化して格納する。
public struct KeyChord: Hashable, Codable, Sendable {
    public let keyCode: UInt16
    public let modifiers: UInt

    public init(keyCode: UInt16, modifiers: UInt = 0) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    // NSEvent.ModifierFlags の rawValue（AppKit に依存せず定数で持つ）。
    public static let command: UInt = 1 << 20
    public static let shift:   UInt = 1 << 17
    public static let control: UInt = 1 << 18
    public static let option:  UInt = 1 << 19
    /// chord 構築時に意味を持つ修飾ビットの集合（capsLock 等を無視するマスク）。
    public static let relevantMask: UInt = command | shift | control | option
}

/// chord → action の対応表。既定値を持ち、将来ユーザー設定で上書き可能。
public struct ViewerKeyBindings: Codable, Sendable {
    public var map: [KeyChord: ViewerAction]
    /// 印字可能キーの文字ベース対応表。keyCode はキーボード配列/テンキー依存（JIS・テンキーで
    /// `+`=69/41、`0`=82 等が US の 24/27/29 と一致しない）。keyCode 解決が外れたとき
    /// `charactersIgnoringModifiers` でフォールバックするための層（smoke v2/v3 で実証した root cause）。
    public var characterMap: [String: ViewerAction]

    public init(map: [KeyChord: ViewerAction], characterMap: [String: ViewerAction] = [:]) {
        self.map = map
        self.characterMap = characterMap
    }

    public func action(for chord: KeyChord) -> ViewerAction? { map[chord] }

    public func action(forCharacter character: String) -> ViewerAction? { characterMap[character] }

    /// 既定キーマップ。
    public static let defaults: ViewerKeyBindings = ViewerKeyBindings(map: [
        KeyChord(keyCode: 49): .nextPage,                                 // Space
        KeyChord(keyCode: 49, modifiers: KeyChord.shift): .previousPage,  // ⇧Space
        KeyChord(keyCode: 125): .nextPage,                                // ↓
        KeyChord(keyCode: 126): .previousPage,                            // ↑
        KeyChord(keyCode: 121): .nextPage,                                // PageDown
        KeyChord(keyCode: 116): .previousPage,                            // PageUp
        KeyChord(keyCode: 123): .pageLeftward,                            // ←
        KeyChord(keyCode: 124): .pageRightward,                           // →
        KeyChord(keyCode: 115): .firstPage,                               // Home
        KeyChord(keyCode: 119): .lastPage,                               // End
        KeyChord(keyCode: 24): .fitToWindow,                              // = → fit to window
        KeyChord(keyCode: 24, modifiers: KeyChord.shift): .zoomIn,        // + → zoom in
        KeyChord(keyCode: 27): .zoomOut,                                  // -
        // keyCode 29 (0) は削除 → characterMap の jumpToPercent0 にフォールスルー
        KeyChord(keyCode: 48): .skipForward,                              // Tab
        KeyChord(keyCode: 48, modifiers: KeyChord.shift): .skipBackward,  // ⇧Tab
        KeyChord(keyCode: 3, modifiers: KeyChord.command | KeyChord.control): .toggleFullScreen, // ⌃⌘F
        KeyChord(keyCode: 53): .close,                                    // Esc
        KeyChord(keyCode: 13, modifiers: KeyChord.command): .close,       // ⌘W
    ], characterMap: [
        "+": .zoomIn, "=": .fitToWindow, "-": .zoomOut,
        // 数字キー 0〜9: パーセント位置ジャンプ（0%/10%/…/90%）
        "0": .jumpToPercent0,  "1": .jumpToPercent10, "2": .jumpToPercent20,
        "3": .jumpToPercent30, "4": .jumpToPercent40, "5": .jumpToPercent50,
        "6": .jumpToPercent60, "7": .jumpToPercent70, "8": .jumpToPercent80,
        "9": .jumpToPercent90,
        "d": .toggleSpread,
        "s": .toggleAutoAdvance,
        "w": .cyclePageLayout,
        "]": .nextVolume,
        "[": .prevVolume,
        "e": .cycleEndOfBookBehavior,
        "P": .toggleCoverOffset,
        "?": .showHelp,
        "h": .showHelp,
        "r": .togglePageDirection,
    ])

    // MARK: - 変更・永続（Phase 2.7 キー再割当）

    public struct RebindConflict: Error, Equatable, Sendable {
        public let existing: ViewerAction
        public init(existing: ViewerAction) { self.existing = existing }
    }

    /// 指定 action に割り当たっている全キー（chord→character 順・各内は安定ソート）。
    public func boundBindings(for action: ViewerAction) -> [CapturedBinding] {
        let chords = map.filter { $0.value == action }.keys
            .sorted { ($0.keyCode, $0.modifiers) < ($1.keyCode, $1.modifiers) }
            .map { CapturedBinding.chord($0) }
        let chars = characterMap.filter { $0.value == action }.keys
            .sorted()
            .map { CapturedBinding.character($0) }
        return chords + chars
    }

    /// 同一物理キーが既に解決するアクション（無ければ nil）。
    /// classify の不変条件（文字割当は ⌘⌃⌥ 無し印字キー / chord はそれ以外）により、
    /// character は characterMap、chord は map のみを確認すれば衝突は網羅できる。
    public func existingAction(for capture: CapturedBinding) -> ViewerAction? {
        switch capture {
        case .character(let s): return characterMap[s]
        case .chord(let c):     return map[c]
        }
    }

    /// 競合は拒否（状態不変・使用中アクションを返す）。空き or 同 action なら確定。
    public mutating func assign(_ capture: CapturedBinding, to action: ViewerAction) -> Result<Void, RebindConflict> {
        if let existing = existingAction(for: capture), existing != action {
            return .failure(RebindConflict(existing: existing))
        }
        switch capture {
        case .character(let s): characterMap[s] = action
        case .chord(let c):     map[c] = action
        }
        return .success(())
    }

    public mutating func remove(_ capture: CapturedBinding, from action: ViewerAction) {
        switch capture {
        case .character(let s): if characterMap[s] == action { characterMap[s] = nil }
        case .chord(let c):     if map[c] == action { map[c] = nil }
        }
    }

    /// 指定 action のキーを既定へ戻す（現キーを除去し defaults の該当キーを設定）。
    /// defaults のキーが他 action で使用中なら上書きする（=既定復元を優先）。
    public mutating func resetAction(_ action: ViewerAction) {
        for c in map.filter({ $0.value == action }).keys { map[c] = nil }
        for s in characterMap.filter({ $0.value == action }).keys { characterMap[s] = nil }
        for capture in ViewerKeyBindings.defaults.boundBindings(for: action) {
            switch capture {
            case .character(let s): characterMap[s] = action
            case .chord(let c):     map[c] = action
            }
        }
    }

    /// 全キーを既定へ戻す。
    public mutating func resetAll() { self = .defaults }

    // MARK: - UserDefaults 永続（アプリ全体）

    public static let userDefaultsKey = "viewerKeyBindings"

    public static func load(_ ud: UserDefaults = .standard) -> ViewerKeyBindings {
        guard let data = ud.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode(ViewerKeyBindings.self, from: data)
        else { return .defaults }
        return decoded
    }

    public func save(_ ud: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            ud.set(data, forKey: ViewerKeyBindings.userDefaultsKey)
        }
    }
}
