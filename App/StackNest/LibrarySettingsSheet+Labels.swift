// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore

extension LibrarySettingsSheet {
    /// 4.2c-8: 共有 LabelEditorView へ委譲（リモート編集シートと UI 単一ソース化）。
    /// ステージ状態（stagedFieldLabels / stagedBookTypeLabels）と保存（save()）の流れは不変。
    @ViewBuilder
    func labelSection() -> some View {
        LabelEditorView(
            fieldLabels: $stagedFieldLabels,
            bookTypeLabels: $stagedBookTypeLabels,
            fieldRows: Self.fieldLabelRows,
            bookTypeRows: Self.bookTypeLabelRows)
    }

    /// 内容系 5 フィールドの行（key=dbColumn, canonical=正準）。StampField を単一ソースにする。
    static var fieldLabelRows: [(key: String, canonical: String)] {
        StampField.allCases.map { (key: $0.dbColumn, canonical: $0.localizedTitle) }
    }

    /// bookType の行（raw=0..5, canonical=正準＝`@type` に入る値, display=画面表示名）。
    /// G55: 日本語 UI では canonical と display は同じ文字列。英語 UI では display（訳）を主表示にし、
    /// canonical はファイル名に入る値の補足として LabelEditorView 側で見せる。
    static var bookTypeLabelRows: [(raw: Int, canonical: String, display: String)] {
        (0..<6).map { (raw: $0, canonical: BookTypeLabel.canonicalLabel(for: $0), display: BookTypeLabel.displayLabel(for: $0)) }
    }
}
