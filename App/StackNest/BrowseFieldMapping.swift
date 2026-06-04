// SPDX-License-Identifier: MIT
import AppCore

// DetailField (Detail Pane の field 種別) から BrowserPaneState.BrowseField への mapping。
// BrowseField が持たない field (title / volume / memo) は nil を返す。
// 新規 DetailField case が追加された場合、switch の exhaustiveness check により
// コンパイルエラーが発生するため、漏れなく対応できる。

extension BrowserPaneState.BrowseField {
    /// DetailField から BrowseField を生成する。
    /// Browser pane で絞り込める field のみ non-nil を返す。
    init?(from detailField: DetailField) {
        switch detailField {
        case .genre:    self = .genre
        case .series:   self = .series
        case .author:   self = .author
        case .keywordA: self = .keywordA
        case .keywordB: self = .keywordB
        case .keywordC: self = .keywordC
        case .neta:     self = .neta
        case .title:    return nil
        case .volume:   return nil
        case .memo:     return nil
        }
    }
}
