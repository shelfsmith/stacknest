// SPDX-License-Identifier: MIT
import Foundation
import LibraryStore

// PageDirection は LibraryStore/PageDirection.swift に定義されている。
// AppCore は LibraryStore に依存しているが、@_exported re-export は行っていないため、
// PageDirection を使うモジュール（App 層を含む）は明示的に import LibraryStore が必要。

/// 内蔵ビューワで最終ページの「次」を押したときの挙動。
/// MVP では `.stop` のみ UI 解放。`.nextBook` / `.loop` は scaffold（2.6b-2 で UI 解放）。
public enum EndOfBookBehavior: String, Codable, Sendable, CaseIterable {
    case stop
    case nextBook
    case loop

    public static let defaultValue: EndOfBookBehavior = .stop
}

/// 内蔵ビューワの表示モード。single = 1 ページ、spread = 見開き 2 ページ。
public enum ViewerDisplayMode: String, Codable, Sendable, CaseIterable {
    case single
    case spread
}
