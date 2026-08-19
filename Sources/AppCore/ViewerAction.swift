// SPDX-License-Identifier: MIT
import Foundation

public extension Notification.Name {
    /// ビューアキー割当が保存されたとき発火（ヘルプ表示などの再読込トリガ）。
    static let viewerKeyBindingsChanged = Notification.Name("app.shelfsmith.stacknest.viewerKeyBindingsChanged")
}

/// 内蔵ビューアの操作意図。keyDown / ゾーンクリックはこの値に解決してから実行する。
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
    /// G38: ルーペのトグル。ON の間、カーソル位置の周辺を拡大表示する。
    case toggleLoupe

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
        case .zoomIn, .zoomOut, .fitToWindow, .toggleFullScreen, .close, .toggleLoupe:
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

    /// 保存した時点で**存在を知っていた**アクション（`ViewerAction.rawValue`）の集合。
    ///
    /// `nil` は「G38 以前に保存されたデータ」を意味する。当時はこの欄が無かったので、
    /// どのアクションが既知だったのかを後から知る術がない。
    ///
    /// これが要るのは、保存済みマップの中で「未バインドのアクション」に**二つの意味**が
    /// あるからだ —— ①保存後に新しく増えたアクション（キーを補うべき）と
    /// ②ユーザーが意図的にキーを外したアクション（触ってはいけない）。マップだけを見ても
    /// 両者は区別できない。既知の集合を覚えておくことで初めて分かれる。
    public var knownActions: Set<String>?

    /// 現時点で存在する全アクションの `rawValue`。
    public static let allActionKeys: Set<String> = Set(ViewerAction.allCases.map(\.rawValue))

    public init(
        map: [KeyChord: ViewerAction],
        characterMap: [String: ViewerAction] = [:],
        knownActions: Set<String>? = nil
    ) {
        self.map = map
        self.characterMap = characterMap
        self.knownActions = knownActions
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
        // keyCode 24 (=), 24+shift (+), 27 (-) は削除 → characterMap の fitToWindow/zoomIn/zoomOut にフォールスルー
        // （keyCode 29 (0) と同じ理由: characterMap 経由が JIS/テンキー非依存で確実）
        // keyCode 29 (0) は削除 → characterMap の jumpToPercent0 にフォールスルー
        KeyChord(keyCode: 48): .skipForward,                              // Tab
        KeyChord(keyCode: 48, modifiers: KeyChord.shift): .skipBackward,  // ⇧Tab
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
        "f": .toggleFullScreen,
        "l": .toggleLoupe,
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

    /// Esc（keyCode 53）はキー キャプチャのキャンセルに常用するため再割当不可。
    /// 既定の「閉じる」に固定し、UI からの削除も無効とする。
    public static func isFixed(_ capture: CapturedBinding) -> Bool {
        capture == .chord(KeyChord(keyCode: 53))
    }

    public mutating func remove(_ capture: CapturedBinding, from action: ViewerAction) {
        if Self.isFixed(capture) { return }
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
    ///
    /// `.defaults` の `knownActions` は nil なので、そのまま代入すると「旧データ」に化けて
    /// しまう（次の削除が `load()` で巻き戻る）。今の全アクションを既知として刻み直す。
    public mutating func resetAll() {
        self = .defaults
        knownActions = Self.allActionKeys
    }

    /// G38 final review C-1: 保存済みマップに存在しないアクションへ、defaults 側の既定バインドを補う。
    ///
    /// 新しい `ViewerAction`（例: toggleLoupe）を足しても、**既にキー設定を保存済みのユーザー**の
    /// `UserDefaults` には旧い `ViewerKeyBindings` がそのまま残っている。`load()` が単純に decode
    /// した値を返すだけだと、そのユーザーには新アクションのキーが一生届かない
    /// （defaults に "l" を足しても保存済みマップは知らないまま）。
    ///
    /// 補うのは **`knownActions` に載っていないアクション**、つまり保存後に新しく増えたものだけ。
    /// - ユーザーが明示的に変更したバインドには触れない（対象は未バインドのアクションのみ）。
    /// - **ユーザーが意図的に外したキーは復活させない。**「外した」は保存時に既知だった
    ///   アクションなので `knownActions` に載っており、ここで弾かれる（G38 再レビュー Important #1）。
    /// - 既に他のアクションが使っているキーは奪わない（衝突時はそのアクションを未バインドのまま残す）。
    ///
    /// `knownActions` が nil の旧データだけは「何も既知でない」扱いになり、未バインドの
    /// アクションを一律に補う。C-1 が塞ぎたかったのはまさにこの状態（`l` がどこにも無い保存済み設定）で、
    /// かつ当時は削除の意図を記録していなかったので、これが唯一取りうる解釈になる。
    /// 移行は 1 度きり —— 最後に現在の全アクションを既知として刻むので、次回以降は削除が残る。
    ///
    /// 今後 `ViewerAction` を足すたびに同じ穴が開くので、`toggleLoupe` 専用ではなく汎用の仕組みとして書く。
    public mutating func fillMissingActionsFromDefaults() {
        let known = knownActions ?? []
        for action in ViewerAction.allCases where !known.contains(action.rawValue) {
            guard boundBindings(for: action).isEmpty else { continue }  // 既にバインド済みなら触らない
            for capture in ViewerKeyBindings.defaults.boundBindings(for: action) {
                guard existingAction(for: capture) == nil else { continue }  // 他アクション使用中なら奪わない
                switch capture {
                case .character(let s): characterMap[s] = action
                case .chord(let c):     map[c] = action
                }
            }
        }
        knownActions = Self.allActionKeys
    }

    // MARK: - UserDefaults 永続（アプリ全体）

    public static let userDefaultsKey = "viewerKeyBindings"

    public static func load(_ ud: UserDefaults = .standard) -> ViewerKeyBindings {
        guard let data = ud.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode(ViewerKeyBindings.self, from: data)
        else {
            // 未保存（新規ユーザー）。既定は全アクションを含むので、それを既知として刻んで返す。
            // 刻まずに返すと、この直後にキーを 1 つ外して保存したユーザーの削除が次回 load で戻る。
            var fresh = ViewerKeyBindings.defaults
            fresh.knownActions = Self.allActionKeys
            return fresh
        }
        var merged = decoded
        merged.fillMissingActionsFromDefaults()
        return merged
    }

    public func save(_ ud: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            ud.set(data, forKey: ViewerKeyBindings.userDefaultsKey)
            NotificationCenter.default.post(name: .viewerKeyBindingsChanged, object: nil)
        }
    }
}
