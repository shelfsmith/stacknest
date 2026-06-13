// SPDX-License-Identifier: MIT
import Foundation

/// BrowserPaneState.BrowseField の既定表示名（per-library カスタムラベル未適用時／リモート用）。
/// LibrarySettings.browseLabel(for:) の既定文言と一致させる。
public func defaultBrowseFieldLabel(_ field: BrowserPaneState.BrowseField) -> String {
    switch field {
    case .genre:    return String(localized: "ジャンル")
    case .series:   return String(localized: "シリーズ")
    case .author:   return String(localized: "作者")
    case .neta:     return String(localized: "関連")
    case .keywordA: return String(localized: "キーワード A")
    case .keywordB: return String(localized: "キーワード B")
    case .keywordC: return String(localized: "キーワード C")
    }
}
