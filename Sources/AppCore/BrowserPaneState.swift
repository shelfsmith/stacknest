// SPDX-License-Identifier: MIT
import Foundation
import SwiftUI

public struct BrowserPaneState: Codable, Sendable, Equatable {
    /// 3 列の表示 field。`nil` でその列は機能停止 (将来「列を減らす」UX 用、MVP では default で常に non-nil)。
    public var fields: [BrowseField?] = [.genre, .author, .keywordA]

    /// 各列の現在の選択値。`nil` = 「すべて」(その列の filter 未適用)。
    /// fields[i] と selections[i] は対応。
    public var selections: [String?] = [nil, nil, nil]

    /// pane の高さ (pt)。drag handle で user resize、永続化。
    public var height: Double = 200

    /// Browser pane で絞り込めるフィールド集合。
    /// 種類 (bookType) / レート (rating) は Phase 2.4b の toolbar filter で扱うため
    /// Browser pane 用には含めない (Stackroom も同方針)。
    public enum BrowseField: String, Codable, Sendable, CaseIterable {
        case genre        // ジャンル
        case series       // シリーズ (single-value)
        case author       // 作者
        case neta         // 関連
        case keywordA     // キーワード A
        case keywordB     // キーワード B
        case keywordC     // キーワード C

        public var sqlColumn: String {
            switch self {
            case .genre:    return "genre"
            case .series:   return "series"
            case .author:   return "author"
            case .neta:     return "neta"
            case .keywordA: return "keyword_a"
            case .keywordB: return "keyword_b"
            case .keywordC: return "keyword_c"
            }
        }

        public var localizedTitle: LocalizedStringKey {
            switch self {
            case .genre:    return "ジャンル"
            case .series:   return "シリーズ"
            case .author:   return "作者"
            case .neta:     return "関連"
            case .keywordA: return "キーワード A"
            case .keywordB: return "キーワード B"
            case .keywordC: return "キーワード C"
            }
        }
    }

    public init() {}
}

// MARK: - BrowseField helpers

public extension BrowserPaneState.BrowseField {
    /// DetailField の case 名 (String) から BrowseField を生成するファクトリ。
    /// Browser pane が持たない field (title / volume / memo 等) は nil を返す。
    /// rawValue と field name が一致するため rawValue init のラッパーとして実装する。
    init?(fieldName: String) {
        self.init(rawValue: fieldName)
    }
}

extension BrowserPaneState {
    /// 全選択クリア (「すべて」状態)。pane 表示自体はそのまま。
    public mutating func clearSelections() {
        selections = Array(repeating: nil, count: fields.count)
    }

    /// 列 index の field を変更すると、その列以降の selection は無効化される (cascading の整合性維持)。
    public mutating func setField(_ field: BrowseField?, at index: Int) {
        guard index < fields.count else { return }
        fields[index] = field
        for i in index..<selections.count {
            selections[i] = nil
        }
    }

    /// 列 index の selection を変更すると、その列以降の selection は cascading 整合性のため nil 化。
    public mutating func setSelection(_ value: String?, at index: Int) {
        guard index < selections.count else { return }
        selections[index] = value
        for i in (index + 1)..<selections.count {
            selections[i] = nil
        }
    }
}
