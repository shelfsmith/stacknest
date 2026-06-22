// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore

extension LibrarySettingsSheet {
    // 4.2c-8 B1: ラベル編集はライブラリ設定シートから廃止し、ツールバーの LocalLabelEditorSheet へ移設。
    // 行定義（static）はローカル/リモートの LabelEditorView 呼び出しで共用するため残す。

    /// 内容系 5 フィールドの行（key=dbColumn, canonical=正準）。StampField を単一ソースにする。
    static var fieldLabelRows: [(key: String, canonical: String)] {
        StampField.allCases.map { (key: $0.dbColumn, canonical: $0.localizedTitle) }
    }

    /// bookType の行（raw=0..5, canonical=正準）。
    static var bookTypeLabelRows: [(raw: Int, canonical: String)] {
        (0..<6).map { (raw: $0, canonical: BookTypeLabel.canonicalLabel(for: $0)) }
    }
}
