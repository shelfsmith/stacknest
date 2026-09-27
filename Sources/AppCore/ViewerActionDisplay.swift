// SPDX-License-Identifier: MIT
import Foundation
import StackNestL10n

public extension ViewerAction {
    /// 設定 UI / ヘルプ表示用のラベル（`L10n.text` で言語ごとに引く）。
    /// 新 case を足したらここで必ず付与する（網羅 switch）。
    var displayName: String {
        switch self {
        case .nextPage: return L10n.text("ページ送り")
        case .previousPage: return L10n.text("ページ戻し")
        case .pageLeftward: return L10n.text("左方向へ")
        case .pageRightward: return L10n.text("右方向へ")
        case .firstPage: return L10n.text("先頭ページ")
        case .lastPage: return L10n.text("末尾ページ")
        case .zoomIn: return L10n.text("ズームイン")
        case .zoomOut: return L10n.text("ズームアウト")
        case .fitToWindow: return L10n.text("ウィンドウに合わせる")
        case .toggleFullScreen: return L10n.text("全画面 切替")
        case .close: return L10n.text("閉じる")
        case .toggleSpread: return L10n.text("見開き 切替")
        case .toggleCoverOffset: return L10n.text("表紙オフセット 切替")
        case .toggleAutoAdvance: return L10n.text("スライドショー 開始/停止")
        case .cyclePageLayout: return L10n.text("横長レイアウト 巡回")
        case .nextVolume: return L10n.text("次の巻")
        case .prevVolume: return L10n.text("前の巻")
        case .cycleEndOfBookBehavior: return L10n.text("巻末挙動 切替")
        case .showHelp: return L10n.text("ヘルプ表示")
        case .jumpToPercent0: return L10n.text("位置ジャンプ 0%")
        case .jumpToPercent10: return L10n.text("位置ジャンプ 10%")
        case .jumpToPercent20: return L10n.text("位置ジャンプ 20%")
        case .jumpToPercent30: return L10n.text("位置ジャンプ 30%")
        case .jumpToPercent40: return L10n.text("位置ジャンプ 40%")
        case .jumpToPercent50: return L10n.text("位置ジャンプ 50%")
        case .jumpToPercent60: return L10n.text("位置ジャンプ 60%")
        case .jumpToPercent70: return L10n.text("位置ジャンプ 70%")
        case .jumpToPercent80: return L10n.text("位置ジャンプ 80%")
        case .jumpToPercent90: return L10n.text("位置ジャンプ 90%")
        case .skipForward: return L10n.text("ページスキップ（進む）")
        case .skipBackward: return L10n.text("ページスキップ（戻る）")
        case .togglePageDirection: return L10n.text("ページ方向 切替（この本）")
        case .toggleLoupe: return L10n.text("ルーペ")
        }
    }
}

/// 設定 UI / ヘルプ表の並び順とグループ。
public enum ViewerActionSection: CaseIterable {
    case navigation, zoom, spreadSlideshow, volume, misc

    public var title: String {
        switch self {
        case .navigation: return L10n.text("ナビゲーション")
        case .zoom: return L10n.text("ズーム")
        case .spreadSlideshow: return L10n.text("見開き・スライドショー")
        case .volume: return L10n.text("巻移動")
        case .misc: return L10n.text("その他")
        }
    }

    /// セクション内の表示順。全 ViewerAction を過不足なく分配する（テストで保証）。
    public var actions: [ViewerAction] {
        switch self {
        case .navigation:
            return [.nextPage, .previousPage, .pageLeftward, .pageRightward,
                    .firstPage, .lastPage, .skipForward, .skipBackward,
                    .jumpToPercent0, .jumpToPercent10, .jumpToPercent20, .jumpToPercent30,
                    .jumpToPercent40, .jumpToPercent50, .jumpToPercent60, .jumpToPercent70,
                    .jumpToPercent80, .jumpToPercent90]
        case .zoom:
            return [.zoomIn, .zoomOut, .fitToWindow, .toggleLoupe]
        case .spreadSlideshow:
            return [.toggleSpread, .toggleCoverOffset, .cyclePageLayout,
                    .toggleAutoAdvance, .cycleEndOfBookBehavior, .togglePageDirection]
        case .volume:
            return [.prevVolume, .nextVolume]
        case .misc:
            return [.toggleFullScreen, .close, .showHelp]
        }
    }
}
