// SPDX-License-Identifier: MIT
import Foundation

public extension ViewerAction {
    /// 設定 UI / ヘルプ表示用の日本語ラベル。新 case を足したらここで必ず付与する（網羅 switch）。
    var displayName: String {
        switch self {
        case .nextPage: return "ページ送り"
        case .previousPage: return "ページ戻し"
        case .pageLeftward: return "左方向へ"
        case .pageRightward: return "右方向へ"
        case .firstPage: return "先頭ページ"
        case .lastPage: return "末尾ページ"
        case .zoomIn: return "ズームイン"
        case .zoomOut: return "ズームアウト"
        case .fitToWindow: return "ウィンドウに合わせる"
        case .toggleFullScreen: return "全画面 切替"
        case .close: return "閉じる"
        case .toggleSpread: return "見開き 切替"
        case .toggleCoverOffset: return "表紙オフセット 切替"
        case .toggleAutoAdvance: return "スライドショー 開始/停止"
        case .cyclePageLayout: return "横長レイアウト 巡回"
        case .nextVolume: return "次の巻"
        case .prevVolume: return "前の巻"
        case .cycleEndOfBookBehavior: return "巻末挙動 切替"
        case .showHelp: return "ヘルプ表示"
        case .jumpToPercent0: return "位置ジャンプ 0%"
        case .jumpToPercent10: return "位置ジャンプ 10%"
        case .jumpToPercent20: return "位置ジャンプ 20%"
        case .jumpToPercent30: return "位置ジャンプ 30%"
        case .jumpToPercent40: return "位置ジャンプ 40%"
        case .jumpToPercent50: return "位置ジャンプ 50%"
        case .jumpToPercent60: return "位置ジャンプ 60%"
        case .jumpToPercent70: return "位置ジャンプ 70%"
        case .jumpToPercent80: return "位置ジャンプ 80%"
        case .jumpToPercent90: return "位置ジャンプ 90%"
        case .skipForward: return "ページスキップ（進む）"
        case .skipBackward: return "ページスキップ（戻る）"
        case .togglePageDirection: return "ページ方向 切替（この本）"
        }
    }
}

/// 設定 UI / ヘルプ表の並び順とグループ。
public enum ViewerActionSection: CaseIterable {
    case navigation, zoom, spreadSlideshow, volume, misc

    public var title: String {
        switch self {
        case .navigation: return "ナビゲーション"
        case .zoom: return "ズーム"
        case .spreadSlideshow: return "見開き・スライドショー"
        case .volume: return "巻移動"
        case .misc: return "その他"
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
            return [.zoomIn, .zoomOut, .fitToWindow]
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
