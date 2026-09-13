// SPDX-License-Identifier: MIT
import Foundation

/// G54-S2: 本の形式が、内蔵か外部かを**どちらの設定**で決めるか。
public enum ViewerSwitch: String, Sendable, Equatable, CaseIterable {
    /// 画像ビューアの設定に従う（アーカイブ・画像・フォルダ・PDF）。
    case image
    /// EPUB ビューアの設定に従う。
    case epub
    /// 内蔵ビューアに描く手段が無い（動画・txt/md/rtf）。設定に関わらず外部で開く。
    case externalOnly
}

/// 形式と設定から「内蔵で開こうとしてよいか」を決める。
/// ローカル（`AppState.openBooks`）とオフライン（`OfflineLibraryView.openOffline`）が
/// **同じ規則**を使うために、判定をここ 1 か所に閉じ込める。
public enum ViewerChoice {
    /// 拡張子とディレクトリ判定から、どのスイッチに従うかを決める。
    public static func viewerSwitch(forPath path: String) -> ViewerSwitch {
        switch BookCategory.classify(path: path) {
        case .archive, .image, .folder:
            return .image
        case .video:
            return .externalOnly
        case .text:
            // `.text` には pdf / epub / txt / md / rtf が混ざる。内蔵で描けるのは pdf と epub だけ。
            switch (path as NSString).pathExtension.lowercased() {
            // G54-S2: 画像だけの EPUB も**すべて** EPUB 側の設定に従う。
            // 「画像だけか」は開いてみないと分からず、振り分けの前に一度読むと
            // 外部へ渡すだけの場合でも読み込みが入って開き始めが遅くなるため。
            // 内蔵を選んでいれば、その先で画像ビューアと Washi の窓に振り分けられる。
            case "epub": return .epub
            case "pdf": return .image
            default: return .externalOnly
            }
        }
    }

    /// 設定を見て、内蔵で開こうとしてよいかを返す。
    /// `.externalOnly`（動画・txt/md/rtf）はどちらの設定でも `false`。
    @MainActor
    public static func shouldTryBuiltIn(forPath path: String, settings: ViewerSettings) -> Bool {
        switch viewerSwitch(forPath: path) {
        case .image: return settings.useBuiltInImageViewer
        case .epub: return settings.useBuiltInEPUBViewer
        case .externalOnly: return false
        }
    }
}
